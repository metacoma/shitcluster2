---
name: vault-secret
description: >
  Add a new secret to the cluster: encrypts it with SOPS, commits to a feature
  branch, creates a PR, and imports it into HashiCorp Vault KV v2.
  Use when the user asks to add, create, or update a secret (password, token,
  API key, SSH key, certificate, etc.).
  NOT for reading existing secrets or modifying non-secret configuration.
---

# Vault Secret

Add a secret to the cluster's secret pipeline: SOPS-encrypted YAML → Git PR → Vault KV v2.

## Secret pipeline

```
secrets/vault_data.sops.yaml  --(sops --set)-->  encrypted YAML
       |                                              |
       +--(git commit + PR)--------------------------+
                                                      |
                                          make sops_to_vault
                                                      |
                                              Vault KV v2
                                                      |
                                    KCL: ref+vault://kv/<section>#<key>
```

## Input parameters

Ask the user for these three values:

1. **Vault path** — the section under `kv/` (e.g. `grafana`, `nats`, `vpn_nl`, `monitoring`)
2. **Key name** — the secret key within that section (e.g. `adminPassword`, `root_user`, `ssh_host`)
3. **Value** — the plaintext secret value

The full Vault path will be `kv/<vault_path>#<key_name>`.
The SOPS YAML path will be `vault_data.<vault_path>.<key_name>`.
The KCL reference will be `ref+vault://kv/<vault_path>#<key_name>`.

## Steps

### 1. Validate inputs

- `vault_path` must be lowercase alphanumeric with underscores (e.g. `my_service`)
- `key_name` must be a valid YAML key (alphanumeric with underscores)
- `value` must not be empty
- Check if the key already exists by reading `secrets/vault_data.sops.yaml` — if it does, ask the user whether to update it

### 2. Encrypt and write to SOPS file

```bash
cd /home/ubuntu/shitcluster/repo
sops --set '["vault_data"]["<vault_path>"]["<key_name>"] "<value>"' secrets/vault_data.sops.yaml
```

**Important:** the value must be JSON-encoded. For strings with special characters (quotes, backslashes, newlines), use proper JSON escaping. For multi-line values (like SSH private keys), pass the value as a single line or use `\n` for line breaks.

### 3. Verify encryption

```bash
# Confirm the file is still valid YAML and the key is encrypted
sops --decrypt secrets/vault_data.sops.yaml | grep -A1 "<key_name>"
```

If decryption fails, abort and report the error.

### 4. Create feature branch and commit

```bash
cd /home/ubuntu/shitcluster/repo
git checkout -b feat/secret-<vault_path>-<key_name>
git add secrets/vault_data.sops.yaml
git commit -m "secret: add <vault_path>.<key_name> to SOPS vault"
git push -u origin feat/secret-<vault_path>-<key_name>
```

### 5. Create PR via GitHub API

```bash
cd /home/ubuntu/shitcluster/repo
TOKEN=$(git remote get-url origin | grep -oP 'ghp_\w+')
curl -s -X POST \
  "https://api.github.com/repos/metacoma/shitcluster2/pulls" \
  -H "Authorization: token $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -d '{
    "title": "secret: add <vault_path>.<key_name>",
    "head": "feat/secret-<vault_path>-<key_name>",
    "base": "master",
    "body": "## Secret added\n\n- **Vault path:** `kv/<vault_path>#<key_name>`\n- **SOPS key:** `vault_data.<vault_path>.<key_name>`\n- **KCL reference:** `ref+vault://kv/<vault_path>#<key_name>`\n\nAfter merge, run `make sops_to_vault` to import into Vault."
  }'
```

### 6. Import into Vault (if cluster is accessible)

If the user confirms the cluster is reachable and Vault is running:

```bash
cd /home/ubuntu/shitcluster/repo
make sops_to_vault
```

This re-imports ALL secrets from `secrets/vault_data.sops.yaml` into Vault KV v2 (it is idempotent — existing keys are overwritten).

If the cluster is not accessible, skip this step and instruct the user to run `make sops_to_vault` after merging the PR.

### 7. Report result

Show the user:
- PR URL (from the API response `html_url`)
- Vault path: `kv/<vault_path>#<key_name>`
- KCL reference: `ref+vault://kv/<vault_path>#<key_name>`
- Whether Vault import succeeded or needs manual execution

## Example

User says: "add Grafana admin password `super_secret_123`"

1. vault_path = `grafana`, key_name = `adminPassword`, value = `super_secret_123`
2. `sops --set '["vault_data"]["grafana"]["adminPassword"] "super_secret_123"' secrets/vault_data.sops.yaml`
3. Verify: `sops --decrypt secrets/vault_data.sops.yaml | grep -A1 adminPassword`
4. Branch: `feat/secret-grafana-adminPassword`, commit, push
5. Create PR
6. `make sops_to_vault` (if cluster reachable)
7. Report: PR URL, Vault path `kv/grafana#adminPassword`, KCL ref `ref+vault://kv/grafana#adminPassword`

## Pitfalls

- **JSON escaping:** `sops --set` expects a JSON-encoded value. Quotes inside the value must be escaped as `\"`. Use Python or `jq` to generate the JSON string if the value contains special characters.
- **Multi-line values:** SSH keys and certificates contain newlines. Replace `\n` with literal `\n` in the JSON string, or use `jq -Rs` to encode.
- **Existing keys:** If the key already exists, `sops --set` overwrites it silently. Always check first.
- **SOPS config:** The `.sops.yaml` in the repo root configures age encryption. Do not modify it.
- **Vault import is all-or-nothing:** `make sops_to_vault` re-imports the entire file. This is idempotent but takes time.
- **Never print decrypted secrets** in the terminal output.
