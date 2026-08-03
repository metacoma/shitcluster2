import k8s.api.core.v1 as k8s
import k8s.api.apps.v1 as v1
import config

# lrstanley/vault-unseal: https://github.com/lrstanley/vault-unseal
# Auto-unseals Vault by polling seal status and submitting unseal keys.
#
# All config via env vars (no config file needed).
# Env var mapping: NODES, TOKENS, CHECK_INTERVAL, MAX_CHECK_INTERVAL,
# ALLOW_SINGLE_NODE, LOG_JSON, LOG_LEVEL, ENVIRONMENT.
_vault_ns = config.infra.vault.ns
_vault_addr = "${config.infra.vault.scheme}://${config.infra.vault.service}.${_vault_ns}.svc:${config.infra.vault.port}"
_image = "ghcr.io/lrstanley/vault-unseal"
_image_tag = "1.0.0"

manifests = [
    v1.Deployment {
        metadata = {
            name = "vault-unseal"
            namespace = _vault_ns
            labels = {app = "vault-unseal"}
        }
        spec = {
            replicas = 1
            selector.matchLabels = {app = "vault-unseal"}
            template = {
                metadata = {
                    labels = {app = "vault-unseal"}
                }
                spec = {
                    nodeSelector = {
                        "node-role.kubernetes.io/worker" = ""
                    }
                    tolerations = [{
                        key = "node-role.kubernetes.io/control-plane"
                        operator = "Exists"
                        effect = "NoSchedule"
                    }]
                    containers = [{
                        name = "vault-unseal"
                        image = "${_image}:${_image_tag}"
                        imagePullPolicy = "IfNotPresent"
                        env = [
                            {name = "NODES", value = _vault_addr}
                            {name = "CHECK_INTERVAL", value = "15s"}
                            {name = "MAX_CHECK_INTERVAL", value = "5m"}
                            {name = "ALLOW_SINGLE_NODE", value = "true"}
                            {name = "LOG_JSON", value = "true"}
                            {name = "LOG_LEVEL", value = "info"}
                            {name = "ENVIRONMENT", value = "shitcluster"}
                            {
                                name = "TOKENS"
                                valueFrom = {
                                    secretKeyRef = {
                                        name = "vault-bootstrap"
                                        key = "unseal_key"
                                    }
                                }
                            }
                        ]
                    }]
                }
            }
        }
    }
]
