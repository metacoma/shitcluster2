import k8s.api.core.v1 as core
import k8s.api.apps.v1 as apps
import config as cfg

app = cfg.config.pi_agent

_home = "/home/pi"
_agent_dir = _home + "/.pi/agent"

# Pi agent config (non-secret parts). models.json (contains the litellm
# API key) is injected via the pi-agent-secrets Secret. The kubeconfig is
# generated from the in-cluster ServiceAccount by the entrypoint.
_settings_json = """{
  "lastChangelogVersion": "0.83.0",
  "packages": [
    "npm:pi-mcp-adapter",
    "npm:pi-ai",
    "npm:pi-telegram-plus"
  ],
  "theme": "dark",
  "defaultProvider": "litellm",
  "defaultModel": "openai/deepseek-v4-flash-q3",
  "defaultProjectTrust": "always",
  "compaction": {
    "enabled": false
  },
  "hideThinkingBlock": false,
  "httpIdleTimeoutMs": 1800000,
  "retry": {
    "enabled": true,
    "maxRetries": 3,
    "baseDelayMs": 2000,
    "provider": {
      "timeoutMs": 7200000,
      "maxRetries": 0,
      "maxRetryDelayMs": 60000
    }
  },
  "defaultThinkingLevel": "high"
}"""

_mcp_json = """{
  "mcpServers": {
    "mcphub": {
      "url": "https://mcphub.mansion.metacoma.org/mcp",
      "transport": "streamable-http",
      "directTools": true
    }
  }
}"""

