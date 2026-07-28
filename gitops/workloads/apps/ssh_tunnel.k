import k8s.api.core.v1 as k8s
import k8s.api.apps.v1 as v1
import config as cfg
import json
import kubevirt.v1.k8s_cni_cncf_io_v1_network_attachment_definition as network_attach

_config = cfg.config
_ssh_tunnel = _config.ssh_tunnel

ssh_tunnel_resource_name = lambda endpoint -> str {
  "ssh-tunnel-${endpoint.name}"
}

ssh_tunnel_secret_name = lambda endpoint -> str {
  ssh_tunnel_resource_name(endpoint)
}

ssh_tunnel_private_key_secret_name = lambda endpoint -> str {
  ssh_tunnel_resource_name(endpoint) + "-private-key"
}

nad_name = ssh_tunnel_resource_name

makeDeployment = lambda endpoint : any -> v1.Deployment {
  v1.Deployment {
    metadata = {
      name = ssh_tunnel_resource_name(endpoint)
      namespace = _ssh_tunnel.namespace
      labels = {
        app = ssh_tunnel_resource_name(endpoint)
      }
    }
    spec = {
      selector.matchLabels = {app = ssh_tunnel_resource_name(endpoint) }
      template = {
        metadata = {
          labels.app = ssh_tunnel_resource_name(endpoint)
          annotations = {
            "k8s.v1.cni.cncf.io/networks" = json.encode([
              {
                name = nad_name(endpoint)
                namespace = _ssh_tunnel.namespace
                interface = "public"
              }
            ])
          }
        }
        spec = {
          dnsPolicy = "None"
          dnsConfig.nameservers = ["172.25.0.2", "172.25.0.1"]

          nodeSelector = _config.nodeSelector.controller
          tolerations = [
            {
              key = "node-role.kubernetes.io/control-plane"
              operator = "Exists"
              effect = "NoSchedule"
            },
            {
              key = "node.longhorn.io/storage"
              operator = "Exists"
              effect = "NoSchedule"
            }
          ]
          containers = [{
            name = ssh_tunnel_resource_name(endpoint)
            image = _ssh_tunnel.container_image
            imagePullPolicy = "IfNotPresent"
            command = ["/bin/bash"]
            args = ["-c", """
            sysctl -w net.ipv4.conf.all.forwarding=1
            IF=tun0
            ip tuntap add mode tun $IF
            ip addr add ${endpoint.local_addr} dev $IF
            ip link set tun0 up
            ssh ${_ssh_tunnel.ssh_args} -i /root/.ssh/private_key -l $SSH_TUNNEL_USER $SSH_TUNNEL_HOST '
              ip link del ${endpoint.remote_tun}
              ip tuntap add mode tun ${endpoint.remote_tun}
              ip addr add ${endpoint.remote_addr} dev ${endpoint.remote_tun}
              ip link set ${endpoint.remote_tun} up
              iptables -t nat -C POSTROUTING -s ${endpoint.local_addr} -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING -o eth0 -j MASQUERADE -s ${endpoint.local_addr}
            '
            VPN_ADDR=$(dig +short $SSH_TUNNEL_HOST)
            ip ro add to $VPN_ADDR/32 via ${endpoint.host_network.gw}
            ip ro del to default via 169.254.1.1
            ip ro del to default via ${endpoint.host_network.gw}
            iptables -t nat -I POSTROUTING -o $IF -j MASQUERADE -s 0.0.0.0/0
            ip ro add to default via 10.50.0.1 dev $IF
            while :; do
              echo .
              ssh ${_ssh_tunnel.ssh_args} -w 0:${endpoint.remote_tun[3:]} -i /root/.ssh/private_key -l $SSH_TUNNEL_USER $SSH_TUNNEL_HOST
              sleep 1
            done
            """
            ]
            envFrom = [
              { secretRef.name = ssh_tunnel_secret_name(endpoint) }
            ]
            securityContext = {
              privileged = True
              capabilities.add = [ "NET_ADMIN" ]
#              sysctls = [
#                name = "net.ipv4.conf.all.forwarding"
#                value = "1"
#              }]
            }
            volumeMounts = [{
              name = "ssh-private-key"
              mountPath = "/root/.ssh"
              readOnly = True
            }]
          }]
          volumes = [{
            name = "ssh-private-key"
            secret = {
              secretName = ssh_tunnel_private_key_secret_name(endpoint)
              defaultMode = 0400
            }
          }]
        }
      }
    }
  }

}


manifests = [
  k8s.Namespace {
    metadata.name = _ssh_tunnel.namespace
  }
  [
    [
      k8s.Secret {
        metadata = {
          name = ssh_tunnel_secret_name(endpoint)
          namespace = _ssh_tunnel.namespace
        }
        stringData = {
          SSH_TUNNEL_USER = endpoint.ssh.user
          SSH_TUNNEL_HOST = endpoint.ssh.host
        }
      }
      k8s.Secret {
        metadata = {
          name = ssh_tunnel_private_key_secret_name(endpoint)
          namespace = _ssh_tunnel.namespace
        }
        data = {
          private_key = endpoint.ssh.private_key
        }
      }
      makeDeployment(endpoint)

    network_attach.NetworkAttachmentDefinition {
      metadata = {
        name = nad_name(endpoint)
        namespace = _ssh_tunnel.namespace
      }
      spec = {
        config = json.encode({
          cniVersion = "0.3.1"
          #type = endpoint.host_network.type
          type = "bridge"
          bridge = endpoint.host_network.bridge
          hairpinMode = True
          #mode = endpoint.host_network.mode
          ipam = {
            type = "static",
            addresses = [{
              address = endpoint.host_network.ip
              gateway = endpoint.host_network.gw
            }]
            capabilities.macs = True
          }
        })
      }
    }

    ] for endpoint in _ssh_tunnel.endpoints
  ]
]
