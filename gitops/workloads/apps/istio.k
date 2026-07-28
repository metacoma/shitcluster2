import k8s.api.core.v1 as k8s
import k8s.api.apps.v1 as v1
import config as cfg
import ..argoproj.v1alpha1 as argoproj
import yaml

_config = cfg.config
istio = _config.istio

istio_app = lambda helm : any, values : any, sync : any -> argoproj.Application {
  argoproj.Application {
    metadata = {
        name = helm.release_name
        namespace = _config.argocd.namespace
    }
    spec = {
        destination = {
            namespace = istio.namespace
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
    metadata.name = istio.namespace
  }

  istio_app(
    istio.helm.istio_base, {}
    sync = {}
  ) | {
    spec.ignoreDifferences = [{
          group = "admissionregistration.k8s.io"
          kind = "ValidatingWebhookConfiguration"
          name = "istiod-default-validator"
          jsonPointers = ["/webhooks/0/failurePolicy"]
    }]
  }

  istio_app(
    istio.helm.istiod, values = {
      nodeSelector = _config.nodeSelector.worker
      global.proxy.clusterDomain = _config.k8s_domain
    }
    sync = {}
  )

  istio_app(
    istio.helm.gateway, values = {
      nodeSelector = _config.nodeSelector.worker
      global.proxy.clusterDomain = _config.k8s_domain
      image.tag = istio.helm.gateway.app_version
      service = {
        type = "LoadBalancer"
        loadBalancerIP = istio.gateway_lb
      }
    }
    sync = {}
  )

]
