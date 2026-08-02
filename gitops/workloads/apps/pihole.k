import k8s.api.core.v1 as k8s
import k8s.api.apps.v1 as v1
import config as cfg
import argoproj.v1alpha1 as argoproj
import yaml
import victoria_metrics_operator.v1beta1.operator_victoriametrics_com_v1beta1_vm_service_scrape as vm_service_scrape

_config = cfg.config
ph = _config.pihole

manifests = [
  k8s.Namespace {
    metadata.name = ph.namespace
  }

  # Shared Wildcard Certificate (Reflected from cert-manager namespace)
  k8s.Secret {
    metadata = {
      name = "mansion-net-tls"
      namespace = ph.namespace
      annotations = {
        "reflector.v1.k8s.emberstack.com/reflects" = "cert-manager/mansion-net-tls"
      }
    }
    type = "kubernetes.io/tls"
  }

  {
    apiVersion = "networking.k8s.io/v1"
    kind = "Ingress"
    metadata = {
      name = "pihole-ingress"
      namespace = ph.namespace
      annotations = {
        "kubernetes.io/ingress.class" = "nginx"
      }
    }
    spec = {
      tls = [
        {
          hosts = ["pihole." + _config.cert_manager.managed_domain]
          secretName = "mansion-net-tls"
        }
      ]
      rules = [
        {
          host = "pihole." + _config.cert_manager.managed_domain
          http = {
            paths = [
              {
                path = "/"
                pathType = "Prefix"
                backend = {
                  service = {
                    name = ph.helm.release_name + "-web"
                    port = {
                      number = 80
                    }
                  }
                }
              }
            ]
          }
        }
      ]
    }
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
                  annotations = {
                    "prometheus.io/scrape": "true"
                    "prometheus.io/port": "9617"
                  }
                }
                serviceDhcp = {
                  enabled = False
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
                    enabled = False
                  }
                }

                podAnnotations = {
                  "prometheus.io/scrape": "true"
                  "prometheus.io/port": "9617"
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

  vm_service_scrape.VMServiceScrape {
    metadata = {
      name = "pihole-metrics"
      namespace = ph.namespace
    }
    spec = {
      selector.matchLabels = {
        "app.kubernetes.io/name" = "pihole"
      }
      endpoints = [{
        port = "prometheus"
        interval = "30s"
      }]
    }
  }
]
