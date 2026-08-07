import k8s.api.core.v1 as core
import k8s.api.apps.v1 as apps
import config as cfg

app = cfg.config.tei

manifests = [
    # Text Embeddings Inference (TEI) — OpenAI-compatible embeddings endpoint
    apps.Deployment {
        metadata = {
            name = app.name
            namespace = app.namespace
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
                            "--model-id", app.model
                            "--port", "80"
                        ]
                        ports = [{containerPort = 80}]
                        resources = {
                            requests = {cpu = "500m", memory = "1Gi"}
                            limits = {cpu = "2", memory = "4Gi"}
                        }
                    }]
                }
            }
        }
    },
    core.Service {
        metadata = {
            name = app.name
            namespace = app.namespace
        }
        spec = {
            selector = {app = app.name}
            ports = [{port = 80, targetPort = 80}]
        }
    }
]
