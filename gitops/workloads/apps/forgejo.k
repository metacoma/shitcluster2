import k8s.api.core.v1 as k8s
import argoproj.v1alpha1 as argoproj
import yaml
import config as cfg
import victoria_metrics_operator.v1beta1.operator_victoriametrics_com_v1beta1_vm_service_scrape as vm_service_scrape

_config = cfg.config
fj = _config.forgejo

manifests = [
    # Namespace
    k8s.Namespace {
        metadata.name = fj.namespace
    }
    # Nginx Ingress for HTTP traffic
    {
        apiVersion = "networking.k8s.io/v1"
        kind = "Ingress"
        metadata = {
            name = fj.helm.release_name + "-ingress"
            namespace = fj.namespace
            annotations = {
                "kubernetes.io/ingress.class" = "nginx"
            }
        }
        spec = {
            tls = [
                {
                    hosts = [fj.ingress_host]
                    secretName = "mansion-net-tls"
                }
            ]
            rules = [
                {
                    host = fj.ingress_host
                    http = {
                        paths = [
                            {
                                path = "/"
                                pathType = "Prefix"
                                backend = {
                                    service = {
                                        name = fj.helm.release_name + "-http"
                                        port = {
                                            number = 3000
                                        }
                                    }
                                }
                            }
                        ]
                    }
                }
            ]
        }
    }
    # ArgoCD Application — Helm chart (OCI)
    argoproj.Application {
        metadata = {
            name = fj.helm.release_name
            namespace = _config.argocd.namespace
        }
        spec = {
            destination = {
                namespace = fj.namespace
                name = "in-cluster"
            }
            project = "default"
            source = {
                chart = fj.helm.chart_name
                repoURL = fj.helm.repo
                targetRevision = fj.helm.chart_version
                helm = {
                    values = yaml.encode({
                        # --- Image ---
                        image = {
                            registry = fj.image.registry
                            repository = fj.image.repository
                            tag = fj.image.tag
                            pullPolicy = "IfNotPresent"
                            rootless = True
                        }
                        # --- Security (CRI-O needs SYS_CHROOT for SSH chroot) ---
                        podSecurityContext = {
                            fsGroup = 1000
                        }
                        containerSecurityContext = {
                            allowPrivilegeEscalation = False
                            capabilities = {
                                drop = ["ALL"]
                                add = ["SYS_CHROOT"]
                            }
                            privileged = False
                            readOnlyRootFilesystem = True
                            runAsGroup = 1000
                            runAsNonRoot = True
                            runAsUser = 1000
                        }
                        # --- Services ---
                        service = {
                            http = {
                                type = "ClusterIP"
                                port = 3000
                                annotations = {
                                    "prometheus.io/scrape" = "true"
                                    "prometheus.io/port" = "3000"
                                }
                            }
                            ssh = {
                                type = "LoadBalancer"
                                port = 22
                                loadBalancerIP = fj.ssh_lb_ip
                                externalTrafficPolicy = "Local"
                            }
                        }
                        # --- Ingress (disabled — we use our own Ingress resource above) ---
                        ingress = {
                            enabled = False
                        }
                        # --- Persistence (Longhorn) ---
                        persistence = {
                            enabled = True
                            create = True
                            size = fj.persistence.size
                            storageClass = _config.storageClass
                            accessModes = ["ReadWriteOnce"]
                            annotations = {
                                "helm.sh/resource-policy" = "keep"
                            }
                        }
                        # --- Forgejo config ---
                        gitea = {
                            admin = {
                                username = fj.admin.username
                                password = fj.admin.password
                                email = fj.admin.email
                                passwordMode = "keepUpdated"
                            }
                            # --- Metrics ---
                            metrics = {
                                enabled = True
                                serviceMonitor = {
                                    enabled = False
                                }
                            }
                            # --- Probes ---
                            livenessProbe = {
                                enabled = True
                                tcpSocket = {port = "http"}
                                initialDelaySeconds = 200
                                timeoutSeconds = 1
                                periodSeconds = 10
                                successThreshold = 1
                                failureThreshold = 10
                            }
                            readinessProbe = {
                                enabled = True
                                httpGet = {
                                    path = "/api/healthz"
                                    port = "http"
                                }
                                initialDelaySeconds = 5
                                timeoutSeconds = 1
                                periodSeconds = 10
                                successThreshold = 1
                                failureThreshold = 3
                            }
                            # --- Pod annotations for metrics ---
                            podAnnotations = {
                                "prometheus.io/scrape" = "true"
                                "prometheus.io/port" = "3000"
                            }
                            # --- app.ini overrides ---
                            config = {
                                APP_NAME = fj.app_name
                                RUN_MODE = "prod"
                                server = {
                                    DOMAIN = fj.ingress_host
                                    ROOT_URL = "https://" + fj.ingress_host + "/"
                                    SSH_PORT = 22
                                    SSH_LISTEN_PORT = 2222
                                }
                                # Enable repo indexer for code search
                                indexer = {
                                    REPO_INDEXER_ENABLED = True
                                }
                                # Attachment limits
                                attachment = {
                                    ENABLED = True
                                    MAX_SIZE = "100"
                                    MAX_FILES = "10"
                                }
                                # Git settings
                                git = {
                                    DISABLE_HTTP_GIT = False
                                    ENABLEMENT_DIFF_HIGHLIGHTING = True
                                }
                                # Session/Cache (memory is fine for single-pod)
                                session = {
                                    PROVIDER = "memory"
                                    SAME_SITE = "strict"
                                }
                                cache = {
                                    ADAPTER = "memory"
                                }
                                # Logging
                                log = {
                                    MODE = "file"
                                    LEVEL = "info"
                                }
                                # i18n
                                i18n = {
                                    LANGUAGES = ["en-US", "ru-RU", "uk-UA"]
                                    DEFAULT = "en-US"
                                }
                            }
                        }
                        # --- Resources ---
                        resources = {
                            limits = {
                                cpu = fj.resources.limits.cpu
                                memory = fj.resources.limits.memory
                            }
                            requests = {
                                cpu = fj.resources.requests.cpu
                                memory = fj.resources.requests.memory
                            }
                        }
                        # --- Scheduling ---
                        nodeSelector = _config.nodeSelector.worker
                        # --- Misc ---
                        replicaCount = 1
                        strategy = {type = "Recreate"}
                        deployment = {
                            terminationGracePeriodSeconds = 60
                        }
                    })
                }
            }
            syncPolicy = {
                automated = {
                    selfHeal = True
                }
            }
        }
    }
    # VMServiceScrape for VictoriaMetrics
    vm_service_scrape.VMServiceScrape {
        metadata = {
            name = fj.helm.release_name + "-metrics"
            namespace = fj.namespace
        }
        spec = {
            selector.matchLabels = {
                "app.kubernetes.io/name" = fj.helm.release_name
            }
            endpoints = [{
                port = "http"
                interval = "30s"
                path = "/metrics"
            }]
        }
    }
]
