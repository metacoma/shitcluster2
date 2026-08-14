import k8s.api.core.v1 as k8s
import k8s.api.apps.v1 as v1
import config as cfg
import json

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

startup_script = """set -e
wget -q -O /tmp/sb.tar.gz ${_vt.download_url}
mkdir -p /opt/singbox
tar xzf /tmp/sb.tar.gz -C /opt/singbox --strip-components=1
exec /opt/singbox/sing-box run -c /etc/sing-box/config.json
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
                }
                spec = {
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
