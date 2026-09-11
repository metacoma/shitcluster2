import k8s.api.core.v1 as k8s
import k8s.api.apps.v1 as v1
import config as cfg

# DonSeTch (https://github.com/dondai44423/donsetch) — successor of hound-mcp:
# web fetch / keyless search / crawl as a single MCP server (streamable-http).
# Image: metacoma/donsetch — release binary from GitHub + chromium (tier-2
# solve-and-bounce), built manually on the gitops node and pushed to Docker Hub.

_config = cfg.config
mcp = _config.mcp
_name = "donsetch"
_image = "metacoma/donsetch:v3.6.7"
_port = 8097

manifests = [
  # Cache PVC (fetch/search cache, cookies vault, learned domain state)
  k8s.PersistentVolumeClaim {
    metadata = {
      name = "donsetch-cache"
      namespace = mcp.namespace
    }
    spec = {
      accessModes = ["ReadWriteOnce"]
      resources = {
        requests = {storage = "2Gi"}
      }
      storageClassName = _config.storageClass
    }
  }

  # Deployment
  v1.Deployment {
    metadata = {
      name = _name
      namespace = mcp.namespace
      labels = {
        "app": _name
      }
    }
    spec = {
      replicas = 1
      selector = {
        matchLabels = {
          "app": _name
        }
      }
      template = {
        metadata = {
          labels = {
            "app": _name
          }
        }
        spec = {
          dnsPolicy = "ClusterFirst"
          dnsConfig = {
            nameservers = ["172.25.1.9", "172.25.0.2"]
          }
          containers = [
            {
              name = _name
              image = _image
              env = [
                {
                  name = "NO_COLOR"
                  value = "1"
                }
                {
                  name = "HOME"
                  value = "/home/donsetch"
                }
              ]
              ports = [
                {
                  containerPort = _port
                }
              ]
              resources = {
                requests = {
                  cpu = "200m"
                  memory = "512Mi"
                }
                limits = {
                  cpu = "2"
                  memory = "4Gi"
                }
              }
              volumeMounts = [
                {
                  name = "cache"
                  mountPath = "/home/donsetch"
                }
              ]
            }
          ]
          volumes = [
            {
              name = "cache"
              persistentVolumeClaim = {
                claimName = "donsetch-cache"
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
      name = _name
      namespace = mcp.namespace
    }
    spec = {
      selector = {
        "app": _name
      }
      ports = [
        {
          port = 80
          targetPort = _port
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
      name = _name + "-ingress"
      namespace = mcp.namespace
      annotations = {
        "kubernetes.io/ingress.class" = "nginx"
        # donsetch streams MCP responses; keep buffering off like litellm
        "nginx.ingress.kubernetes.io/proxy-buffering" = "off"
      }
    }
    spec = {
      tls = [
        {
          hosts = ["donsetch-mcp." + _config.cert_manager.managed_domain]
          secretName = "mansion-net-tls"
        }
      ]
      rules = [
        {
          host = "donsetch-mcp." + _config.cert_manager.managed_domain
          http = {
            paths = [
              {
                path = "/"
                pathType = "Prefix"
                backend = {
                  service = {
                    name = _name
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
