import k8s.api.core.v1 as k8s
import config as cfg
import ..argoproj.v1alpha1 as argoproj
import yaml
import json
import kubevirt.v1.k8s_cni_cncf_io_v1_network_attachment_definition as network_attach

_config = cfg.config
cert_manager = _config.cert_manager

# Helper for ArgoCD Application
app_manifest = lambda helm : any, values : any -> argoproj.Application {
  argoproj.Application {
    metadata = {
        name = helm.release_name
        namespace = _config.argocd.namespace
    }
    spec = {
        destination = {
            namespace = cert_manager.namespace
            name = "in-cluster"
        }
        project = "default"
        source = {
            chart = helm.chart_name
            repoURL = helm.repo
            targetRevision = helm.chart_version
            helm = {
              values = yaml.encode(values)
            }
        }
        syncPolicy = {
            automated = {
                selfHeal = True
            }
        }
    }
  }
}

manifests = [
  # 1. Namespace
  k8s.Namespace {
    metadata = {
      name = cert_manager.namespace
    }
  }

  # 2. Network Attachment Definition for Management VLAN
  network_attach.NetworkAttachmentDefinition {
    metadata = {
      name = "macvlan-management-cert-manager"
      namespace = cert_manager.namespace
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
            address = "172.24.1.2/16"
            gateway = "172.24.0.1"
          }]
        }
      })
    }
  }

  # 3. Helm Installation via ArgoCD
  app_manifest(
    cert_manager.helm, 
    values = {
      installCRDs = True
      # Use Multus annotation for access to Management VLAN
      podAnnotations = {
        "k8s.v1.cni.cncf.io/networks": json.encode([
          {
            "name": "macvlan-management-cert-manager",
            "interface": "net1",
            "ips": ["172.24.1.2/16"]
          }
        ])
      }
      # Ensure controllers run on workers
      nodeSelector = {
        "node-role.kubernetes.io/worker": ""
      }
      webhook = {
        nodeSelector = {
          "node-role.kubernetes.io/worker": ""
        }
      }
      cainjector = {
        nodeSelector = {
          "node-role.kubernetes.io/worker": ""
        }
      }
      startupapicheck = {
        nodeSelector = {
          "node-role.kubernetes.io/worker": ""
        }
      }
    }
  )

  # 4. Secret for BIND TSIG key (RFC 2136)
  k8s.Secret {
    metadata = {
      name = "bind-tsig-secret"
      namespace = cert_manager.namespace
    }
    stringData = {
      tsig = "ref+vault://kv/bind#cert_manager_key"
    }
  }

  # 5. ClusterIssuer for Let's Encrypt with BIND DNS-01
  {
    apiVersion = "cert-manager.io/v1"
    kind = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-prod-bind"
    }
    spec = {
      acme = {
        server = "https://acme-v02.api.letsencrypt.org/directory"
        email = "admin@metacoma.org"
        privateKeySecretRef = {
          name = "letsencrypt-prod-account-key"
        }
        solvers = [
          {
            dns01 = {
              rfc2136 = {
                nameservers = ["172.24.0.2"]
                tsigKeyName = "cert_manager_key"
                tsigAlgorithm = "HMACSHA256"
                tsigSecretSecretRef = {
                  name = "bind-tsig-secret"
                  key = "tsig"
                }
              }
            }
          }
        ]
      }
    }
  }

  # 6. Wildcard Certificate for managed domain
  {
    apiVersion = "cert-manager.io/v1"
    kind = "Certificate"
    metadata = {
      name = "mansion-wildcard-cert"
      namespace = "network" # Target namespace where cert will be used
    }
    spec = {
      secretName = "mansion-net-tls"
      issuerRef = {
        name = "letsencrypt-prod-bind"
        kind = "ClusterIssuer"
      }
      commonName = "*." + cert_manager.managed_domain
      dnsNames = [
        "*." + cert_manager.managed_domain
        cert_manager.managed_domain
      ]
    }
  }
]
