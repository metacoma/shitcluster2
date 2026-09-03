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
import .apps.bird as bird
import .apps.vless_tunnel as vless_tunnel
import .apps.cert_manager as cert_manager
import .apps.reflector as reflector
import .apps.mcphub as mcphub
# import .apps.ddgs as ddgs
import .apps.kubernetes_mcp as kubernetes_mcp
import .apps.hound_mcp as hound_mcp
import .apps.github_mcp as github_mcp
import .apps.grafana_mcp as grafana_mcp
import .apps.helm_mcp as helm_mcp
import .apps.artifacthub_mcp as artifacthub_mcp
import .apps.package_version_check_mcp as package_version_check_mcp
import .apps.tei as tei
import .apps.forgejo as forgejo
import .apps.litellm as litellm
import .apps.mattermost as mattermost
import .apps.pongbot as pongbot
import .apps.pi_agent as pi_agent
# temporarily disabled (2026-08-09): desktop setup testing
# import .apps.opencode_agent as opencode_agent
# import .apps.opencode_mattermost_bridge as opencode_mattermost_bridge

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
    bird.manifests
    vless_tunnel.manifests
    cert_manager.manifests
    mcphub.manifests
    # ddgs.manifests
    kubernetes_mcp.manifests
    hound_mcp.manifests
    github_mcp.manifests
    grafana_mcp.manifests
    helm_mcp.manifests
    artifacthub_mcp.manifests
    package_version_check_mcp.manifests
    tei.manifests
    forgejo.manifests
    litellm.manifests
    mattermost.manifests
    pongbot.manifests
    pi_agent.manifests
    # opencode_agent.manifests
    # opencode_mattermost_bridge.manifests
]

manifests.yaml_stream([
    resources
])
