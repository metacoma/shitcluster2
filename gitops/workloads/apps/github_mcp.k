import k8s.api.core.v1 as core
import k8s.api.apps.v1 as apps
import k8s.api.networking.v1 as net
import config as cfg

_config = cfg.config
mcp = _config.mcp
_name = "github-mcp"
_image = "ghcr.io/github/github-mcp-server:latest"
_ingress_host = mcp.github_mcp.ingress_host

manifests = [
    apps.Deployment {
        metadata = {
            name = _name
            namespace = mcp.namespace
        }
        spec = {
            replicas = 1
            selector = {matchLabels = {app = _name}}
            template = {
                metadata = {labels = {app = _name}}
                spec = {
                    containers = [{
                        name = _name
                        image = _image
                        args = [
                            "http", 
                            "--scope-challenge", 
                            "--base-url", "https://" + _ingress_host
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
            name = _name
            namespace = mcp.namespace
        }
        spec = {
            selector = {app = _name}
            ports = [{port = 80, targetPort = 8082}]
        }
    },
    net.Ingress {
        metadata = {
            name = _name
            namespace = mcp.namespace
            annotations = {
                "kubernetes.io/ingress.class": "nginx"
            }
        }
        spec = {
            tls = [{
                hosts = [_ingress_host]
                secretName = "mansion-net-tls"
            }]
            rules = [{
                host = _ingress_host
                http = {
                    paths = [{
                        path = "/"
                        pathType = "Prefix"
                        backend = {
                            service = {
                                name = _name
                                port = {number = 80}
                            }
                        }
                    }]
                }
            }]
        }
    }
]
