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
import .apps.dnscrypt_proxy as dnscrypt_proxy
import .apps.pihole as pihole
import .apps.cert_manager as cert_manager
import .apps.reflector as reflector
import .apps.mcphub as mcphub
# import .apps.ddgs as ddgs
import .apps.hound_mcp as hound_mcp

resources = [
    ssh_tunnel.manifests
    reflector.manifests
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
    dnscrypt_proxy.manifests
    pihole.manifests
    cert_manager.manifests
    mcphub.manifests
    # ddgs.manifests
    hound_mcp.manifests
]

manifests.yaml_stream([
    resources
])
