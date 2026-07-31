import k8s.api.core.v1 as k8s
import config as cfg
import argoproj.v1alpha1 as argoproj
import yaml

_config = cfg.config
ph = _config.pihole

manifests = [
  k8s.Namespace {
    metadata.name = ph.namespace
  }

  argoproj.Application {
    metadata = {
        name = ph.helm.release_name
        namespace = _config.argocd.namespace
    }
    spec = {
        destination = {
            namespace = ph.namespace
            name = "in-cluster"
        }
        project = "default"
        source = {
            chart = ph.helm.chart_name
            repoURL = ph.helm.repo
            targetRevision = ph.helm.chart_version
            helm = {
              values = yaml.encode({
                # Basic Configuration
                replicaCount = 1
                adminPassword = ph.adminPassword
                
                # Upstream DNS (our dnscrypt-proxy)
                DNS1 = ph.upstreamDns
                DNS2 = ""
                
                # Network Settings
                serviceDns = {
                  type = "LoadBalancer"
                  loadBalancerIP = ph.loadBalancerIP
                  mixedService = True
                  externalTrafficPolicy = "Local"
                }
                
                # Storage (Longhorn)
                persistentVolumeClaim = {
                  enabled = True
                  storageClass = _config.storageClass
                  size = "1Gi"
                }

                # Adlists - Conservative set for non-tech users
                adlists = [
                  "https://big.oisd.nl",
                  "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
                ]

                # Monitoring
                monitoring = {
                  sidecar = {
                    enabled = True
                  }
                  podMonitor = {
                    enabled = True
                  }
                }

                # Resource limits and scheduling
                resources = {
                  limits = {
                    cpu = "200m"
                    memory = "256Mi"
                  }
                  requests = {
                    cpu = "100m"
                    memory = "128Mi"
                  }
                }
                nodeSelector = _config.nodeSelector.worker
                extraEnvVars = {
                  DNSMASQ_USER = "root"
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
