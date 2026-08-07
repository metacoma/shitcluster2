import k8s.api.core.v1 as k8s
import argoproj.v1alpha1 as argoproj
import yaml
import config as cfg

_config = cfg.config
ll = _config.litellm
backend = ll.backend_host

# Model list mirroring /var/lib/llama-cpp/litellm.yaml on mcmp10,
# with docker-internal names replaced by mcmp10.mgmt.mansion.shitcluster.io:<host-port>
_model_list = [
    {
        model_name = "qwen36-27b"
        litellm_params = {
            model = "openai/qwen36-27b"
            api_base = "http://${backend}:8083/v1"
            api_key = "local"
        }
    }
    {
        model_name = "qwen36-27b-uncensored"
        litellm_params = {
            model = "openai/qwen36-27b-uncensored"
            api_base = "http://${backend}:8084/v1"
            api_key = "local"
        }
    }
    {
        model_name = "qwen36-35b"
        litellm_params = {
            model = "openai/qwen36-35b"
            api_base = "http://${backend}:8086/v1"
            api_key = "local"
        }
    }
    {
        model_name = "qwen36-35b-heretic"
        litellm_params = {
            model = "openai/qwen36-35b-heretic"
            # points to glm-45-air backend (as in original config)
            api_base = "http://${backend}:8090/v1"
            api_key = "local"
        }
    }
    {
        model_name = "step-37-flash"
        litellm_params = {
            model = "openai/step-37-flash"
            api_base = "http://${backend}:8087/v1"
            api_key = "local"
        }
    }
    {
        model_name = "glm-45-air"
        litellm_params = {
            model = "openai/glm-45-air"
            api_base = "http://${backend}:8090/v1"
            api_key = "local"
        }
    }
    {
        model_name = "laguna-s21-q2"
        litellm_params = {
            model = "openai/laguna-s21-q2"
            api_base = "http://${backend}:8087/v1"
            api_key = "local"
        }
    }
    {
        model_name = "laguna-xs21-q8"
        litellm_params = {
            model = "openai/laguna-xs21-q8"
            api_base = "http://${backend}:8087/v1"
            api_key = "local"
        }
    }
    {
        model_name = "laguna-xs21-q4"
        litellm_params = {
            model = "openai/laguna-xs"
            api_base = "http://${backend}:8088/v1"
            api_key = "local"
        }
    }
    {
        model_name = "gemma4-31b"
        litellm_params = {
            model = "openai/gemma4-31b"
            api_base = "http://${backend}:8085/v1"
            api_key = "local"
        }
    }
    {
        model_name = "deepseek-v4-flash-q3"
        litellm_params = {
            model = "openai/deepseek-v4-flash-q3"
            api_base = "http://${backend}:8087/v1"
            api_key = "local"
        }
    }
    # Embeddings model (served in-process via sentence-transformers)
    {
        model_name = "all-MiniLM-L6-v2"
        litellm_params = {
            model = "sentence-transformers/all-MiniLM-L6-v2"
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
                            repository = "metacoma/litellm"
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
                                callbacks = ["prometheus"]
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
