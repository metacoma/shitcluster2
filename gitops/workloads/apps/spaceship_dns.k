import k8s.api.core.v1 as k8s
import k8s.api.batch.v1 as batch
import config as cfg
import file
import json
import kubevirt.v1.k8s_cni_cncf_io_v1_network_attachment_definition as network_attach

_config = cfg.config

namespace = "network"
name = "spaceship-dns-updater"
nad_name = "macvlan-management-spaceship"
image = "nicolaka/netshoot:latest"

spaceship_dns = {
  domain = "ref+vault://kv/spaceship_dns#domain"
  api_key = "ref+vault://kv/spaceship_dns#api_key"
  api_secret = "ref+vault://kv/spaceship_dns#api_secret"
  api_url = "ref+vault://kv/spaceship_dns#api_url"
}

bind = {
  ns = "172.24.0.2"
  tsig_key = "ref+vault://kv/bind#cert_manager_key"
  tsig_key_name = "cert_manager_key"
  zone = "mansion.metacoma.org"
}

update_script = file.read("apps/spaceship_dns_update.sh")

manifests = [
  # 1. Network Attachment Definition for Management VLAN (BIND access)
  network_attach.NetworkAttachmentDefinition {
    metadata = {
      name = nad_name
      namespace = namespace
    }
    spec = {
      config = json.encode({
        cniVersion = "0.3.1"
        type = "macvlan"
        master = "br-management"
        mode = "bridge"
        ipam = {
          type = "static"
          addresses = [{
            address = "172.24.1.3/32"
          }]
          routes = [
            { dst = "172.24.0.2/32" }
          ]
        }
      })
    }
  }

  # 2. Secret with Spaceship API + BIND TSIG credentials
  k8s.Secret {
    metadata = {
      name = name
      namespace = namespace
    }
    stringData = {
      SPACESHIP_API_URL = spaceship_dns.api_url
      SPACESHIP_API_KEY = spaceship_dns.api_key
      SPACESHIP_API_SECRET = spaceship_dns.api_secret
      SPACESHIP_DOMAIN = spaceship_dns.domain
      BIND_NS = bind.ns
      BIND_TSIG_KEY = bind.tsig_key
      BIND_TSIG_KEY_NAME = bind.tsig_key_name
      BIND_ZONE = bind.zone
    }
  }

  # 3. CronJob: Spaceship API + BIND ext view update
  batch.CronJob {
    metadata = {
      name = name
      namespace = namespace
      labels = {
        app = name
      }
    }
    spec = {
      schedule = "*/15 * * * *"
      concurrencyPolicy = "Forbid"
      successfulJobsHistoryLimit = 3
      failedJobsHistoryLimit = 1
      jobTemplate.spec = {
        template = {
          metadata = {
            annotations = {
              "k8s.v1.cni.cncf.io/networks" = json.encode([
                {
                  name = nad_name
                  namespace = namespace
                  interface = "eth1"
                }
              ])
            }
          }
          spec = {
            restartPolicy = "OnFailure"
            nodeSelector = _config.nodeSelector.worker
            containers = [{
              name = name
              image = image
              imagePullPolicy = "IfNotPresent"
              command = ["/bin/sh", "-c", update_script]
              envFrom = [{
                secretRef.name = name
              }]
            }]
          }
        }
      }
    }
  }
]
