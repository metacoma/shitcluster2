import k8s.api.core.v1 as k8s
import config as cfg
import argoproj.v1alpha1 as argoproj
import yaml

_config = cfg.config
af = _config.antifilter

manifests = [
  k8s.Namespace {
    metadata.name = af.namespace
  }

  argoproj.Application {
    metadata = {
        name = af.helm.release_name
        namespace = _config.argocd.namespace
    }
    spec = {
        destination = {
            namespace = af.namespace
            name = "in-cluster"
        }
        project = "default"
        source = {
            chart = af.helm.chart_name
            repoURL = af.helm.repo
            targetRevision = af.helm.chart_version
            helm = {
              values = yaml.encode({
                frrk8s = {
                  # Ensure the daemonset runs on appropriate nodes
                  nodeSelector = _config.nodeSelector.worker
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

  # BGP Configuration via FRRConfiguration CRD
  {
    apiVersion = "frrk8s.metallb.io/v1beta1"
    kind = "FRRConfiguration"
    metadata = {
        name = "bgp-peerings"
        namespace = af.namespace
    }
    spec = {
        bgp = {
            routers = [
                {
                    as = peer.localAs
                    neighbors = [
                        {
                            address = peer.neighborIp
                            remoteAs = peer.remoteAs
                            holdTime = str(peer.holdTime)
                            ebgpMultiHop = peer.multihop
                        }
                    ]
                } for peer in af.bgpPeers
            ]
        }
    }
  }
]
