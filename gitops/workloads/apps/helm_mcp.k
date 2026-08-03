import k8s.api.core.v1 as core
import k8s.api.apps.v1 as apps
import k8s.api.networking.v1 as net
import config as cfg

app = cfg.config.mcp.helm_mcp

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
                        args = ["-mode=http", "-httpListenAddr=:" + str(app.port)]
                        ports = [{containerPort = app.port}]
                        resources = {
                            requests = {cpu = "50m", memory = "128Mi"}
                            limits = {cpu = "200m", memory = "256Mi"}
                        }
                    }]
                    dnsConfig = {nameservers = ["172.25.1.9", "172.25.0.2"]}
                    dnsPolicy = "ClusterFirst"
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
