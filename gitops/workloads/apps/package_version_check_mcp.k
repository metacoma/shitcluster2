import k8s.api.core.v1 as k8s
import k8s.api.apps.v1 as v1
import config as cfg

_config = cfg.config
mcp = _config.mcp
pkg_ver = mcp.package_version_check_mcp

manifests = [
  # Deployment
  v1.Deployment {
    metadata = {
      name = "package-version-check-mcp"
      namespace = mcp.namespace
      labels = {
        "app": "package-version-check-mcp"
      }
    }
    spec = {
      replicas = 1
      selector = {
        matchLabels = {
          "app": "package-version-check-mcp"
        }
      }
      template = {
        metadata = {
          labels = {
            "app": "package-version-check-mcp"
          }
        }
        spec = {
          containers = [
            {
              name = "package-version-check-mcp"
              image = pkg_ver.image
              ports = [
                {
                  containerPort = pkg_ver.port
                }
              ]
              livenessProbe = {
                httpGet = {
                  path = "/health"
                  port = pkg_ver.port
                }
                initialDelaySeconds = 10
                periodSeconds = 30
              }
              readinessProbe = {
                httpGet = {
                  path = "/health"
                  port = pkg_ver.port
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
      name = "package-version-check-mcp"
      namespace = mcp.namespace
    }
    spec = {
      selector = {
        "app": "package-version-check-mcp"
      }
      ports = [
        {
          port = 80
          targetPort = pkg_ver.port
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
      name = "package-version-check-mcp-ingress"
      namespace = mcp.namespace
      annotations = {
        "kubernetes.io/ingress.class" = "nginx"
      }
    }
    spec = {
      tls = [
        {
          hosts = ["pkgver-mcp." + _config.cert_manager.managed_domain]
          secretName = "mansion-net-tls"
        }
      ]
      rules = [
        {
          host = "pkgver-mcp." + _config.cert_manager.managed_domain
          http = {
            paths = [
              {
                path = "/"
                pathType = "Prefix"
                backend = {
                  service = {
                    name = "package-version-check-mcp"
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