manifests = [
    # ------------------------------------------------------------------
    # ConfigMap: non-secret pi agent config files
    # ------------------------------------------------------------------
    core.ConfigMap {
        metadata = {
            name = "pi-agent-config"
            namespace = app.namespace
        }
        data = {
            "settings.json": _settings_json
            "mcp.json": _mcp_json
            "auth.json": "{}"
        }
    },

    # ------------------------------------------------------------------
    # Secret: secret pi agent config (resolved from Vault by vals at
    # render time in the ArgoCD repo-server)
    # ------------------------------------------------------------------
    core.Secret {
        metadata = {
            name = "pi-agent-secrets"
            namespace = app.namespace
        }
        type = "Opaque"
        data = {
            # models.json contains the litellm master key
            "models.json": "ref+vault://kv/pi_agent#models_json_base64"
            # sops age private key -> enables decrypting repo secrets in-container
            "age_key": "ref+vault://kv/pi_agent#age_key_base64"
            # vault token for vault CLI / vals / sops_to_vault
            "vault_token": "ref+vault://kv/vault#token_base64"
            # telegram bot bridge config (tg.json with botToken + allowedUserId)
            "tg.json": "ref+vault://kv/pi_agent#tg_json_base64"
        }
    },

    # ------------------------------------------------------------------
    # ServiceAccount: in-cluster auth (entrypoint builds kubeconfig from it)
    # ------------------------------------------------------------------
    core.ServiceAccount {
        metadata = {
            name = app.name
            namespace = app.namespace
        }
    },
    # ClusterRoleBinding (raw dict — rbac types not in the k8s package)
    {
        apiVersion = "rbac.authorization.k8s.io/v1"
        kind = "ClusterRoleBinding"
        metadata = {
            name = app.name + "-admin"
        }
        roleRef = {
            apiGroup = "rbac.authorization.k8s.io"
            kind = "ClusterRole"
            name = "cluster-admin"
        }
        subjects = [{
            kind = "ServiceAccount"
            name = app.name
            namespace = app.namespace
        }]
    },

    # ------------------------------------------------------------------
    # PVC: 20GB working volume mounted at /data (repo clone + sessions)
    # ------------------------------------------------------------------
    core.PersistentVolumeClaim {
        metadata = {
            name = "pi-agent-data"
            namespace = app.namespace
        }
        spec = {
            accessModes = ["ReadWriteOnce"]
            resources = {
                requests = {
                    storage = app.storage
                }
            }
            storageClassName = cfg.config.storageClass
        }
    },

    # ------------------------------------------------------------------
    # Deployment: pi coding agent (entrypoint starts pi in tmux)
    # ------------------------------------------------------------------
    apps.Deployment {
        metadata = {
            name = app.name
            namespace = app.namespace
            labels = {
                app = app.name
            }
        }
        spec = {
            replicas = 1
            selector = {
                matchLabels = {app = app.name}
            }
            template = {
                metadata = {
                    labels = {app = app.name}
                }
                spec = {
                    initContainers = [{
                        # tg.json must be writable (extension persists pairing/offsets),
                        # so copy it from the read-only Secret into a writable emptyDir
                        name = "tg-config-init"
                        image = app.image
                        securityContext = {
                            runAsUser = 0
                        }
                        command = ["sh", "-c", "cp /secret/tg.json /tg-config/tg.json && chown 1001:1001 /tg-config/tg.json && chmod 0600 /tg-config/tg.json"]
                        volumeMounts = [
                            {
                                name = "pi-agent-secrets"
                                mountPath = "/secret"
                            }
                            {
                                name = "tg-config"
                                mountPath = "/tg-config"
                            }
                        ]
                    }]
                    containers = [{
                        name = app.name
                        image = app.image
                        imagePullPolicy = "Always"
                        env = [
                            {
                                name = "PI_PROVIDER"
                                value = app.provider
                            }
                            {
                                name = "PI_MODEL"
                                value = app.model
                            }
                            {
                                # pi works from the 20GB PVC mounted at /data
                                name = "WORKSPACE"
                                value = "/data"
                            }
                            {
                                name = "VAULT_ADDR"
                                value = app.vault.addr
                            }
                            {
                                name = "VAULT_TOKEN"
                                valueFrom = {
                                    secretKeyRef = {
                                        name = "pi-agent-secrets"
                                        key = "vault_token"
                                    }
                                }
                            }
                        ]
                        # pi-agent mostly idles in tmux; keep requests small so it
                        # fits the dense schedulable nodes (mcmp4/6/8)
                        resources = {
                            requests = {
                                cpu = "200m"
                                memory = "512Mi"
                            }
                            limits = {
                                cpu = "2"
                                memory = "4Gi"
                            }
                        }
                        volumeMounts = [
                            # pi config files (non-secret)
                            {
                                name = "pi-agent-config"
                                mountPath = _agent_dir + "/settings.json"
                                subPath = "settings.json"
                            }
                            {
                                name = "pi-agent-config"
                                mountPath = _agent_dir + "/mcp.json"
                                subPath = "mcp.json"
                            }
                            {
                                name = "pi-agent-config"
                                mountPath = _agent_dir + "/auth.json"
                                subPath = "auth.json"
                            }
                            # secret config files
                            {
                                name = "pi-agent-secrets"
                                mountPath = _agent_dir + "/models.json"
                                subPath = "models.json"
                            }
                            {
                                name = "pi-agent-secrets"
                                mountPath = _home + "/.config/sops/age/keys.txt"
                                subPath = "age_key"
                            }
                            {
                                # writable copy of tg.json (see tg-config-init initContainer)
                                name = "tg-config"
                                mountPath = _agent_dir + "/tg.json"
                                subPath = "tg.json"
                            }
                            # 20GB working volume at /data (repo clone + sessions)
                            {
                                name = "pi-agent-data"
                                mountPath = "/data"
                            }
                            {
                                name = "pi-agent-data"
                                mountPath = _agent_dir + "/sessions"
                                subPath = "sessions"
                            }
                        ]
                    }]
                    serviceAccountName = app.name
                    volumes = [
                        {
                            name = "pi-agent-config"
                            configMap = {
                                name = "pi-agent-config"
                            }
                        }
                        {
                            name = "pi-agent-secrets"
                            secret = {
                                secretName = "pi-agent-secrets"
                            }
                        }
                        {
                            name = "pi-agent-data"
                            persistentVolumeClaim = {
                                claimName = "pi-agent-data"
                            }
                        }
                        {
                            name = "tg-config"
                            emptyDir = {}
                        }
                    ]
                }
            }
        }
    }
]
