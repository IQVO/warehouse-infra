# ---------------------------------------------------------------------------
# Frontends: the product UI half of the localhost topology (ADR-0005).
#
# Two host-facing entrypoints, independent, with NO proxy relationship:
#
#   http://localhost        -> Nginx web gateway -> console (/) + remotes (/mfes/<ctx>/)
#   http://localhost:8000   -> Kong              -> every API (/api/<ctx>)
#
# Kong never serves HTML/JS/CSS. The web gateway never proxies an API. That
# separation is the whole point of the design and is asserted by
# scripts/test-exposure-policy.sh.
#
# Each bounded context owns its remote under <repo>/web and ships the frontend
# Deployment/Service in its OWN chart behind `frontend.enabled` (default
# false). warehouse-infra only decides that this environment wants them on,
# and supplies the locally built image tag -- the same environment-vs-shape
# split as services.tf.
#
# warehouse-console is its own Helm release (it has no backend chart to ride
# along in) and additionally gets the runtime /config.json carrying
# `apiOrigin`, which every remote reads to build its own API base. That is how
# ONE image serves any environment.
# ---------------------------------------------------------------------------

locals {
  # Every remote is owned by the bounded context whose API it calls, and is
  # served at /mfes/<context>/. The remote_name is the Module Federation
  # container name the console's vite.config.ts imports by -- recorded here
  # only for traceability; nothing in Terraform derives behaviour from it.
  frontend_remotes = var.deploy_frontends ? {
    "order-management"        = { remote_name = "order_mgmt_mfe" }
    "inventory-storage"       = { remote_name = "inventory_mfe" }
    "wes-work-planning"       = { remote_name = "planning_mfe" }
    "fulfillment-execution"   = { remote_name = "fulfillment_mfe" }
    "workforce-management"    = { remote_name = "workforce_mfe" }
    "facility-layout"         = { remote_name = "facility_mfe" }
    "labor-performance"       = { remote_name = "labor_mfe" }
    "process-path-management" = { remote_name = "process_path_mfe" }
  } : {}

  # Content-addressed image tags, NOT the fixed "local" tag the Go services
  # use. That fixed tag is a known defect over there: a rebuilt image leaves
  # the pod template byte-identical, so Kubernetes sees no reason to roll and
  # `IfNotPresent` stops the kubelet re-pulling -- the OLD bundle keeps being
  # served until something else changes the pod spec. Hashing the sources into
  # the tag makes the Deployment's image field change whenever the bundle
  # does, so a rollout happens by itself. Do not "simplify" this back to a
  # fixed tag.
  #
  # The hash deliberately spans the ui-kit too: it is compiled INTO every
  # remote's bundle, so a ui-kit change with an unchanged remote still
  # produces different bytes.
  uikit_source_hash = sha256(join("", concat(
    [for f in sort(fileset("${path.module}/../../warehouse-ui-kit/src", "**")) : filesha256("${path.module}/../../warehouse-ui-kit/src/${f}")],
    [
      filesha256("${path.module}/../../warehouse-ui-kit/package.json"),
    ],
  )))

  frontend_source_hash = {
    for name, fe in local.frontend_remotes :
    name => substr(sha256(join("", concat(
      [for f in sort(fileset("${path.module}/../../${name}/web/src", "**")) : filesha256("${path.module}/../../${name}/web/src/${f}")],
      [
        filesha256("${path.module}/../../${name}/web/package.json"),
        filesha256("${path.module}/../../${name}/web/vite.config.ts"),
        filesha256("${path.module}/../../${name}/web/index.html"),
        filesha256("${path.module}/../../${name}/web/Dockerfile"),
        filesha256("${path.module}/../../${name}/web/nginx.conf"),
        local.uikit_source_hash,
      ],
    ))), 0, 12)
  }

  console_source_hash = var.deploy_frontends ? substr(sha256(join("", concat(
    [for f in sort(fileset("${path.module}/../../warehouse-console/src", "**")) : filesha256("${path.module}/../../warehouse-console/src/${f}")],
    [
      filesha256("${path.module}/../../warehouse-console/package.json"),
      filesha256("${path.module}/../../warehouse-console/vite.config.ts"),
      filesha256("${path.module}/../../warehouse-console/index.html"),
      filesha256("${path.module}/../../warehouse-console/Dockerfile"),
      filesha256("${path.module}/../../warehouse-console/nginx.conf"),
      local.uikit_source_hash,
    ],
  ))), 0, 12) : ""

  console_chart_path   = "${path.module}/../../warehouse-console/charts/warehouse-console"
  console_release_name = "warehouse-console"

  # Service DNS the web gateway proxies to. Every one of these is ClusterIP:
  # the gateway is the only frontend workload with a NodePort.
  #
  # The frontend Service name comes from each chart's own frontendFullname
  # helper, which is "<release>-frontend"; the release name is the context
  # name (services.tf uses each.key). Asserted live by the smoke test rather
  # than assumed.
  frontend_service_host = {
    for name, fe in local.frontend_remotes :
    name => "${name}-frontend.${var.apps_namespace}.svc.cluster.local"
  }

  console_service_host = "${local.console_release_name}.${var.apps_namespace}.svc.cluster.local"

  # The browser-facing API origin the console publishes in /config.json. This
  # is KONG's host endpoint -- a different origin from the page itself, which
  # is exactly why Kong needs the exact-origin CORS policy in kong-cors.tf.
  api_origin = "http://localhost:${var.kong_proxy_http_host_port}"

  # The page's own origin, and therefore the ONLY origin Kong should grant
  # CORS to. Port 80 is implicit in an HTTP origin, so it must be omitted
  # there or the browser's Origin header will never match.
  web_origin = var.web_gateway_host_port == 80 ? "http://localhost" : "http://localhost:${var.web_gateway_host_port}"
}

