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
      "visibility": "public",
      "owner": "admin"
    },
    "kubernetes-mcp": {
      "type": "streamable-http",
      "url": "https://k8s-mcp.mansion.metacoma.org/mcp",
      "timeout": 60000,
      "enabled": true,
      "visibility": "public",
      "owner": "admin"
    },
    "github-mcp": {
      "type": "streamable-http",
      "url": "https://github-mcp.mansion.metacoma.org",
      "headers": {
        "Authorization": "Bearer ref+vault://kv/metacoma#github"
      },
      "timeout": 60000,
      "enabled": true,
      "visibility": "public",
      "owner": "admin"
    },
    "grafana-mcp": {
      "type": "streamable-http",
      "url": "https://grafana-mcp.mansion.metacoma.org/mcp",
      "timeout": 60000,
      "enabled": true,
      "visibility": "public",
      "owner": "admin"
    },
    "artifacthub-mcp": {
      "type": "streamable-http",
      "url": "https://artifacthub-mcp.mansion.metacoma.org/mcp",
      "timeout": 60000,
      "enabled": true,
      "visibility": "public",
      "owner": "admin"
    },
    "package-version-check-mcp": {
      "type": "streamable-http",
      "url": "https://pkgver-mcp.mansion.metacoma.org/mcp",
      "timeout": 60000,
      "enabled": true,
      "visibility": "public",
      "owner": "admin"
    },
    "qdrant-loader-mcp": {
      "type": "streamable-http",
      "url": "https://qdrant-loader-mcp.mansion.metacoma.org/mcp",
      "timeout": 60000,
      "enabled": true,
      "visibility": "public",
      "owner": "admin"
    }
  },
  "systemConfig": {
    "routing": {
      "enableBearerAuth": false,
      "skipAuth": true
    },
    "auth": {
      "betterAuth": {}
    }
  },
  "users": [],
  "bearerKeys": []
}"""

manifests = [
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
                        name = "prepare-config"
                        image = "busybox:1.28"
                        command = ["sh", "-c", "cp /config-ro/mcp_settings.json /app/data/mcp_settings.json"]
                        volumeMounts = [
                            {
                                name = "settings"
                                mountPath = "/config-ro"
                                readOnly = True
                            }
                            {
                                name = "data"
                                mountPath = "/app/data"
                            }
                        ]
                    }]
                    containers = [{
                        name = _name
                        image = _image
                        ports = [{containerPort = 3000}]
                        env = [
                            {
                                name = "ADMIN_PASSWORD"
                                value = mcp.admin_password
                            }
                            {
                                name = "MCPHUB_SETTING_PATH"
                                value = "/app/data/mcp_settings.json"
                            }
                        ]
                        volumeMounts = [
                            {
                                name = "data"
                                mountPath = "/app/data"
                            }
                        ]
                    }]
                    volumes = [
                        {
                            name = "settings"
                            configMap = {name = _name + "-settings"}
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
            }
        }
        spec = {
            tls = [{
                hosts = [mcp.ingress_host]
                secretName = "mansion-net-tls"
            }]
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
