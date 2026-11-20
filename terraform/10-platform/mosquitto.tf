# ---------------------------------------------------------------------------
# Mosquitto — a single Eclipse Mosquitto MQTT broker for the WCS tier
# (warehouse control system): VDA 5050 messages between amr-fleet-control and
# the robots, and the AS/RS telegrams, travel over it. Nothing outside the WCS
# subscribes to it; the WES and everything above it speak Kafka, never MQTT.
# The equipment emulator (helm-values/equipment-emulator.yaml) is the first
# client and reaches it at mosquitto.<apps namespace>.svc.cluster.local:1883.
#
# Plain Kubernetes resources (ConfigMap, Deployment, Service) rather than a
# Helm release: one container, one config file, no chart worth pulling.
#
# allow_anonymous true is deliberate and matches the fleet's no-auth rule
# (the study cluster's traffic is cluster-internal; no application authenticates).
# persistence false: the broker is ephemeral like Kafka here; retained state
# is rebuilt by the publishers. NOT a production broker topology (one replica,
# no TLS, no ACLs).
# ---------------------------------------------------------------------------

resource "kubernetes_config_map" "mosquitto" {
  count = var.deploy_mosquitto ? 1 : 0

  depends_on = [kubernetes_namespace.apps]

  metadata {
    name      = "mosquitto-config"
    namespace = var.apps_namespace
    labels = {
      "app.kubernetes.io/name" = "mosquitto"
      "warehouse.local/tier"   = "platform"
    }
  }

  data = {
    "mosquitto.conf" = <<-EOT
      listener 1883
      allow_anonymous true
      persistence false
    EOT
  }
}

resource "kubernetes_deployment" "mosquitto" {
  count = var.deploy_mosquitto ? 1 : 0

  depends_on = [kubernetes_namespace.apps, kubernetes_config_map.mosquitto]

  metadata {
    name      = "mosquitto"
    namespace = var.apps_namespace
    labels = {
      "app.kubernetes.io/name"      = "mosquitto"
      "app.kubernetes.io/component" = "mqtt-broker"
      "warehouse.local/tier"        = "platform"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "mosquitto"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"      = "mosquitto"
          "app.kubernetes.io/component" = "mqtt-broker"
        }
        annotations = {
          # The ConfigMap is mounted by subPath, which kubelet does not
          # live-update: roll the pod when the config changes.
          "checksum/config" = sha256(kubernetes_config_map.mosquitto[0].data["mosquitto.conf"])
        }
      }

      spec {
        container {
          name  = "mosquitto"
          image = var.mosquitto_image

          port {
            name           = "mqtt"
            container_port = 1883
            protocol       = "TCP"
          }

          volume_mount {
            name       = "config"
            mount_path = "/mosquitto/config/mosquitto.conf"
            sub_path   = "mosquitto.conf"
            read_only  = true
          }

          readiness_probe {
            tcp_socket {
              port = "mqtt"
            }
            initial_delay_seconds = 2
            period_seconds        = 5
          }

          resources {
            requests = { cpu = "25m", memory = "32Mi" }
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.mosquitto[0].metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "mosquitto" {
  count = var.deploy_mosquitto ? 1 : 0

  depends_on = [kubernetes_namespace.apps, kubernetes_deployment.mosquitto]

  metadata {
    name      = "mosquitto"
    namespace = var.apps_namespace
    labels = {
      "app.kubernetes.io/name" = "mosquitto"
      "warehouse.local/tier"   = "platform"
    }
  }

  spec {
    type = "ClusterIP"
    selector = {
      "app.kubernetes.io/name" = "mosquitto"
    }
    port {
      name        = "mqtt"
      port        = 1883
      target_port = "mqtt"
      protocol    = "TCP"
    }
  }
}
