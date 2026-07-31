import k8s.api.core.v1 as k8s
import config as cfg
import argoproj.v1alpha1 as argoproj
import yaml

_config = cfg.config
dp = _config.dnscrypt_proxy

# Custom dnscrypt-proxy configuration
# This is a high-quality default focusing on DoH and privacy
dns_config = """
listen_addresses = ['0.0.0.0:5353']
server_names = ['cloudflare', 'google']
# Use only DoH if possible
doh_servers = true
# Server must support DNS security extensions (DNSSEC)
require_dnssec = true
# Cache settings for performance
cache = true
cache_size = 2048

[sources]
  [sources.public-resolvers]
    urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md', 'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md']
    cache_file = 'public-resolvers.md'
    minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
    refresh_delay = 72
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
                configmap = {
                  config = {
                    enabled = True
                    data = {
                      "dnscrypt-proxy.toml": dns_config
                    }
                  }
                }
                # Ensure it runs on worker nodes
                nodeSelector = _config.nodeSelector.worker
                service = {
                  main = {
                    enabled = True
                    type = "LoadBalancer"
                    loadBalancerIP = "172.25.1.8"
                    ports = {
                      "dns-tcp" = {
                        enabled = True
                        port = 53
                        targetPort = 5353
                        protocol = "TCP"
                      }
                      "dns-udp" = {
                        enabled = True
                        port = 53
                        targetPort = 5353
                        protocol = "UDP"
                      }
                      "http" = {
                        enabled = True
                        port = 8080
                        targetPort = 8080
                        protocol = "TCP"
                      }
                    }
                  }
                  "dns-udp" = {
                    enabled = False
                  }
                  "dns-tcp" = {
                    enabled = False
                  }
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
