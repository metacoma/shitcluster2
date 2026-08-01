import k8s.api.core.v1 as k8s
import config as cfg
import ..argoproj.v1alpha1 as argoproj
import yaml

_config = cfg.config
reflector = _config.reflector

# Helper for ArgoCD Application
app_manifest = lambda helm : any, values : any -> argoproj.Application {
  argoproj.Application {
    metadata = {
        name = helm.release_name
        namespace = _config.argocd.namespace
    }
    spec = {
        destination = {
            namespace = reflector.namespace
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
            syncOptions = [
                "CreateNamespace=true"
            ]
        }
    }
  }
}

manifests = [
  # 1. Namespace
  k8s.Namespace {
    metadata = {
      name = reflector.namespace
    }
  }

  # 2. Helm Installation via ArgoCD
  app_manifest(
    reflector.helm, 
    values = {
      nodeSelector = {
        "node-role.kubernetes.io/worker": ""
      }
    }
  )
]
