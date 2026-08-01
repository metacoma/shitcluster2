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
        name = "frr-bgp-config"
        namespace = af.namespace
    }
    spec = {
        bgp = {
            routers = [
                {
                    asn = 64512
                    neighbors = [
                        {
                            address = peer.neighborIp
                            asn = peer.remoteAs
                            holdTime = str(peer.holdTime) + "s"
                            keepaliveTime = str(peer.holdTime // 3) + "s"
                            ebgpMultiHop = peer.multihop
                        } for peer in af.bgpPeers
                    ]
                }
            ]
        }
        raw = {
            priority = 100
            rawConfig = """
ip prefix-list BIRD-ANTIFILTER-IN seq 10 deny 2.56.206.0/24
ip prefix-list BIRD-ANTIFILTER-IN seq 20 permit 0.0.0.0/0 le 32

route-map BIRD-ANTIFILTER-IN permit 10
 match ip address prefix-list BIRD-ANTIFILTER-IN
exit

route-map BIRD-ANTIFILTER-OUT deny 10
exit

router bgp 64512
 neighbor 45.154.73.71 local-as 65542 no-prepend replace-as
 !
 address-family ipv4 unicast
  neighbor 45.154.73.71 route-map BIRD-ANTIFILTER-IN in
  neighbor 45.154.73.71 route-map BIRD-ANTIFILTER-OUT out
  neighbor 172.25.0.1 route-map BIRD-ANTIFILTER-IN in
  neighbor 172.25.0.1 route-map BIRD-ANTIFILTER-OUT out
 exit-address-family
exit
"""
        }
    }
  }
]
