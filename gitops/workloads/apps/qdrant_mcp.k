import k8s.api.core.v1 as core
import k8s.api.apps.v1 as apps
import k8s.api.networking.v1 as net
import config as cfg

app = cfg.config.mcp.qdrant_mcp

manifests = [
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
                                name = "QDRANT_URL"
                                value = app.qdrant_url
                            }
                            {
                                name = "COLLECTION_NAME"
                                value = app.collection
                            }
                            {
                                name = "EMBEDDING_MODEL"
                                value = app.embedding_model
                            }
                            {
                                name = "FASTMCP_SERVER_HOST"
                                value = "0.0.0.0"
                            }
                        ]
                        resources = {
                            requests = {cpu = "100m", memory = "256Mi"}
                            limits = {cpu = "500m", memory = "1Gi"}
                        }
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