# ---------------------------------------------------------------------------
# Build + side-load every frontend image.
# ---------------------------------------------------------------------------

resource "null_resource" "build_and_load_frontend" {
  for_each = local.frontend_remotes

  depends_on = [kind_cluster.warehouse]

  triggers = {
    source_hash = local.frontend_source_hash[each.key]
    image       = "warehouse/${each.key}-frontend:local-${local.frontend_source_hash[each.key]}"
    cluster     = var.cluster_name
  }

  provisioner "local-exec" {
    command = "${path.module}/../scripts/build-and-load-frontend.sh '${each.key}' 'web' 'local-${local.frontend_source_hash[each.key]}' '${var.cluster_name}'"
  }
}

resource "null_resource" "build_and_load_console" {
  count = var.deploy_frontends ? 1 : 0

  depends_on = [kind_cluster.warehouse]

  triggers = {
    source_hash = local.console_source_hash
    image       = "warehouse/warehouse-console-frontend:local-${local.console_source_hash}"
    cluster     = var.cluster_name
  }

  # The console's SPA is the repo root, not a web/ subdirectory.
  provisioner "local-exec" {
    command = "${path.module}/../scripts/build-and-load-frontend.sh 'warehouse-console' '.' 'local-${local.console_source_hash}' '${var.cluster_name}'"
  }
}

# ---------------------------------------------------------------------------
# warehouse-console: its own Helm release.
# ---------------------------------------------------------------------------

resource "helm_release" "console" {
  count = var.deploy_frontends ? 1 : 0

  depends_on = [
    kubernetes_namespace.apps,
    null_resource.build_and_load_console,
  ]

  name      = local.console_release_name
  chart     = local.console_chart_path
  namespace = var.apps_namespace

  timeout = 300
  wait    = true

  values = [
    yamlencode({
      image = {
        repository = "warehouse/warehouse-console-frontend"
        tag        = "local-${local.console_source_hash}"
        pullPolicy = "IfNotPresent"
      }

      # ClusterIP: the web gateway is the only host-facing frontend endpoint.
      service = {
        type       = "ClusterIP"
        port       = 80
        targetPort = 8080
      }

      # Frontend routing belongs to the web gateway, never to an Ingress or
      # HTTPRoute -- an Ingress here would put console traffic through KONG,
      # which is precisely what this design forbids.
      ingress = {
        enabled = false
      }

      # The runtime contract every remote reads. apiOrigin points at Kong's
      # host endpoint, cross-origin from this page by design.
      runtimeConfig = {
        enabled   = true
        apiOrigin = local.api_origin
      }
    }),
  ]
}

