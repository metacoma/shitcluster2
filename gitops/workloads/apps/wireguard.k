import k8s.api.core.v1 as k8s
import config as cfg
import ..argoproj.v1alpha1 as argoproj
import yaml

_config = cfg.config
wg = _config.wireguard

# List of peers stored in Vault (split into pk and ip)
peers_data = [
    {"pk": "ref+vault://kv/wireguard#peer_1_pk", "ip": "ref+vault://kv/wireguard#peer_1_ip"},
    {"pk": "ref+vault://kv/wireguard#peer_2_pk", "ip": "ref+vault://kv/wireguard#peer_2_ip"},
    {"pk": "ref+vault://kv/wireguard#peer_3_pk", "ip": "ref+vault://kv/wireguard#peer_3_ip"},
    {"pk": "ref+vault://kv/wireguard#peer_4_pk", "ip": "ref+vault://kv/wireguard#peer_4_ip"},
    {"pk": "ref+vault://kv/wireguard#peer_5_pk", "ip": "ref+vault://kv/wireguard#peer_5_ip"},
    {"pk": "ref+vault://kv/wireguard#peer_6_pk", "ip": "ref+vault://kv/wireguard#peer_6_ip"},
]

# Map to Helm chart client format
clients = [
    {
        "PublicKey": p.pk, 
        "AllowedIPs": p.ip
    } for p in peers_data
]

# Generate peer configs using a list comprehension and join
peer_configs = "".join([ "\n[Peer]\nPublicKey = " + c.PublicKey + "\nAllowedIPs = " + c.AllowedIPs + "\n" for c in clients])

wg0_conf = "[Interface]\nAddress = " + wg.server_address + "\nListenPort = 51820\nTable = off\nPostUp = wg set wg0 private-key /etc/wireguard/privatekey && iptables -t nat -A POSTROUTING -s " + wg.server_cidr + " -o eth0 -j MASQUERADE\nPostDown = iptables -t nat -D POSTROUTING -s " + wg.server_cidr + " -o eth0 -j MASQUERADE\n" + peer_configs

manifests = [
  k8s.Namespace {
    metadata.name = "network" # Using the same namespace as ssh_tunnel
  }
  # Secret holding the server private key, used by the chart via secretName
  k8s.Secret {
    metadata = {
        name = "wireguard-server-key"
        namespace = "network"
    }
    type = "Opaque"
    stringData = {
        "privatekey": "ref+vault://kv/wireguard#server_private_key"
    }
  }
  # Custom config secret to fix routing loop (Table = off)
  k8s.Secret {
    metadata = {
        name = "wireguard-vpn-wg-config"
        namespace = "network"
    }
    type = "Opaque"
    stringData = {
        "wg0.conf": wg0_conf
    }
  }
  argoproj.Application {
    metadata = {
        name = "wireguard-vpn"
        namespace = "argocd"
    }
    spec = {
        destination = {
            namespace = "network"
            name = "in-cluster"
        }
        project = "default"
        source = {
            chart = "wireguard"
            repoURL = "https://bryopsida.github.io/wireguard-chart"
            targetRevision = "0.23.0"
            helm = {
                values = yaml.encode({
                      replicaCount = 1
                      autoscaling = { enabled = False }
                      service = {
                        type = "LoadBalancer"
                        loadBalancerIP = wg.lb_ip
                        port = wg.port
                      }
                      securityContext = {
                          privileged = True
                      }
                      wireguard = {
                          serverAddress = wg.server_address
                          serverCidr = wg.server_cidr
                          clients = clients
                      }
                      secretName = "wireguard-server-key"
                      disableConfigManagement = True
                    })
                releaseName = "wireguard-vpn"
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
