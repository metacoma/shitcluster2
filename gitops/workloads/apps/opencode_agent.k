import k8s.api.core.v1 as core
import k8s.api.apps.v1 as apps
import config as cfg

app = cfg.config.opencode_agent

_home = "/home/opencode"
_config_dir = _home + "/.config/opencode"
_data_dir = _home + "/.local/share/opencode"

# Global agent rules — the opencode-telegram bot mirrors assistant replies,
# tool calls and tool output to Telegram, so the agent must never paste raw
# secrets into replies. Loaded by opencode from ~/.config/opencode/AGENTS.md.
# Also shipped in the image; mounted here so it can be updated without a
# rebuild.
_agents_md = """# Global agent rules (opencode-agent container)

These rules apply to every OpenCode session running in this container,
regardless of the project. They are loaded from `~/.config/opencode/AGENTS.md`.

## Secret handling — the Telegram bridge mirrors everything you write

Every assistant reply, tool call, and thinking block is **mirrored to the
Telegram bot chat** by the opencode-telegram bot. Treat everything you output
as public to anyone with access to that chat:

- **NEVER paste raw secrets (passwords, tokens, API keys, private keys,
  decrypted SOPS/Vault values) into your replies.** Replace every secret with
  a redacted placeholder:
  - password/token values → `***`
  - private keys → `[redacted key]`
  - decrypted values you were asked to show → show only the first/last few
    chars, e.g. `abcd…wxyz`
- When you need to reference a secret (e.g. "run `make argocd_password`"),
  describe the command instead of pasting the resulting value.
- If a tool returns secret material (e.g. `sops -d`, `vault kv get`, reading
  `.env`), do NOT copy it into your reply text — summarize what it contains.
- The TUI/Telegram mirror cannot be disabled per-message: assume every
  assistant message is visible in Telegram.

## General container hygiene

- `~/.local/share/opencode/auth.json` and the injected Secret contain bot
  tokens and API keys — never print their contents.
- Session data under `~/.local/share/opencode/` may contain secret material —
  never attach or `cat` full sessions to Telegram.
"""

manifests = [
    # ------------------------------------------------------------------
    # ConfigMap: global agent rules (opencode reads AGENTS.md from its
    # global config dir; also baked into the image)
    # ------------------------------------------------------------------
    core.ConfigMap {
        metadata = {
            name = "opencode-agent-config"
            namespace = app.namespace
        }
        data = {
            "AGENTS.md": _agents_md
        }
    }
    # ------------------------------------------------------------------
    # Secret: opencode.json (litellm provider config with API key),
    # Telegram bridge credentials, vault/github tokens. Resolved from
    # Vault by vals at render time in the ArgoCD repo-server.
    # (Secret data values must be valid base64 — hence *_base64 keys.)
    # ------------------------------------------------------------------
    core.Secret {
        metadata = {
            name = "opencode-agent-secrets"
            namespace = app.namespace
        }
        type = "Opaque"
        data = {
            # opencode.json contains the litellm provider + API key
            "opencode.json": "ref+vault://kv/opencode_agent#opencode_json_base64"
            # telegram bridge credentials (bot token + allowed user id)
            "tg_token": "ref+vault://kv/opencode_agent#telegram_token_base64"
            "tg_user_id": "ref+vault://kv/opencode_agent#telegram_user_id_base64"
            # vault token for vault CLI / vals / sops_to_vault
            "vault_token": "ref+vault://kv/vault#token_base64"
            # GH_TOKEN (metacoma) -> git push/pull to github.com from the pod
            "gh_token": "ref+vault://kv/metacoma#github_base64"
            # sops age private key -> decrypting repo secrets in-container
            "age_key": "ref+vault://kv/pi_agent#age_key_base64"
        }
    }
    # ------------------------------------------------------------------
    # ServiceAccount: in-cluster auth (entrypoint builds kubeconfig from it)
    # ------------------------------------------------------------------
    core.ServiceAccount {
        metadata = {
            name = app.name
            namespace = app.namespace
        }
    }
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
    }
    # ------------------------------------------------------------------
    # PVC: 20GB working volume mounted at /data (repo clone + opencode data)
    # ------------------------------------------------------------------
    core.PersistentVolumeClaim {
        metadata = {
            name = "opencode-agent-data"
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
    }
    # ------------------------------------------------------------------
    # Deployment: opencode agent (entrypoint starts opencode serve + the
    # telegram bridge; container stays alive via the foreground bot)
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
                    containers = [{
                        name = app.name
                        image = app.image
                        imagePullPolicy = "Always"
                        env = [
                            {
                                name = "TELEGRAM_BOT_TOKEN"
                                valueFrom = {
                                    secretKeyRef = {
                                        name = "opencode-agent-secrets"
                                        key = "tg_token"
                                    }
                                }
                            }
                            {
                                name = "TELEGRAM_ALLOWED_USER_ID"
                                valueFrom = {
                                    secretKeyRef = {
                                        name = "opencode-agent-secrets"
                                        key = "tg_user_id"
                                    }
                                }
                            }
                            {
                                name = "OPENCODE_API_URL"
                                value = "http://127.0.0.1:" + str(app.oc_port)
                            }
                            {
                                name = "OPENCODE_MODEL_PROVIDER"
                                value = app.model_provider
                            }
                            {
                                name = "OPENCODE_MODEL_ID"
                                value = app.model
                            }
                            {
                                name = "BOT_LOCALE"
                                value = "ru"
                            }
                            {
                                # opencode works from the 20GB PVC mounted at /data
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
                                        name = "opencode-agent-secrets"
                                        key = "vault_token"
                                    }
                                }
                            }
                            {
                                name = "GH_TOKEN"
                                valueFrom = {
                                    secretKeyRef = {
                                        name = "opencode-agent-secrets"
                                        key = "gh_token"
                                    }
                                }
                            }
                        ]
                        # mostly idles in the telegram bot loop; keep requests
                        # small so it fits the dense schedulable nodes
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
                            # opencode.json (litellm provider config with API key)
                            {
                                name = "opencode-agent-secrets"
                                mountPath = "/etc/opencode-agent/opencode.json"
                                subPath = "opencode.json"
                            }
                            # sops age key -> enables decrypting repo secrets in-container
                            {
                                name = "opencode-agent-secrets"
                                mountPath = _home + "/.config/sops/age/keys.txt"
                                subPath = "age_key"
                            }
                            # global agent rules (updatable without image rebuild)
                            {
                                name = "opencode-agent-config"
                                mountPath = _config_dir + "/AGENTS.md"
                                subPath = "AGENTS.md"
                            }
                            # 20GB working volume at /data (repo clone + workspace)
                            {
                                name = "opencode-agent-data"
                                mountPath = "/data"
                            }
                            # opencode sessions/data persisted on the PVC
                            {
                                name = "opencode-agent-data"
                                mountPath = _data_dir
                                subPath = "opencode"
                            }
                        ]
                    }]
                    serviceAccountName = app.name
                    volumes = [
                        {
                            name = "opencode-agent-config"
                            configMap = {
                                name = "opencode-agent-config"
                            }
                        }
                        {
                            name = "opencode-agent-secrets"
                            secret = {
                                secretName = "opencode-agent-secrets"
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
]
