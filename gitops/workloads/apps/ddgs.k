import k8s.api.core.v1 as k8s
import k8s.api.apps.v1 as v1
import config as cfg

_config = cfg.config
mcp = _config.mcp
ddgs = mcp.ddgs

manifests = [
  # Deployment
  v1.Deployment {
    metadata = {
      name = "ddgs"
      namespace = mcp.namespace
      labels = {
        "app": "ddgs"
      }
    }
    spec = {
      replicas = 1
      selector = {
        matchLabels = {
          "app": "ddgs"
        }
      }
      template = {
        metadata = {
          labels = {
            "app": "ddgs"
          }
        }
        spec = {
          containers = [
            {
              name = "ddgs"
              image = ddgs.image
              args = ["mcp-proxy", "--host=0.0.0.0", "--port=" + str(ddgs.port), "--allow-origin=*", "--", "ddgs", "mcp"]
              ports = [
                {
                  containerPort = ddgs.port
                }
              ]
              resources = {
                requests = {
                  cpu = "100m"
                  memory = "128Mi"
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
      name = "ddgs"
      namespace = mcp.namespace
    }
    spec = {
      selector = {
        "app": "ddgs"
      }
      ports = [
        {
          port = 80
          targetPort = ddgs.port
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
      name = "ddgs-ingress"
      namespace = mcp.namespace
      annotations = {
        "kubernetes.io/ingress.class" = "nginx"
      }
    }
    spec = {
      tls = [
        {
          hosts = ["ddgs." + _config.cert_manager.managed_domain]
          secretName = "mansion-net-tls"
        }
      ]
      rules = [
        {
          host = "ddgs." + _config.cert_manager.managed_domain
          http = {
            paths = [
              {
                path = "/"
                pathType = "Prefix"
                backend = {
                  service = {
                    name = "ddgs"
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
