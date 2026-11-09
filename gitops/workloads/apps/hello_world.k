import k8s.api.core.v1 as k8s
import k8s.api.apps.v1 as apps
import config as cfg

_config = cfg.config
app = _config.hello_world
_name = app.name

manifests = [
    # 1. Test namespace
    k8s.Namespace {
        metadata = {
            name = app.namespace
        }
    }

    # 2. Hello-world Deployment
    apps.Deployment {
        metadata = {
            name = _name
            namespace = app.namespace
            labels = {
                app = _name
            }
        }
        spec = {
            replicas = app.replicas
            selector = {
                matchLabels = {
                    app = _name
                }
            }
            template = {
                metadata = {
                    labels = {
                        app = _name
                    }
                }
                spec = {
                    containers = [{
                        name = _name
                        image = app.image
                        imagePullPolicy = "IfNotPresent"
                        ports = [{
                            name = "http"
                            containerPort = app.port
                        }]
                        readinessProbe = {
                            httpGet = {
                                path = "/"
                                port = "http"
                            }
                            initialDelaySeconds = 2
                            periodSeconds = 5
                        }
                        resources = app.resources
                    }]
                }
            }
        }
    }

    # 3. Service exposing the hello-world container
    k8s.Service {
        metadata = {
            name = _name
            namespace = app.namespace
            labels = {
                app = _name
            }
        }
        spec = {
            selector = {
                app = _name
            }
            ports = [{
                name = "http"
                port = app.port
                targetPort = "http"
            }]
        }
    }
]
