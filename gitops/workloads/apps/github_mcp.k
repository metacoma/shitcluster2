import k8s.api.core.v1 as core
import k8s.api.apps.v1 as apps
import k8s.api.networking.v1 as net
import config as cfg

app = cfg.config.mcp.github_mcp

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
                        args = [
                            "http", 
                            "--scope-challenge", 
                            "--base-url", "https://" + app.ingress_host
                        ]
                        ports = [{containerPort = 8082}]
                        env = [
                            {
                                name = "GITHUB_PERSONAL_ACCESS_TOKEN"
                                value = "ref+vault://kv/metacoma#github"
                            }
                        ]
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
            ports = [{port = 80, targetPort = 8082}]
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
