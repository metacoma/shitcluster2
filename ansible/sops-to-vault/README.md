# SOPS → Vault Import Playbook

Automatically decrypts a [SOPS](https://github.com/getsops/sops)-encrypted YAML file and imports all secrets into [HashiCorp Vault](https://www.vaultproject.io/) KV v2.

## How It Works

```
sops-encrypted YAML → sops --decrypt → recursive include_tasks → Vault KV v2
```

1. **Decrypt** — `sops --decrypt` with age key
2. **Walk** — recursively walks the YAML tree using `include_tasks` with `write_secret.yml`
3. **Classify** — at each level, separates leaf values (`is not mapping`) from nested dicts (`is mapping`)
4. **Import** — writes leaf values to Vault via `community.hashi_vault.vault_kv2_write`

### Path Mapping

The SOPS top-level key `vault_data` is stripped (via `strip_prefix`), so:

| SOPS Key | Vault Path | KCL Reference |
|---|---|---|
| `vault_data.grafana.adminUser` | `kv/grafana` | `ref+vault://kv/grafana#adminUser` |
| `vault_data.vpn_nl.ssh_host` | `kv/vpn_nl` | `ref+vault://kv/vpn_nl#ssh_host` |
| `mnt_users.mcmp2.password` | `kv/mnt_users/mcmp2` | — |

## Prerequisites

```bash
# Install sops + age
# Install ansible
pip install ansible hvac PyYAML
ansible-galaxy collection install -r requirements.yml
```

## Usage

```bash
ansible-playbook sops_to_vault.yml \
  -e age_key_file=/path/to/age/keys.txt \
  -e sops_file=/path/to/vault_data.sops.yaml \
  -e vault_addr=http://vault:8200 \
  -e vault_token=hvs.xxx \
  -e vault_mount=kv \
  -e strip_prefix=vault_data
```

## Parameters

| Variable | Description | Default |
|---|---|---|
| `age_key_file` | Path to age private key | `~/.config/sops/age/keys.txt` |
| `sops_file` | Path to SOPS-encrypted YAML | `secrets/vault_data.sops.yaml` |
| `vault_addr` | Vault HTTP address | `http://127.0.0.1:8200` |
| `vault_token` | Vault auth token | *(required)* |
| `vault_mount` | KV v2 mount point | `kv` |
| `strip_prefix` | Prefix to strip from paths | `""` |
| `validate_certs` | Verify Vault TLS certs | `false` |

## Files

| File | Purpose |
|---|---|
| `sops_to_vault.yml` | Main playbook |
| `write_secret.yml` | Recursive task: classify + write + recurse |
| `requirements.yml` | Ansible Galaxy collection deps |
