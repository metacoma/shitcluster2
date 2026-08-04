import k8s.api.core.v1 as k8s
import k8s.api.apps.v1 as v1
import config as cfg

_config = cfg.config
mcp = _config.mcp
artifacthub = mcp.artifacthub_mcp

manifests = [
  # Deployment
  v1.Deployment {
    metadata = {
      name = "artifacthub-mcp"
      namespace = mcp.namespace
      labels = {
        "app": "artifacthub-mcp"
      }
    }
    spec = {
      replicas = 1
      selector = {
        matchLabels = {
          "app": "artifacthub-mcp"
        }
      }
      template = {
        metadata = {
          labels = {
            "app": "artifacthub-mcp"
          }
        }
        spec = {
          containers = [
            {
              name = "artifacthub-mcp"
              image = artifacthub.image
              ports = [
                {
                  containerPort = artifacthub.port
                }
              ]
              livenessProbe = {
                httpGet = {
                  path = "/status"
                  port = artifacthub.port
                }
                initialDelaySeconds = 10
                periodSeconds = 30
              }
              readinessProbe = {
                httpGet = {
                  path = "/status"
                  port = artifacthub.port
                }
                initialDelaySeconds = 5
                periodSeconds = 10
              }
              resources = {
                requests = {
                  cpu = "100m"
                  memory = "256Mi"
                }
                limits = {
                  cpu = "500m"
                  memory = "512Mi"
                }
              }
            }
          ]
        }
      }
    }
  }

  # Service
  k8s.Service {
    metadata = {
      name = "artifacthub-mcp"
      namespace = mcp.namespace
    }
    spec = {
      selector = {
        "app": "artifacthub-mcp"
      }
      ports = [
        {
          port = 80
          targetPort = artifacthub.port
        }
      ]
      type = "ClusterIP"
    }
  }

  # Ingress
  {
    apiVersion = "networking.k8s.io/v1"
    kind = "Ingress"
    metadata = {
      name = "artifacthub-mcp-ingress"
      namespace = mcp.namespace
      annotations = {
        "kubernetes.io/ingress.class" = "nginx"
      }
    }
    spec = {
      tls = [
        {
          hosts = ["artifacthub-mcp." + _config.cert_manager.managed_domain]
          secretName = "mansion-net-tls"
        }
      ]
      rules = [
        {
          host = "artifacthub-mcp." + _config.cert_manager.managed_domain
          http = {
            paths = [
              {
                path = "/"
                pathType = "Prefix"
                backend = {
                  service = {
                    name = "artifacthub-mcp"
                    port = {
                      number = 80
                    }
                  }
                }
              }
            ]
          }
        }
      ]
    }
  }
]
