import k8s.api.core.v1 as core
import k8s.api.apps.v1 as apps
import k8s.api.networking.v1 as net
import config as cfg

_config = cfg.config
mcp = _config.mcp
_name = "mcphub"
_image = "samanhappy/mcphub:latest"

# mcp_settings.json content
_settings = """{
  "mcpServers": {
    "hound-mcp": {
      "type": "streamable-http",
      "url": "https://hound-mcp.mansion.metacoma.org/mcp",
      "timeout": 60000,
      "enabled": true,
      "visibility": "public"
    }
  },
  "systemConfig": {
    "auth": {
      "betterAuth": {}
    }
  },
  "users": [],
  "bearerKeys": []
}"""

manifests = [
    core.Namespace {
        metadata.name = mcp.namespace
    },
    core.PersistentVolumeClaim {
        metadata = {
            name = _name + "-settings-data"
            namespace = mcp.namespace
        }
        spec = {
            accessModes = ["ReadWriteOnce"]
            resources = {requests = {storage = "100Mi"}}
            storageClassName = _config.storageClass
        }
    },
    core.PersistentVolumeClaim {
        metadata = {
            name = _name + "-data"
            namespace = mcp.namespace
        }
        spec = {
            accessModes = ["ReadWriteOnce"]
            resources = {requests = {storage = "4Gi"}}
            storageClassName = _config.storageClass
        }
    },
    core.ConfigMap {
        metadata = {
            name = _name + "-settings"
            namespace = mcp.namespace
        }
        data = {
            "mcp_settings.json": _settings
        }
    },
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
                    initContainers = [{
                        name = "init-settings"
                        image = "busybox:latest"
                        command = ["sh", "-c", "cp /etc/mcphub-config/mcp_settings.json /app/mcp_settings.json"]
                        volumeMounts = [
                            {
                                name = "settings-cm"
                                mountPath = "/etc/mcphub-config"
                                readOnly = True
                            }
                            {
                                name = "settings-pvc"
                                mountPath = "/app"
                            }
                        ]
                    }]
                    containers = [{
                        name = _name
                        image = _image
                        ports = [{containerPort = 3000}]
                        env = [{
                            name = "ADMIN_PASSWORD"
                            value = mcp.admin_password
                        }]
                        volumeMounts = [
                            {
                                name = "settings-pvc"
                                mountPath = "/app/mcp_settings.json"
                                subPath = "mcp_settings.json"
                            }
                            {
                                name = "data"
                                mountPath = "/app/data"
                            }
                        ]
                    }]
                    volumes = [
                        {
                            name = "settings-cm"
                            configMap = {name = _name + "-settings"}
                        }
                        {
                            name = "settings-pvc"
                            persistentVolumeClaim = {claimName = _name + "-settings-data"}
                        }
                        {
                            name = "data"
                            persistentVolumeClaim = {claimName = _name + "-data"}
                        }
                    ]
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
            ports = [{port = 80, targetPort = 3000}]
        }
    },
    net.Ingress {
        metadata = {
            name = _name
            namespace = mcp.namespace
            annotations = {
                "kubernetes.io/ingress.class": "nginx"
                "cert-manager.io/cluster-issuer": "letsencrypt-prod-bind"
            }
        }
        spec = {
            rules = [{
                host = mcp.ingress_host
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
