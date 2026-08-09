import k8s.api.core.v1 as core
import k8s.api.apps.v1 as apps
import config as cfg

app = cfg.config.opencode_mattermost_bridge
oc_app = cfg.config.opencode_agent

# chat-bridge.json — config for the opencode-chat-bridge process.
# Enables the Mattermost connector, sets thread isolation, and configures
# tool message presentation. The ACP backend (opencode) is auto-installed
# by the bridge's entrypoint script at container start.
_chat_bridge_json = """
{
  "botName": "opencode",
  "trigger": "!oc",
  "rateLimitSeconds": 5,
  "toolMessages": {
    "mode": "events",
    "showArguments": false,
    "showOutputFor": ["bash"],
    "maxTraceEntries": 20
  },
  "sessionStorePath": "/data/sessions/chat-sessions.json",
  "mattermost": {
    "enabled": true,
    "url": "{env:MATTERMOST_URL}",
    "token": "{env:MATTERMOST_TOKEN}",
    "teamName": "",
    "respondToMentions": true,
    "ignoreChannels": [],
    "ignoreUsers": [],
    "allowedUsers": [],
    "threadIsolation": true
  }
}
"""

# opencode.json — provider config + agent permissions for the bridge.
# The provider section tells opencode how to reach our local LiteLLM;
# without it opencode falls back to its built-in cloud model.
_opencode_json = """
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "litellm": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "LiteLLM",
      "options": {
        "baseURL": "https://litellm.mansion.metacoma.org/v1",
        "apiKey": "ref+vault://kv/litellm#master_key"
      },
      "models": {
        "openai/qwen36-27b": {
          "name": "Qwen 3.6 27B"
        },
        "openai/qwen36-35b": {
          "name": "Qwen 3.6 35B"
        },
        "openai/gemma4-31b": {
          "name": "Gemma 4 31B"
        },
        "openai/deepseek-v4-flash-q3": {
          "name": "DeepSeek V4 Flash Q3"
        }
      }
    }
  },
  "default_agent": "chat-bridge",
  "agent": {
    "chat-bridge": {
      "description": "OpenCode chat bridge agent",
      "mode": "primary",
      "permission": {
        "read": "allow",
        "edit": "allow",
        "write": "allow",
        "bash": "allow",
        "glob": "allow",
        "grep": "allow",
        "task": "allow"
      }
    }
  }
}
"""

manifests = [
    # ------------------------------------------------------------------
    # ConfigMap: bridge configuration (chat-bridge.json only)
    # ------------------------------------------------------------------
    core.ConfigMap {
        metadata = {
            name = app.name + "-config"
            namespace = app.namespace
        }
        data = {
            "chat-bridge.json": _chat_bridge_json
        }
    }
    # ------------------------------------------------------------------
    # Deployment: opencode-chat-bridge (Mattermost connector)
    # Shares the same PVC as opencode-agent-k8s for /data workspace.
    # The bridge installs opencode at runtime and spawns it via ACP stdio.
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
                    # Keep bridge on the same node as opencode-agent-k8s so
                    # the shared RWO PVC (opencode-agent-data) is accessible
                    affinity = {
                        podAffinity = {
                            requiredDuringSchedulingIgnoredDuringExecution = [{
                                labelSelector = {
                                    matchExpressions = [{
                                        key = "app"
                                        operator = "In"
                                        values = [oc_app.name]
                                    }]
                                }
                                topologyKey = "kubernetes.io/hostname"
                            }]
                        }
                    }
                    containers = [{
                        name = app.name
                        image = app.image
                        imagePullPolicy = "Always"
                        env = [
                            {
                                name = "CONNECTOR"
                                value = "mattermost"
                            }
                            {
                                name = "MATTERMOST_URL"
                                value = app.mattermost_url
                            }
                            {
                                name = "OPENCODE_MODEL_PROVIDER"
                                value = "litellm"
                            }
                            {
                                name = "OPENCODE_MODEL_ID"
                                value = "openai/qwen36-27b"
                            }
                            {
                                name = "MATTERMOST_TOKEN"
                                valueFrom = {
                                    secretKeyRef = {
                                        name = app.name + "-secrets"
                                        key = "mattermost_token"
                                    }
                                }
                            }
                            {
                                # Session data stored on the shared PVC
                                name = "SESSION_BASE_DIR"
                                value = "/data/sessions"
                            }
                            {
                                name = "SESSION_RETENTION_DAYS"
                                value = "7"
                            }
                        ]
                        resources = {
                            requests = {
                                cpu = "100m"
                                memory = "256Mi"
                            }
                            limits = {
                                cpu = "1"
                                memory = "2Gi"
                            }
                        }
                        volumeMounts = [
                            # Bridge config files
                            {
                                name = "bridge-config"
                                mountPath = "/app/chat-bridge.json"
                                subPath = "chat-bridge.json"
                            }
                            # opencode provider + agent config (contains API key)
                            {
                                name = "bridge-secrets"
                                mountPath = "/app/opencode.json"
                                subPath = "opencode.json"
                            }
                            # Shared workspace (same PVC as opencode-agent-k8s)
                            {
                                name = "opencode-agent-data"
                                mountPath = "/data"
                            }
                        ]
                    }]
                    volumes = [
                        {
                            name = "bridge-config"
                            configMap = {
                                name = app.name + "-config"
                            }
                        }
                        {
                            name = "bridge-secrets"
                            secret = {
                                secretName = app.name + "-secrets"
                            }
                        }
                        {
                            name = "opencode-agent-data"
                            persistentVolumeClaim = {
                                claimName = "opencode-agent-data"
                            }
                        }
                    ]
                }
            }
        }
    }
    # ------------------------------------------------------------------
    # Secret: Mattermost bot token + opencode.json (provider config
    # with litellm API key). opencode.json is here (not ConfigMap) because
    # it contains the litellm master API key.
    # ------------------------------------------------------------------
    core.Secret {
        metadata = {
            name = app.name + "-secrets"
            namespace = app.namespace
        }
        type = "Opaque"
        stringData = {
            "mattermost_token": app.mattermost_token
            "opencode.json": _opencode_json
        }
    }
]
