import k8s.api.core.v1 as k8s
import k8s.api.apps.v1 as v1
import config as cfg

_config = cfg.config
mcp = _config.mcp
hound = mcp.hound_mcp

manifests = [
  # Cache PVC
  k8s.PersistentVolumeClaim {
    metadata = {
      name = "hound-cache"
      namespace = mcp.namespace
    }
    spec = {
      accessModes = ["ReadWriteOnce"]
      resources = {
        requests = {
          storage = "1Gi"
        }
      }
      storageClassName = _config.storageClass
    }
  }

  # Deployment
  v1.Deployment {
    metadata = {
      name = "hound-mcp"
      namespace = mcp.namespace
      labels = {
        "app": "hound-mcp"
      }
    }
    spec = {
      replicas = 1
      selector = {
        matchLabels = {
          "app": "hound-mcp"
        }
      }
      template = {
        metadata = {
          labels = {
            "app": "hound-mcp"
          }
        }
        spec = {
          dnsPolicy = "ClusterFirst"
          dnsConfig = {
            nameservers = ["172.25.1.9", "172.25.0.2"]
          }
          containers = [
            {
              name = "hound-mcp"
              image = hound.image
              env = [
                {
                  name = "NO_COLOR"
                  value = "1"
                }
              ]
              ports = [
                {
                  containerPort = hound.port
                }
              ]
              resources = {
                requests = {
                  cpu = "200m"
                  memory = "2Gi"
                }
                limits = {
                  cpu = "1"
                  memory = "5Gi"
                }
              }
              volumeMounts = [
                {
                  name = "shm"
                  mountPath = "/dev/shm"
                }
                {
                  name = "cache"
                  mountPath = "/home/hound/.hound"
                }
              ]
            }
          ]
          volumes = [
            {
              name = "shm"
              emptyDir = {
                medium = "Memory"
                sizeLimit = "1Gi"
              }
            }
            {
              name = "cache"
              persistentVolumeClaim = {
                claimName = "hound-cache"
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
      name = "hound-mcp"
      namespace = mcp.namespace
    }
    spec = {
      selector = {
        "app": "hound-mcp"
      }
      ports = [
        {
          port = 80
          targetPort = hound.port
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
      name = "hound-mcp-ingress"
      namespace = mcp.namespace
      annotations = {
        "kubernetes.io/ingress.class" = "nginx"
      }
    }
    spec = {
      tls = [
        {
          hosts = ["hound-mcp." + _config.cert_manager.managed_domain]
          secretName = "mansion-net-tls"
        }
      ]
      rules = [
        {
          host = "hound-mcp." + _config.cert_manager.managed_domain
          http = {
            paths = [
              {
                path = "/"
                pathType = "Prefix"
                backend = {
                  service = {
                    name = "hound-mcp"
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
