import k8s.api.core.v1 as k8s
import ..argoproj.v1alpha1 as argoproj
import config as cfg
import yaml
import victoria_metrics_operator.v1beta1.operator_victoriametrics_com_v1beta1_vm_service_scrape as vm_service_scrape

_config = cfg.config
mcp = _config.mcp
k8s_mcp = mcp.k8s_mcp

# Construct final values by combining static config and dynamic properties
chart_values = {
  replicaCount = k8s_mcp.values.replicaCount
  serviceAccount = k8s_mcp.values.serviceAccount
  rbac = k8s_mcp.values.rbac
  ingress = {
    enabled = k8s_mcp.values.ingress.enabled
    host = k8s_mcp.prefix + "." + _config.cert_manager.managed_domain
    tls = k8s_mcp.values.ingress.tls
  }
  metrics = {
    serviceMonitor = {
      enabled = k8s_mcp.values.metrics.serviceMonitor.enabled
      labels = { "release": k8s_mcp.helm.release_name }
    }
  }
}

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
          values = yaml.encode(chart_values)
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
  },

  # VictoriaMetrics scrape resource
  vm_service_scrape.VMServiceScrape {
    metadata = {
      name = k8s_mcp.helm.release_name + "-metrics"
      namespace = mcp.namespace
    }
    spec = {
      selector.matchLabels = {
        "app.kubernetes.io/name" = k8s_mcp.helm.release_name
      }
      endpoints = [{
        port = "http"
        interval = "30s"
      }]
    }
  }
]
