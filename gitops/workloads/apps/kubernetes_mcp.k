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
      name = k8s_mcp.helm.release_name
      namespace = _config.argocd.namespace
    }
    spec = {
      project = "default"
      source = {
        chart = k8s_mcp.helm.chart
        repoURL = k8s_mcp.helm.repo
        targetRevision = k8s_mcp.helm.version
        helm = {
          values = yaml.encode({
            replicaCount = 1
            serviceAccount = { create = True }
            rbac = { create = True }
            ingress = {
              enabled = True
              host = k8s_mcp.prefix + "." + _config.cert_manager.managed_domain
              tls = {
                secretName = "mansion-net-tls"
              }
            }
            metrics = {
              serviceMonitor = {
                enabled = True
                labels = { "release": k8s_mcp.helm.release_name }
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
]
