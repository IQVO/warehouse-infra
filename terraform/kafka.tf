# ---------------------------------------------------------------------------
# Kafka — single-broker, KRaft mode (no ZooKeeper), for local event-driven
# integration + the per-service analytics fan-out (ADR-0010 in each repo).
#
# Chart: oci://registry-1.docker.io/bitnamicharts/kafka
#
# Same bitnamilegacy image-registry override as postgres.tf, for the same
# reason: Bitnami moved its versioned public images to "Bitnami Secure
# Images" in 2025 and the frozen, version-pinned tags now live under the
# `bitnamilegacy` Docker Hub org. `4.0.0-debian-12-r10` is pinned to match
# this chart's own appVersion exactly (verified present in bitnamilegacy).
#
# controller+broker combined (KRaft `combined` process role) — the simplest
# viable single-node topology for a laptop kind cluster; this is explicitly
# NOT a production Kafka topology (no replication, ephemeral storage).
# ---------------------------------------------------------------------------

resource "helm_release" "kafka" {
  count = var.deploy_kafka ? 1 : 0

  depends_on = [kubernetes_namespace.apps]

  name       = "kafka"
  repository = "oci://registry-1.docker.io/bitnamicharts"
  chart      = "kafka"
  version    = var.kafka_chart_version
  namespace  = var.apps_namespace

  # A first boot has to initialize the KRaft cluster metadata log.
  timeout = 600
  wait    = true

  values = [yamlencode({
    global = {
      security = {
        allowInsecureImages = true
      }
    }

    image = {
      registry   = "docker.io"
      repository = "bitnamilegacy/kafka"
      tag        = var.kafka_image_tag
    }

    # Single combined controller+broker node — no separate controller pool,
    # no replication. Fine for a laptop; not a production topology.
    controller = {
      replicaCount = 1
      persistence = {
        enabled = var.kafka_persistence_enabled
        # Chart default is 8Gi; this single-broker/no-replication topology
        # only ever holds a handful of demo/e2e topics with short retention,
        # so 3Gi (same rationale/size as postgres.tf's PVC) is plenty for a
        # laptop kind cluster and avoids reserving 8Gi of host disk per PVC.
        size = "3Gi"
      }
      # 2Gi limit (was 1Gi). The broker runs with KAFKA_HEAP_OPTS
      # MaxRAMPercentage=75, so heap scales with the limit; at 1Gi it sat at
      # ~950Mi in steady state and was OOMKilled during a full warehouse-day
      # simulation (60 orders, every context publishing integration +
      # analytics events, ~20 topics x 8 partitions + .dlq topics). An OOM
      # restart is not a soft failure here: consumers without broker-restart
      # recovery stopped for good (order-management exited; fulfillment-
      # execution's WorkReleased consumer silently stopped). Kafka CLI tools
      # run inside this same container (see AGENTS.md) and need headroom too.
      resources = {
        requests = { cpu = "250m", memory = "1Gi" }
        limits   = { cpu = "1000m", memory = "2Gi" }
      }
    }

    # listeners.client.protocol=PLAINTEXT: no SASL/TLS. This cluster has no
    # network policy isolating warehouse-systems from other namespaces
    # either, so this mirrors Postgres's "fine for a laptop, not prod"
    # stance rather than under- or over-building auth for a local kind
    # cluster no one else can reach.
    listeners = {
      client = {
        protocol = "PLAINTEXT"
      }
      controller = {
        protocol = "PLAINTEXT"
      }
      interbroker = {
        protocol = "PLAINTEXT"
      }
      external = {
        protocol = "PLAINTEXT"
      }
    }

    # kraft.enabled defaults true on this chart major version (no separate
    # ZooKeeper release); left implicit rather than pinned so a future chart
    # bump doesn't silently fight its own default.

    # Single-broker cluster: Kafka's internal topics (__consumer_offsets,
    # __transaction_state) default to replication factor 3, which can NEVER
    # succeed with only 1 broker -- auto-topic-creation retries forever and
    # every consumer group's FindCoordinator request fails with error 15
    # (Group Coordinator Not Available), which is FATAL to any service whose
    # only inbound data path is a Kafka consumer (e.g. labor-performance).
    # Force every replication factor to 1 to match the single-broker
    # topology this module actually deploys.
    #
    # num.partitions: every business topic is auto-created (each service's
    # writer sets AllowAutoTopicCreation: true; this repo has no
    # kafka_topic/Mongey-provider resource and no required_providers entry
    # for one) so the broker's own num.partitions default is the ONLY
    # source of truth for a freshly created topic's partition count.
    # Kafka's own default is 1, which is what silently produced the
    # "every topic has 1 partition" state this override now fixes going
    # forward (scalability plan §3.2). The 17 topics that already existed
    # were bumped live via `kafka-topics.sh --alter --partitions 8`
    # instead of through Terraform: partition count can only be increased,
    # never decreased, and Kafka has no "resize" apply path through this
    # chart (bumping this value alone does not touch an existing topic,
    # only ones auto-created after this change) — so there is nothing for
    # `terraform apply` to reconcile here, and setting num.partitions to
    # match keeps a future auto-created topic (or one recreated after a
    # deliberate delete) from silently reverting to 1.
    overrideConfiguration = {
      "offsets.topic.replication.factor"         = "1"
      "transaction.state.log.replication.factor" = "1"
      "transaction.state.log.min.isr"            = "1"
      "num.partitions"                           = "8"
    }

    # The EXTERNAL listener + its per-pod NodePort Service. This is what
    # makes this the ONLY broker the platform needs: host-side clients
    # (e2e-tests, local `go run`) reach the same broker the pods use,
    # instead of a separate docker-compose container that shared nothing
    # but a port number. `domain` is what the broker advertises to those
    # host clients, and it must be an address resolvable ON THE HOST —
    # "localhost" works because kind publishes the NodePort there via
    # main.tf's extra_port_mappings.
    externalAccess = {
      enabled = var.kafka_external_access_enabled
      controller = {
        service = {
          type      = "NodePort"
          domain    = "localhost"
          nodePorts = [var.kafka_node_port]
        }
      }
    }

    metrics = {
      kafka = {
        enabled = false
      }
    }
  })]
}

# In-cluster bootstrap address every service's KAFKA_BROKERS / kafka.brokers
# helm value should point at. The bitnami chart's headless/plain Service is
# named "kafka" in this release (release name == chart's fullname default).
output "kafka_brokers" {
  description = "In-cluster Kafka bootstrap address (PLAINTEXT), or empty if deploy_kafka=false."
  value       = var.deploy_kafka ? "kafka.${var.apps_namespace}.svc.cluster.local:9092" : ""
}

# Host-side bootstrap address for the SAME broker: what e2e-tests/env.sh and
# a local `go run` should use. Empty when the broker is cluster-internal only.
output "kafka_brokers_host" {
  description = "Host-reachable Kafka bootstrap address for out-of-cluster clients (e2e-tests, local go run)."
  value       = var.deploy_kafka && var.kafka_external_access_enabled ? "localhost:${var.kafka_host_port}" : ""
}
