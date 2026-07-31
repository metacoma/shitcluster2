import k8s.api.core.v1 as k8core
import argoproj.v1alpha1 as argoproj
import kubevirt.v1.k8s_cni_cncf_io_v1_network_attachment_definition as network_attach
import yaml
import json
import manifests
import .apps.ssh_tunnel as ssh_tunnel
import .apps.monitoring as monitoring
import .apps.observability as observability
import .apps.istio as istio
import .apps.knative as knative
import .apps.vector as vector
import .apps.nats as nats
import .apps.eventing_jsm as eventing_jsm
import .apps.spaceship_dns as spaceship_dns
import .apps.ingress_nginx as ingress_nginx
import .apps.wireguard as wireguard

resources = [
    #    argoproj.Application {
    #        metadata = {
    #            name = "reflector"
    #            namespace = "argocd"
    #        }
    #        spec = {
    #            destination = {
    #                namespace = "reflector"
    #                name = "in-cluster"
    #            }
    #            project = "default"
    #            source = {
    #                chart = "reflector"
    #                repoURL = "oci://ghcr.io/emberstack/helm-charts/reflector"
    #                targetRevision = "9.1.39"
    #                helm = {
    #                    values = yaml.encode({
    #                      nodeSelector = {
    #                        "node-role.kubernetes.io/worker": ""
    #                      }
    #                    })
    #                    releaseName = "reflector"
    #                }
    #            }
    #            syncPolicy = {
    #                automated = {
    #                    selfHeal = True
    #                }
    #                syncOptions = [
    #                    "CreateNamespace=true"
    #                ]
    #            }
    #        }
    #    }
    
    #    argoproj.Application {
    #        metadata = {
    #            name = "cert-manager"
    #            namespace = "argocd"
    #        }
    #        spec = {
    #            destination = {
    #                namespace = "cert-manager"
    #                name = "in-cluster"
    #            }
    #            project = "default"
    #            source = {
    #                chart = "cert-manager"
    #                repoURL = "https://charts.jetstack.io"
    #                targetRevision = "1.19.1"
    #                helm = {
    #                    values = yaml.encode({
    #                      installCRDs = True
    #
    #                      dns01RecursiveNameservers: "172.24.0.2:53,8.8.8.8:53"
    #                      podAnnotations = {
    #                        "k8s.v1.cni.cncf.io/networks" = json.encode([
    #                          {
    #                            "name" = "macvlan-management-cert-manager",
    #                            "interface" = "net1",
    #                            "ips" = ["172.24.1.2/24"]
    #                          }])
    #                      }
    #
    #                      nodeSelector = {
    #                        "node-role.kubernetes.io/worker" = ""
    #                      }
    #
    #                      webhook.nodeSelector = {
    #                        "node-role.kubernetes.io/worker" = ""
    #                      }
    #
    #                      cainjector.nodeSelector = {
    #                        "node-role.kubernetes.io/worker" = ""
    #                      }
    #
    #                      startupapicheck.nodeSelector = {
    #                        "node-role.kubernetes.io/worker" = ""
    #                      }
    #
    #                    })
    #                    releaseName = "cert-manager"
    #                }
    #            }
    #            syncPolicy = {
    #                automated = {
    #                    selfHeal = True
    #                }
    #                syncOptions = [
    #                    "CreateNamespace=true"
    #                ]
    #            }
    #        }
    #    }
    ssh_tunnel.manifests
    monitoring.manifests
    observability.manifests
    knative.manifests
    istio.manifests
    vector.manifests
    nats.manifests
    eventing_jsm.manifests
    spaceship_dns.manifests
    ingress_nginx.manifests
    wireguard.manifests
]

manifests.yaml_stream([
    resources
])
