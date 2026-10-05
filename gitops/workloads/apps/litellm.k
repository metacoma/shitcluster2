import k8s.api.core.v1 as k8s
import argoproj.v1alpha1 as argoproj
import yaml
import config as cfg

_config = cfg.config
ll = _config.litellm
backend = ll.backend_host

# Актуальные модели, обслуживаемые llama-swap на mcmp10
# (/var/lib/homellm/llamaswap/config.yaml). Порты бэкендов совпадают с
# run-model.sh llama-swap: glm-5.3 и deepseek-exp разделяют слот 8087
# (llama-swap держит ровно одну модель за раз, exclusive:true).
_model_list = [
    {
        model_name = "glm-5.3"
        litellm_params = {
            model = "openai/glm-5.3-flash-iq4xs"
            api_base = "http://${backend}:8087/v1"
            api_key = "local"
        }
    }
    {
        model_name = "qwen3.8-next"
        litellm_params = {
            model = "openai/qwen3.8-flash-next"
            api_base = "http://${backend}:8094/v1"
            api_key = "local"
        }
    }
    {
        model_name = "deepseek-exp"
        litellm_params = {
            model = "openai/deepseek-v4-flash"
            api_base = "http://${backend}:8087/v1"
            api_key = "local"
        }
    }
    {
        model_name = "qwen3.8-27b"
        litellm_params = {
            model = "openai/qwen38-27b"
            api_base = "http://${backend}:8093/v1"
            api_key = "local"
        }
    }
]

manifests = [
    # 1. Namespace
    k8s.Namespace {
        metadata.name = ll.namespace
    }
    # 2. Master key Secret (from Vault via vals)
    k8s.Secret {
        metadata = {
            name = "litellm-masterkey"
            namespace = ll.namespace
        }
        stringData = {
            masterkey = ll.master_key
        }
    }
    # 3. Nginx Ingress for HTTPS traffic
    {
        apiVersion = "networking.k8s.io/v1"
        kind = "Ingress"
        metadata = {
            name = ll.helm.release_name + "-ingress"
            namespace = ll.namespace
            annotations = {
                "kubernetes.io/ingress.class" = "nginx"
                "nginx.ingress.kubernetes.io/proxy-read-timeout" = "1800"
                "nginx.ingress.kubernetes.io/proxy-send-timeout" = "1800"
                "nginx.ingress.kubernetes.io/proxy-buffering" = "off"
                "nginx.ingress.kubernetes.io/proxy-body-size" = "0"
            }
        }
        spec = {
            tls = [
                {
                    hosts = [ll.ingress_host]
                    secretName = "mansion-net-tls"
                }
            ]
            rules = [
                {
                    host = ll.ingress_host
                    http = {
                        paths = [
                            {
                                path = "/"
                                pathType = "Prefix"
                                backend = {
                                    service = {
                                        name = ll.helm.release_name
                                        port = {
                                            number = 4000
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
    # 4. ArgoCD Application — official monolithic Helm chart (OCI)
    argoproj.Application {
        metadata = {
            name = ll.helm.release_name
            namespace = _config.argocd.namespace
        }
        spec = {
            destination = {
                namespace = ll.namespace
                name = "in-cluster"
            }
            project = "default"
            source = {
                chart = ll.helm.chart_name
                repoURL = ll.helm.repo
                targetRevision = ll.helm.chart_version
                helm = {
                    values = yaml.encode({
                        replicaCount = 1
                        image = {
                            repository = "ghcr.io/berriai/litellm-database"
                            pullPolicy = "IfNotPresent"
                            tag = ll.helm.app_version
                        }
                        nameOverride = "litellm"
                        # Master key from Vault-backed Secret
                        masterkeySecretName = "litellm-masterkey"
                        masterkeySecretKey = "masterkey"
                        # Stateless: no Postgres, no Redis, no migrations
                        db = {
                            useExisting = False
                            deployStandalone = False
                        }
                        redis = {
                            enabled = False
                        }
                        migrationJob = {
                            enabled = False
                        }
                        # Proxy configuration (same as /var/lib/llama-cpp/litellm.yaml)
                        proxy_config = {
                            model_list = _model_list
                            litellm_settings = {
                                drop_params = True
                                request_timeout = 1800
                                callbacks = ["prometheus", "otel"]
                            }
                            general_settings = {
                                master_key = "os.environ/PROXY_MASTER_KEY"
                            }
                        }
                        # Chart-managed ingress disabled — we use our own Ingress above
                        ingress = {
                            enabled = False
                        }
                        serviceMonitor = {
                            enabled = False
                        }
                        logLevel = "INFO"
                        # OTel-экспортер в кластерный OTLP-коллектор (ns observability):
                        # трейсы -> Tempo, метрики -> VictoriaMetrics
                        # События (gen_ai.content.* -> Loki) ВЫКЛ: баг litellm #32996
                        # (None в log-рекордах дропает батч + трейсбеки); вернуть после апгрейда
                        envVars = {
                            OTEL_EXPORTER_OTLP_ENDPOINT = "http://otlp-opentelemetry-collector.observability.svc:4317"
                            OTEL_EXPORTER_OTLP_PROTOCOL = "grpc"
                            OTEL_SERVICE_NAME = "litellm-proxy"
                            LITELLM_OTEL_INTEGRATION_ENABLE_METRICS = "true"
                        }
                        nodeSelector = _config.nodeSelector.worker
                        resources = {
                            requests = {
                                cpu = "100m"
                                memory = "512Mi"
                            }
                            limits = {
                                cpu = "500m"
                                memory = "2Gi"
                            }
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
]
