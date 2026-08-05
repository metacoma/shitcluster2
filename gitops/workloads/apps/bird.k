import k8s.api.core.v1 as k8s
import k8s.api.apps.v1 as v1
import config as cfg
import json
import file
import kubevirt.v1.k8s_cni_cncf_io_v1_network_attachment_definition as network_attach

_config = cfg.config
_bird = _config.bird

nad_name = "bird-management"

# BIRD config (router id 172.24.0.19, BGP mikrotik local 172.24.0.19, llama3 removed)
bird_conf = file.read("apps/bird_data/bird.conf")

manifests = [
  # 1. Namespace
  k8s.Namespace {
    metadata.name = _bird.namespace
  }

  # 2. Network Attachment Definition on br-management (management network)
  network_attach.NetworkAttachmentDefinition {
    metadata = {
      name = nad_name
      namespace = _bird.namespace
    }
    spec = {
      config = json.encode({
        cniVersion = "0.3.1"
        type = "bridge"
        bridge = "br-management"
        hairpinMode = True
        ipam = {
          type = "static"
          addresses = [{
            address = _bird.ip
            gateway = _bird.gateway
          }]
          routes = [
            { dst = "0.0.0.0/0", gw = _bird.gateway }
          ]
        }
      })
    }
  }

  # 3. ConfigMap with bird.conf
  k8s.ConfigMap {
    metadata = {
      name = "bird-conf"
      namespace = _bird.namespace
    }
    data = {
      "bird.conf": bird_conf
    }
  }

  # 4. Deployment
  v1.Deployment {
    metadata = {
      name = "bird"
      namespace = _bird.namespace
      labels = {
        app = "bird"
      }
    }
    spec = {
      replicas = 1
      selector.matchLabels = {app = "bird"}
      template = {
        metadata = {
          labels.app = "bird"
          annotations = {
            "k8s.v1.cni.cncf.io/networks" = json.encode([
              {
                name = nad_name
                namespace = _bird.namespace
                interface = "public"
              }
            ])
          }
        }
        spec = {
          dnsPolicy = "None"
          dnsConfig.nameservers = [_bird.gateway]

          nodeSelector = _config.nodeSelector.worker
          hostNetwork = False

          containers = [{
            name = "bird"
            image = _bird.image
            imagePullPolicy = "IfNotPresent"
            command = ["/bin/sh"]
            args = ["-c", """
              sysctl -w net.ipv4.ip_forward=1
              sysctl -w net.ipv4.conf.all.forwarding=1
              exec bird -f -c /etc/bird/bird.conf
            """]
            securityContext = {
              privileged = True
              capabilities.add = ["NET_ADMIN", "NET_RAW", "SYS_ADMIN"]
            }
            volumeMounts = [{
              name = "bird-conf"
              mountPath = "/etc/bird"
              readOnly = True
            }]
            readinessProbe = {
              exec = {
                command = ["birdc", "show", "status"]
              }
              initialDelaySeconds = 10
              periodSeconds = 10
              timeoutSeconds = 5
            }
            livenessProbe = {
              exec = {
                command = ["birdc", "show", "status"]
              }
              initialDelaySeconds = 15
              periodSeconds = 30
              timeoutSeconds = 5
            }
          }]
          volumes = [{
            name = "bird-conf"
            configMap = {
              name = "bird-conf"
            }
          }]
        }
      }
    }
  }
]
