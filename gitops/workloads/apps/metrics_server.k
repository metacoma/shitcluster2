import k8s.api.core.v1 as k8s
import config as cfg
import ..argoproj.v1alpha1 as argoproj
import yaml

_config = cfg.config
ms = _config.metrics_server

# Helper for ArgoCD Application
app_manifest = lambda helm : any, values : any -> argoproj.Application {
  argoproj.Application {
    metadata = {
      name = helm.release_name
      namespace = _config.argocd.namespace
    }
    spec = {
      destination = {
        namespace = ms.namespace
        name = "in-cluster"
      }
      project = "default"
      source = {
        chart = helm.chart_name
        repoURL = helm.repo
        targetRevision = helm.chart_version
        helm = {
          values = yaml.encode(values)
        }
      }
      syncPolicy = {
        automated = {
          selfHeal = True
        }
      }
    }
  }
}

manifests = [
  app_manifest(
    ms.helm,
    values = {
      replicas = 1
      metrics.enabled = True
      serviceMonitor.enabled = False
      podDisruptionBudget.enabled = False
      addonResizer = {
        enabled = True
        nanny = {
          cpu = "50m"
          extraCpu = "5m"
          memory = "100Mi"
          extraMemory = "10Mi"
          minClusterSize = 1
        }
      }
      resources.requests = {
        cpu = "50m"
        memory = "100Mi"
      }
      args = ["--kubelet-insecure-tls"]
      nodeSelector = {
        "node-role.kubernetes.io/control-plane" = ""
      }
      tolerations = [
        {
          key = "node-role.kubernetes.io/control-plane"
          operator = "Exists"
          effect = "NoSchedule"
        }
        {
          key = "node.kubernetes.io/not-ready"
          operator = "Exists"
          effect = "NoExecute"
        }
        {
          key = "node.kubernetes.io/unreachable"
          operator = "Exists"
          effect = "NoExecute"
        }
      ]
    }
  )
]
