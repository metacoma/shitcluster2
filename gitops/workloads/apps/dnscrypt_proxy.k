import k8s.api.core.v1 as k8s
import config as cfg
import argoproj.v1alpha1 as argoproj
import yaml

_config = cfg.config
dp = _config.dnscrypt_proxy

# Custom dnscrypt-proxy configuration
# This is a high-quality default focusing on DoH and privacy
dns_config = """
listen_addresses = ['0.0.0.0:53']
server_names = ['cloudflare', 'google']
# Use only DoH if possible
doh_servers = true
# Enable DNSSEC validation
dnssec = true
# Cache settings for performance
cache = true
cache_size = 2048
"""

manifests = [
  k8s.Namespace {
    metadata.name = dp.namespace
  }

  argoproj.Application {
    metadata = {
        name = dp.helm.release_name
        namespace = _config.argocd.namespace
    }
    spec = {
        destination = {
            namespace = dp.namespace
            name = "in-cluster"
        }
        project = "default"
        source = {
            chart = dp.helm.chart_name
            repoURL = dp.helm.repo
            targetRevision = dp.helm.chart_version
            helm = {
              values = yaml.encode({
                config = dns_config
                # Ensure it runs on worker nodes
                nodeSelector = _config.nodeSelector.worker
                service = {
                  type = "LoadBalancer"
                  loadBalancerIP = "172.25.1.8"
                }
              })
            }
        }
        syncPolicy = {
            automated = {
                selfHeal = True
            }
        }
    }
  }
]
