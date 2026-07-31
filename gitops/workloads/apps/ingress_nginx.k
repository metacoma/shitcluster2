import k8s.api.core.v1 as k8s
import config as cfg
import ..argoproj.v1alpha1 as argoproj
import yaml

_config = cfg.config
ingress_nginx = _config.ingress_nginx

ingress_app = lambda helm : any, values : any, sync : any -> argoproj.Application {
  argoproj.Application {
    metadata = {
        name = helm.release_name
        namespace = _config.argocd.namespace
    }
    spec = {
        destination = {
            namespace = ingress_nginx.namespace
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
        } | sync
    }
  }
}

manifests = [

  k8s.Namespace {
    metadata.name = ingress_nginx.namespace
  }

  ingress_app(
    ingress_nginx.helm, 
    values = {
      controller = {
        nodeSelector = _config.nodeSelector.worker
        service = {
          loadBalancerIP = ingress_nginx.ingress_lb
        }
      }
    },
    sync = {}
  )

]
