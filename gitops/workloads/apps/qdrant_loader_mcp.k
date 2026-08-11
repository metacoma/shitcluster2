import k8s.api.core.v1 as core
import k8s.api.apps.v1 as apps
import k8s.api.networking.v1 as net
import yaml
import config as cfg

app = cfg.config.mcp.qdrant_loader_mcp

# Server config (loaded via MCP_CONFIG) — vector_size matters for MiniLM (384d)
_config_yaml = yaml.encode({
    global = {
        qdrant = {
            url = app.qdrant_url
            collection_name = app.collection
        }
        llm = {
            provider = "openai"
            base_url = app.llm_base_url
            api_key = app.llm_api_key
            models = {
                embeddings = app.llm_embedding_model
            }
            embeddings = {
                vector_size = 1024
            }
        }
    }
})

manifests = [
    core.ConfigMap {
        metadata = {
            name = app.name + "-config"
            namespace = cfg.config.mcp.namespace
        }
        data = {
            "config.yaml": _config_yaml
        }
    },
    apps.Deployment {
        metadata = {
            name = app.name
            namespace = cfg.config.mcp.namespace
        }
        spec = {
            replicas = 1
            selector = {matchLabels = {app = app.name}}
            template = {
                metadata = {labels = {app = app.name}}
                spec = {
                    containers = [{
                        name = app.name
                        image = app.image
                        ports = [{containerPort = app.port}]
                        env = [
                            {
                                name = "MCP_CONFIG"
                                value = "/etc/qdrant-loader/config.yaml"
                            }
                            {
                                name = "QDRANT_URL"
                                value = app.qdrant_url
                            }
                            {
                                name = "QDRANT_COLLECTION_NAME"
                                value = app.collection
                            }
                            {
                                name = "LLM_PROVIDER"
                                value = "openai"
                            }
                            {
                                name = "LLM_BASE_URL"
                                value = app.llm_base_url
                            }
                            {
                                name = "LLM_API_KEY"
                                value = app.llm_api_key
                            }
                            {
                                name = "LLM_EMBEDDING_MODEL"
                                value = app.llm_embedding_model
                            }
                            {
                                name = "MCP_LOG_LEVEL"
                                value = "INFO"
                            }
                        ]
                        volumeMounts = [{
                            name = "config"
                            mountPath = "/etc/qdrant-loader"
                            readOnly = True
                        }]
                        resources = {
                            requests = {cpu = "100m", memory = "256Mi"}
                            limits = {cpu = "500m", memory = "1Gi"}
                        }
                    }]
                    volumes = [{
                        name = "config"
                        configMap = {name = app.name + "-config"}
                    }]
                }
            }
        }
    },
    core.Service {
        metadata = {
            name = app.name
            namespace = cfg.config.mcp.namespace
        }
        spec = {
            selector = {app = app.name}
            ports = [{port = 80, targetPort = app.port}]
        }
    },
    net.Ingress {
        metadata = {
            name = app.name
            namespace = cfg.config.mcp.namespace
            annotations = {
                "kubernetes.io/ingress.class": "nginx"
            }
        }
        spec = {
            tls = [{
                hosts = [app.ingress_host]
                secretName = "mansion-net-tls"
            }]
            rules = [{
                host = app.ingress_host
                http = {
                    paths = [{
                        path = "/"
                        pathType = "Prefix"
                        backend = {
                            service = {
                                name = app.name
                                port = {number = 80}
                            }
                        }
                    }]
                }
            }]
        }
    }
]
