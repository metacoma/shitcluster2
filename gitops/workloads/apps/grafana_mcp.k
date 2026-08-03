import k8s.api.core.v1 as k8s
import ..argoproj.v1alpha1 as argoproj
import config as cfg
import yaml

_config = cfg.config
mcp = _config.mcp
grafana_mcp = mcp.grafana_mcp

chart_values = {
  replicaCount = 1
  image = {
    registry = "docker.io"
    repository = "grafana/mcp-grafana"
    tag = grafana_mcp.image.tag
  }
  grafana = {
    url = "https://grafana." + _config.cert_manager.managed_domain
  }
  env = {
    GRAFANA_USERNAME = "ref+vault://kv/grafana#adminUser"
    GRAFANA_PASSWORD = "ref+vault://kv/grafana#adminPassword"
  }
  extraArgs = ["--allowed-hosts=*", "--transport streamable-http"]
  service = {
    type = "ClusterIP"
    port = 8000
  }
  ingress = {
    enabled = True
    className = "nginx"
    hosts = [{
      host = grafana_mcp.name + "." + _config.cert_manager.managed_domain
      paths = [{ path = "/", pathType = "Prefix" }]
    }]
    tls = [{
      secretName = "mansion-net-tls"
      hosts = [grafana_mcp.name + "." + _config.cert_manager.managed_domain]
    }]
  }
  resources = {
    limits = { cpu = "200m", memory = "256Mi" }
    requests = { cpu = "100m", memory = "128Mi" }
  }
  nodeSelector = _config.nodeSelector.worker
}

manifests = [
  argoproj.Application {
    metadata = {
      name = grafana_mcp.helm.release_name
      namespace = _config.argocd.namespace
    }
    spec = {
      project = "default"
      source = {
        chart = grafana_mcp.helm.chart
        repoURL = grafana_mcp.helm.repo
        targetRevision = grafana_mcp.helm.version
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
  }
]
