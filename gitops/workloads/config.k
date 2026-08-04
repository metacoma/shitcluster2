_ssh_tunnel_namespace = "network"

config = {
    k8s_domain = "k8s.mansion.shitcluster.io"
    storageClass = "longhorn"
    argocd = {
        namespace = "argocd"
    }
    nodeSelector = {
        worker = {
            "node-role.kubernetes.io/worker": ""
        }
        controller = {
            "node-role.kubernetes.io/control-plane": ""
        }
    }
    nodeAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms = [{
            matchExpressions = [{
                key = "node-role.kubernetes.io/worker"
                operator = "Exists"
            }]
        }]
    }
    ssh_tunnel = {
        ssh_args = """-o Compression=no \
      -o UserKnownHostsFile=/dev/null \
      -o StrictHostKeyChecking=no \
      -o Ciphers=chacha20-poly1305@openssh.com  \
      -o MACs=umac-128-etm@openssh.com \
      -o KexAlgorithms=curve25519-sha256 \
      -o TCPKeepAlive=yes \
      -o ServerAliveInterval=15 \
      -o ServerAliveCountMax=3 \
      -o ExitOnForwardFailure=yes \
    """
        namespace = _ssh_tunnel_namespace
        container_image = "nicolaka/netshoot:latest"
        endpoints = [
            {
                host_network = {
                    #type = "bridge"
                    bridge = "br-public"
                    ip = "172.25.220.2/16"
                    gw = "172.25.0.1"
                }
                name = "nl0"
                country = "NL"
                ssh = {
                    user = "ref+vault://kv/vpn_nl#ssh_user"
                    host = "ref+vault://kv/vpn_nl#ssh_host"
                    private_key = "ref+vault://kv/vpn_nl#ssh_private_key_base64"
                }
                local_addr = "10.50.0.2/24"
                remote_addr = "10.50.0.1/24"
                remote_tun = "tun5"
            }
        ]
    }
    monitoring = {
        notifications = {
            telegram = {
                bot_token = "ref+vault://kv/monitoring#telegram_bot_token"
                chat_id = "ref+vault://kv/monitoring#telegram_chat_id"
            }
        }
        namespace = "monitoring"
        alertmanager = {
            secret_name = "alert-manager"
            helm = {
                release_name = "alertmanager"
                chart_version = "1.30.0"
                app_version = "v0.30.0"
                repo = "https://prometheus-community.github.io/helm-charts"
                chart_name = "alertmanager"
            }
        }
        kube_state_metrics = {
            helm = {
                release_name = "kube-state-metrics"
                chart_version = "7.0.0"
                app_version = "2.17.0"
                repo = "https://prometheus-community.github.io/helm-charts"
                chart_name = "kube-state-metrics"
            }
        }
        node_exporter = {
            helm = {
                release_name = "node-exporter"
                chart_version = "4.49.2"
                app_version = "1.10.2"
                repo = "https://prometheus-community.github.io/helm-charts"
                chart_name = "prometheus-node-exporter"
            }
        }
        blackbox_exporter = {
            helm = {
                release_name = "blackbox-exporter"
                chart_version = "11.6.1"
                app_version = "v0.28.0"
                repo = "https://prometheus-community.github.io/helm-charts"
                chart_name = "prometheus-blackbox-exporter"
            }
        }
        vm_operator = {
            helm = {
                release_name = "vm-operator"
                chart_version = "0.57.1"
                app_version = "v0.66.1"
                repo = "https://victoriametrics.github.io/helm-charts/"
                chart_name = "victoria-metrics-operator"
            }
        }
        vm_single = {
            helm = {
                release_name = "vm-single"
                chart_version = "0.43.0"
                app_version = "v1.148.0"
                repo = "https://victoriametrics.github.io/helm-charts/"
                chart_name = "victoria-metrics-single"
            }
        }
        vm_agent = {
            helm = {
                release_name = "vm-agent"
                chart_version = "0.28.0"
                app_version = "v1.132.0"
                repo = "https://victoriametrics.github.io/helm-charts/"
                chart_name = "victoria-metrics-agent"
            }
        }
        grafana = {
            helm = {
                repo = "https://grafana.github.io/helm-charts"
                release_name = "grafana"
                chart_version = "10.5.15"
                app_version = "12.3.1"
                chart_name = "grafana"
            }
        }
    }
    observability = {
        namespace = "observability"
        loki = {
            helm = {
                repo = "https://grafana.github.io/helm-charts"
                release_name = "loki"
                chart_version = "6.49.0"
                app_version = "3.6.3"
                chart_name = "loki"
            }
        }
        tempo = {
            helm = {
                repo = "https://grafana.github.io/helm-charts"
                release_name = "tempo"
                chart_version = "1.24.1"
                app_version = "2.9.0"
                chart_name = "tempo"
            }
        }
        otlp = {
            ingress_host = "otlp.ref+vault://kv/spaceship_dns#managed_domain"
            helm = {
                repo = "https://open-telemetry.github.io/opentelemetry-helm-charts"
                release_name = "otlp"
                chart_version = "0.142.0"
                app_version = "0.142.0"
                chart_name = "opentelemetry-collector"
            }
        }
    }
    istio = {
        namespace = "istio-system"
        gateway_lb = "172.25.1.6"
        helm = {
            istio_base = {
                chart_name = "base"
                repo = "https://istio-release.storage.googleapis.com/charts"
                chart_version = "1.28.1"
                app_version = "1.28.1"
                release_name = "istio-base"
            }
            istiod = {
                chart_name = "istiod"
                repo = "https://istio-release.storage.googleapis.com/charts"
                app_version = "1.28.1"
                chart_version = "1.28.1"
                release_name = "istiod"
            }
            gateway = {
                chart_name = "gateway"
                repo = "https://istio-release.storage.googleapis.com/charts"
                app_version = "1.28.1"
                chart_version = "1.28.1"
                release_name = "istio-ingressgateway"
            }
        }
    }
    knative = {
        domain = "kn.public.mansion.shitcluster.io"
        operator = {
            namespace = "knative-operator"
            helm = {
                chart = "knative-operator"
                repo = "https://knative.github.io/operator"
                release_name = "knative-operator"
                version = "1.20.0"
                app_version = "v1.20.0"
            }
        }
        eventing = {
            namespace = "knative-eventing"
            version = "1.20.0"
        }
        serving = {
            namespace = "knative-serving"
            version = "1.20.0"
        }
    }
    nats = {
        namespace = "nats"
        users = {
            root = {
                username = "ref+vault://kv/nats#root_user+"
                password = "ref+vault://kv/nats#root_password+"
            }
            sys = {
                username = "ref+vault://kv/nats#sys_user+"
                password = "ref+vault://kv/nats#sys_password+"
            }
        }
        helm = {
            chart = "nats"
            repo = "https://nats-io.github.io/k8s/helm/charts/"
            release_name = "nats"
            version = "2.12.4"
            app_version = "2.12.4"
        }
    }
    vector = {
        namespace = "vector"
        configMapFiles = {
            "vector-exceptions" = {
                "parser.lua" = "apps/vector_data/parsers/parser.lua"
                "python.lua" = "apps/vector_data/parsers/python.lua"
            }
        }
        vector = {
            helm = {
                chart_name = "vector"
                repo = "https://helm.vector.dev"
                release_name = "vector"
                chart_version = "0.49.0"
                app_version = "0.52.0-distroless-libc"
            }
        }
    }
    ingress_nginx = {
        namespace = "ingress-nginx"
        ingress_lb = "172.25.1.1"
        helm = {
            chart_name = "ingress-nginx"
            repo = "https://kubernetes.github.io/ingress-nginx"
            release_name = "ingress-nginx"
            chart_version = "4.15.1"
            app_version = "1.12.0"
        }
    }
    wireguard = {
        namespace = "network"
        lb_ip = "172.25.1.7"
        port = 51820
        server_address = "10.30.0.1/24"
        server_cidr = "10.30.0.0/24"
    }
    dnscrypt_proxy = {
        namespace = "network"
        helm = {
            chart_name = "dnscrypt-proxy"
            repo = "https://charts.obeone.cloud"
            release_name = "dnscrypt-proxy"
            chart_version = "1.4.5"
        }
    }
    pihole = {
        namespace = "network"
        helm = {
            chart_name = "pihole"
            repo = "https://mojo2600.github.io/pihole-kubernetes/"
            release_name = "pihole"
            chart_version = "2.38.0"
        }
        loadBalancerIP = "172.25.1.9"
        upstreamDns = "172.25.1.8"
        adminPassword = "ref+vault://kv/pihole#adminPassword"
    }
    cert_manager = {
        namespace = "cert-manager"
        issuer_name = "letsencrypt-prod-bind"
        managed_domain = "ref+vault://kv/spaceship_dns#managed_domain"
        helm = {
            chart_name = "cert-manager"
            repo = "https://charts.jetstack.io"
            release_name = "cert-manager"
            chart_version = "v1.21.1"
            app_version = "v1.21.1"
        }
    }
    reflector = {
        namespace = "reflector"
        helm = {
            release_name = "reflector"
            chart_name = "reflector"
            repo = "oci://ghcr.io/emberstack/helm-charts/reflector"
            chart_version = "9.1.39"
            app_version = "9.1.39"
        }
    }
    longhorn = {
        namespace = "longhorn-system"
        metrics_service = "longhorn-backend"
        metrics_port = "9500"
    }
    external = {
        litellm = {
            host = "mcmp10.mgmt.mansion.shitcluster.io"
            port = "4000"
            metrics_path = "/metrics/"
            bearer_token = "sk-local"
            interval = "30s"
        }
        llamacpp = {
            host = "mcmp10.mgmt.mansion.shitcluster.io"
            port = "8083"
            metrics_path = "/metrics"
            interval = "30s"
        }
    }
    mcp = {
        namespace = "mcp"
        admin_password = "ref+vault://kv/mcphub#admin_password"
        ingress_host = "mcphub.mansion.metacoma.org"
        github_mcp = {
            name = "github-mcp"
            image = "ghcr.io/github/github-mcp-server:latest"
            ingress_host = "github-mcp.ref+vault://kv/spaceship_dns#managed_domain"
        }
        ddgs = {
            image = "docker.io/library/ddgs-mcp-ddgs-mcp:latest"
            port = 8096
        }
        hound_mcp = {
            image = "metacoma/hound-mcp:v2"
            port = 8765
        }
        k8s_mcp = {
            prefix = "k8s-mcp"
            helm = {
                repo = "oci://ghcr.io/containers/charts/kubernetes-mcp-server"
                chart = "kubernetes-mcp-server"
                version = "0.1.0"
                release_name = "kubernetes-mcp-server"
            }
            values = {
                replicaCount = 1
                serviceAccount = {create = True}
                rbac = {
                    create = True
                    extraClusterRoles = [{
                        name = "kubernetes-mcp-admin"
                        rules = [
                            {
                                apiGroups = [""]
                                resources = ["nodes", "pods", "persistentvolumeclaims", "namespaces", "events", "configmaps", "services", "secrets"]
                                verbs = ["get", "list", "watch", "create", "update", "patch", "delete"]
                            }
                            {
                                apiGroups = [""]
                                resources = ["pods/log", "nodes/proxy"]
                                verbs = ["get"]
                            }
                            {
                                apiGroups = [""]
                                resources = ["pods/exec"]
                                verbs = ["create"]
                            }
                            {
                                apiGroups = ["apps"]
                                resources = ["deployments", "statefulsets", "daemonsets", "replicasets"]
                                verbs = ["get", "list", "watch", "create", "update", "patch", "delete"]
                            }
                            {
                                apiGroups = ["metrics.k8s.io"]
                                resources = ["nodes", "pods"]
                                verbs = ["get", "list", "watch"]
                            }
                            {
                                apiGroups = ["rbac.authorization.k8s.io"]
                                resources = ["roles", "clusterroles", "rolebindings", "clusterrolebindings"]
                                verbs = ["get", "list", "watch"]
                            }
                        ]
                    }]
                    extraClusterRoleBindings = [{
                        name = "kubernetes-mcp-admin-binding"
                        roleRef = {
                            name = "kubernetes-mcp-admin"
                        }
                    }]
                }
                ingress = {
                    enabled = True
                    tls = {secretName = "mansion-net-tls"}
                }
                metrics = {
                    serviceMonitor = {enabled = False}
                }
            }
        }
        grafana_mcp = {
            name = "grafana-mcp"
            helm = {
                repo = "oci://ghcr.io/grafana-community/helm-charts/grafana-mcp"
                chart = "grafana-mcp"
                version = "0.19.0"
                release_name = "grafana-mcp"
            }
            image = {
                repository = "grafana/mcp-grafana"
                tag = "0.17.2"
            }
        }
        helm_mcp = {
            name = "mcp-helm"
            image = "ghcr.io/zekker6/mcp-helm:v1.3.0"
            port = 8012
            ingress_host = "mcp-helm.ref+vault://kv/spaceship_dns#managed_domain"
        }
        artifacthub_mcp = {
            image = "ghcr.io/metacoma/artifacthub-mcp-proxy:latest"
            port = 8080
        }
        package_version_check_mcp = {
            image = "ghcr.io/mshekow/package-version-check-mcp:latest"
            port = 8000
        }
    }
}
