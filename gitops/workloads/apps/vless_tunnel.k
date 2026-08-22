import k8s.api.core.v1 as k8s
import k8s.api.apps.v1 as v1
import config as cfg
import json
import kubevirt.v1.k8s_cni_cncf_io_v1_network_attachment_definition as network_attach

_config = cfg.config
_vt = _config.vless_tunnel

app_name = "vless-tunnel"
configmap_name = "singbox-config"

# sing-box client config (VLESS + REALITY + XHTTP + TUN).
# No DNS section on purpose: pod DNS goes through cluster coredns (direct rule below).
# Secrets are resolved by vals at render time (ref+vault://).
singbox_config = {
    "log": {"level": "info"},
    "inbounds": [{
        "type": "tun",
        "tag": "tun-in",
        "interface_name": "singtun",
        "address": [_vt.tun_address],
        "auto_route": True,
        "strict_route": True,
        "stack": "system",
    }],
    "outbounds": [
        {
            "type": "vless",
            "tag": "vless-out",
            "server": _vt.server,
            "server_port": _vt.server_port,
            "uuid": _vt.reality.uuid,
            "tls": {
                "enabled": True,
                "server_name": _vt.reality.server_name,
                "utls": {"enabled": True, "fingerprint": "chrome"},
                "reality": {
                    "enabled": True,
                    "public_key": _vt.reality.public_key,
                    "short_id": _vt.reality.short_id,
                },
            },
            "transport": {
                "type": "xhttp",
                "host": _vt.reality.host,
                "path": _vt.reality.path,
                "mode": "auto",
            },
        },
        {"type": "direct", "tag": "direct"},
    ],
    "route": {
        "auto_detect_interface": True,
        # keep cluster + private networks direct so pod DNS / cluster traffic is unaffected
        "rules": [
            {
                "ip_cidr": ["10.233.0.0/16", "172.16.0.0/12", "192.168.0.0/16", _vt.tun_cidr],
                "outbound": "direct",
            }
        ],
    },
}

nad_name = "vless-tunnel-public"

startup_script = """set -e
# wait for the Multus public interface (CNI attaches before container start)
for i in 1 2 3 4 5; do [ -d /sys/class/net/public ] && break; sleep 1; done
# like ssh_tunnel: keep cluster reachable via Calico, default via public gw
ip route add 10.233.0.0/16 via 169.254.1.1 dev eth0 2>/dev/null || true
ip route del default via 169.254.1.1 2>/dev/null || true
ip route add default via ${_vt.public.gw} dev public
# the VLESS carrier (server) must bypass the tun: high-priority rule -> main table
ip rule add priority 100 to ${_vt.server} lookup main 2>/dev/null || true
# gateway mode (like ssh_tunnel): forward + NAT traffic from the public network into the tunnel
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.all.forwarding=1
iptables -t nat -A POSTROUTING -o singtun -j MASQUERADE 2>/dev/null || true
# forwarded packets arriving on the public interface go into the tun (table 2022)
ip rule add priority 150 iif public lookup 2022 2>/dev/null || true
exec sing-box run -c /etc/sing-box/config.json
"""

manifests = [
    k8s.Namespace {
        metadata.name = _vt.namespace
    }
    k8s.ConfigMap {
        metadata = {
            name = configmap_name
            namespace = _vt.namespace
        }
        data = {
            "config.json": json.encode(singbox_config)
        }
    }
    network_attach.NetworkAttachmentDefinition {
        metadata = {
            name = nad_name
            namespace = _vt.namespace
        }
        spec = {
            config = json.encode({
                cniVersion = "0.3.1"
                type = "bridge"
                bridge = "br-public"
                hairpinMode = True
                ipam = {
                    type = "static"
                    addresses = [{
                        address = _vt.public.ip
                        gateway = _vt.public.gw
                    }]
                    capabilities.macs = True
                }
            })
        }
    }
    v1.Deployment {
        metadata = {
            name = app_name
            namespace = _vt.namespace
            labels = {
                app = app_name
            }
        }
        spec = {
            replicas = 1
            selector = {
                matchLabels = {
                    app = app_name
                }
            }
            template = {
                metadata = {
                    labels = {
                        app = app_name
                    }
                    annotations = {
                        "vless-tunnel.k/config-revision" = _vt.config_revision
                        "k8s.v1.cni.cncf.io/networks" = json.encode([
                            {
                                name = nad_name
                                namespace = _vt.namespace
                                interface = "public"
                            }
                        ])
                    }
                }
                spec = {
                    dnsPolicy = "None"
                    dnsConfig = {
                        nameservers = ["172.25.0.2", "172.25.0.1"]
                    }
                    nodeSelector = _config.nodeSelector.controller
                    tolerations = [
                        {
                            key = "node-role.kubernetes.io/control-plane"
                            operator = "Exists"
                            effect = "NoSchedule"
                        }
                        {
                            key = "node.longhorn.io/storage"
                            operator = "Exists"
                            effect = "NoSchedule"
                        }
                    ]
                    containers = [{
                        name = "singbox"
                        image = _vt.image
                        imagePullPolicy = "IfNotPresent"
                        command = ["/bin/sh", "-c"]
                        args = [startup_script]
                        securityContext = {
                            privileged = True
                        }
                        volumeMounts = [{
                            name = "config"
                            mountPath = "/etc/sing-box"
                            readOnly = True
                        }]
                    }]
                    volumes = [{
                        name = "config"
                        configMap = {
                            name = configmap_name
                        }
                    }]
                }
            }
        }
    }
]
