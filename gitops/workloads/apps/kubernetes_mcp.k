import k8s.api.core.v1 as k8s
import ..argoproj.v1alpha1 as argoproj
import config as cfg
import yaml

_config = cfg.config
mcp = _config.mcp
k8s_mcp = mcp.k8s_mcp

manifests = [
  # ArgoCD Application for Helm Chart
  argoproj.Application {
    metadata = {
      name = "kubernetes-mcp-server"
      namespace = _config.argocd.namespace
    }
    spec = {
      project = "default"
      source = {
        chart = "kubernetes-mcp-server"
        repoURL = "oci://ghcr.io/containers/charts"
        targetRevision = "0.1.0"
        helm = {
          values = yaml.encode({
            replicaCount = 1
            serviceAccount = { create = True }
            rbac = { create = True }
            ingress = { enabled = False }
            metrics = {
              serviceMonitor = {
                enabled = True
                labels = { "release": "kubernetes-mcp-server" }
              }
            }
          })
        }
      }
      destination = {
        server = "https://kubernetes.default.svc"
        namespace = mcp.namespace
      }
      syncPolicy = {
        automated = { prune = True, selfHeal = True }
      }
    }
  }

  # Ingress (following hound-mcp pattern)
  {
    apiVersion = "networking.k8s.io/v1"
    kind = "Ingress"
    metadata = {
      name = "kubernetes-mcp-ingress"
      namespace = mcp.namespace
      annotations = {
        "kubernetes.io/ingress.class" = "nginx"
      }
    }
    spec = {
      tls = [
        {
          hosts = [k8s_mcp.ingress_host]
          secretName = "mansion-net-tls"
        }
      ]
      rules = [
        {
          host = k8s_mcp.ingress_host
          http = {
            paths = [
              {
                path = "/"
                pathType = "Prefix"
                backend = {
                  service = {
                    name = "kubernetes-mcp-server"
                    port = {
                      number = 8080
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