# ---------------------------------------------------------------------------
# The Nginx web gateway.
# ---------------------------------------------------------------------------

locals {
  web_gateway_name = "web-gateway"

  # nginx variable names cannot contain hyphens.
  web_gateway_config = var.deploy_frontends ? templatefile("${path.module}/templates/web-gateway.conf.tftpl", {
    listen_port = 8080
    # kube-dns by IP -- nginx cannot resolve its own resolver, so a DNS name
    # here fails config parsing and the container never starts. Resolving
    # upstreams at REQUEST time (rather than once at boot) is what stops a
    # redeployed frontend pod 502-ing until the gateway itself restarts.
    dns_resolver         = var.cluster_dns_ip
    console_service_host = local.console_service_host
    console_service_port = 80
    remotes = [
      for name, fe in local.frontend_remotes : {
        context      = name
        remote_name  = fe.remote_name
        upstream_var = replace(name, "-", "_")
        service_host = local.frontend_service_host[name]
        service_port = 80
      }
    ]
  }) : ""
}

resource "kubernetes_config_map" "web_gateway" {
  count = var.deploy_frontends ? 1 : 0

  depends_on = [kubernetes_namespace.apps]

  metadata {
    name      = "${local.web_gateway_name}-config"
    namespace = var.apps_namespace
    labels = {
      "app.kubernetes.io/name"   = local.web_gateway_name
      "warehouse.local/tier"     = "frontend"
      "warehouse.local/exposure" = "localhost"
    }
  }

  data = {
    "nginx.conf" = local.web_gateway_config
  }
}

resource "kubernetes_deployment" "web_gateway" {
  count = var.deploy_frontends ? 1 : 0

  depends_on = [
    kubernetes_config_map.web_gateway,
    helm_release.console,
    helm_release.service,
  ]

  metadata {
    name      = local.web_gateway_name
    namespace = var.apps_namespace
    labels = {
      "app.kubernetes.io/name"      = local.web_gateway_name
      "app.kubernetes.io/component" = "web-gateway"
      "warehouse.local/tier"        = "frontend"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name" = local.web_gateway_name
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"      = local.web_gateway_name
          "app.kubernetes.io/component" = "web-gateway"
        }
        annotations = {
          # Roll the pod whenever the routing config changes. The ConfigMap is
          # mounted by subPath, which kubelet does NOT live-update, so without
          # this a changed upstream would never take effect.
          "checksum/config" = sha256(local.web_gateway_config)
        }
      }

      spec {
        security_context {
          run_as_non_root = true
          run_as_user     = 101
          fs_group        = 101
        }

        container {
          name  = "nginx"
          image = var.web_gateway_image

          port {
            name           = "http"
            container_port = 8080
            protocol       = "TCP"
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
            read_only  = true
          }

          volume_mount {
            name       = "cache"
            mount_path = "/var/cache/nginx"
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = "http"
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = "http"
            }
            initial_delay_seconds = 3
            period_seconds        = 5
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.web_gateway[0].metadata[0].name
          }
        }

        volume {
          name = "cache"
          empty_dir {}
        }

        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }
}

# The gateway's NodePort: one of exactly two host-facing product ports (the
# other is Kong's). kind's extraPortMappings (main.tf) publish this on
# 127.0.0.1:<web_gateway_host_port>.
resource "kubernetes_service" "web_gateway" {
  count = var.deploy_frontends ? 1 : 0

  depends_on = [kubernetes_deployment.web_gateway]

  metadata {
    name      = local.web_gateway_name
    namespace = var.apps_namespace
    labels = {
      "app.kubernetes.io/name"   = local.web_gateway_name
      "warehouse.local/tier"     = "frontend"
      "warehouse.local/exposure" = "localhost"
    }
  }

  spec {
    type = "NodePort"
    selector = {
      "app.kubernetes.io/name" = local.web_gateway_name
    }
    port {
      name        = "http"
      port        = 80
      target_port = "http"
      node_port   = var.web_gateway_node_port
      protocol    = "TCP"
    }
  }
}

output "web_url" {
  description = "The product UI: the console shell and every Module Federation remote."
  value       = var.deploy_frontends ? local.web_origin : ""
}

output "api_origin" {
  description = "The product API origin (Kong). Cross-origin from web_url by design."
  value       = local.api_origin
}
