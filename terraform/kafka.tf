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
      }
      resources = {
        requests = { cpu = "250m", memory = "512Mi" }
        limits   = { cpu = "1000m", memory = "1Gi" }
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
    overrideConfiguration = {
      "offsets.topic.replication.factor"         = "1"
      "transaction.state.log.replication.factor" = "1"
      "transaction.state.log.min.isr"            = "1"
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
