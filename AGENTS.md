# shitcluster

GitOps repository for homelab Kubernetes cluster. Ansible (Kubespray) for base infra, KCL for GitOps manifests, ArgoCD for delivery, SOPS+age for secrets, Vault for runtime secret injection.

## Stack

- Ansible 11 + Kubespray v2.31.0 (CRI-O, Calico BGP, MetalLB L2, kube-vip)
- KCL (Kubernetes Configuration Language) for manifest generation
- ArgoCD with KCL CMP plugin + AVP (argocd-vault-plugin)
- HashiCorp Vault (Helm 0.34.0) + SOPS/age encryption
- Longhorn 1.11.3 (block storage with Whereabouts CNI)
- Istio 1.28.1, Knative 1.20.0, NATS 2.12.4
- VictoriaMetrics + Grafana + Loki + Tempo + Vector (observability)

## Repository structure

```
ansible/                — Kubespray, network, Longhorn node prep
ansible/group_vars/     — Cluster-wide Ansible vars (Calico, MetalLB, kube-vip)
ansible/host_vars/      — Per-node Ansible vars
gitops/infra/           — KCL infra module (Tekton, SOPS secrets namespace)
gitops/workloads/       — KCL workloads module (apps, monitoring, networking)
gitops/workloads/apps/  — Per-app KCL files (*.k). Add new apps here.
tmux/                   — KCL tmux session configs (schema.k defines types)
tmux/sessions/          — Individual tmux session definitions
secrets/                — SOPS-encrypted YAML (age key in .sops.yaml)
vault-data/             — Terraform/OpenTofu for Vault (rarely used)
argocd/                 — ArgoCD Helm values, CMP plugins, Application JSON
Makefile                — Orchestration: kubernetes, longhorn, vault, argocd
```

## Commands

- `make kubernetes` — Install K8s via Kubespray (does NOT reset; run `make kubernetes_reset` first if needed)
- `make longhorn` — Node prep + Whereabouts CNI + Longhorn Helm + BackupTarget
- `make vault` — Install Vault Helm, wait for init, extract root token
- `make sops_to_vault` — Decrypt SOPS secrets, import to Vault KV v2
- `make argocd_prepare` — Create Vault namespace, policies, tokens, K8s secrets
- `make argocd` — Install ArgoCD Helm + KCL CMP + AVP plugin
- `make argocd_infra_app` / `make argocd_workloads_app` — Create ArgoCD Applications
- `make flow` — Full deployment pipeline (all steps in order)
- `make update_kubeconfig` — Fetch kubeconfig from mcmp2 via SSH
- `make -C ansible ansible_lint` — Lint Ansible playbooks
- `make -C ansible ansible_ping` — Ping cluster nodes
- `cd gitops/workloads && kcl run .` — Validate/render workload manifests
- `cd gitops/infra && kcl run .` — Validate/render infra manifests
- `kcl fmt .` — Format KCL files

## GitOps architecture

### Pipeline overview

```
Git repo → ArgoCD repo-server → KCL CMP plugin (kcl run | vals eval) → Kubernetes API
```

ArgoCD repo-server runs two sidecar containers:
- **my-plugin** — KCL + vals image (`ghcr.io/metacoma/kcl-vals:latest`). Runs `kcl run` to generate YAML, then pipes through `vals eval` which resolves `ref+vault://` references by querying Vault.
- **avp** — argocd-vault-plugin (AVP) for raw YAML files with `<path|avp.kubernetes.io>` or `avp.kubernetes.io` annotations.

### ArgoCD Applications

| Application | Source path | Plugin | Purpose |
|---|---|---|---|
| `infra` | `gitops/infra` | `kcl-v1.0` | Infra resources (namespace, SOPS secret, Tekton) |
| `workloads` | `gitops/workloads` | `kcl-v1.0` | All workloads (apps, monitoring, networking) |
| `argocd-vault` | `gitops/argocd-vault` | `kcl-v1.0` | KCL manifests with Vault refs (dir does not exist yet) |
| `argocd-vault-raw` | `gitops/argocd-vault-raw` | `argocd-vault-plugin` | Raw YAML with AVP annotations (dir does not exist yet) |

All applications use `in-cluster` connection (`https://kubernetes.default.svc`), auto-sync with self-heal, and target `master` branch.

### KCL module structure

Each module (infra, workloads) has its own `kcl.mod` with dependencies. Structure:

```
gitops/<module>/
  kcl.mod          — package deps (k8s, argoproj, custom operators)
  kcl.mod.lock     — LOCKED, auto-generated
  main.k           — entry point: imports apps, exports manifests.yaml_stream([...])
  config.k         — shared config dict (namespaces, Helm versions, Vault refs)
  apps/            — per-app .k files, each exporting `manifests`
```

**main.k pattern:**
```kcl
import .apps.foo as foo
import .apps.bar as bar

resources = [foo.manifests, bar.manifests]
manifests.yaml_stream([resources])
```

**config.k pattern:**
```kcl
config = {
  app = {
    namespace = "app-ns"
    secret = "ref+vault://kv/app#secret"
  }
}
```

**app.k pattern** — each file in `apps/` exports a `manifests` variable (list of K8s resources). Two deployment patterns:

1. **Native K8s resources** — directly define `k8s.Namespace`, `k8s.Secret`, `v1.Deployment`, etc. (e.g., `ssh_tunnel.k`, `spaceship_dns.k`)
2. **Nested ArgoCD Application** — define `argoproj.Application` that points to a Helm chart. The nested app is managed by ArgoCD as a child of the parent application. Use a lambda helper like `monitoring_app(helm_config, values, sync)` for DRY Helm app generation (e.g., `monitoring.k`, `istio.k`, `observability.k`, `vector.k`, `nats.k`)

### KCL dependencies (workloads)

| Package | OCI registry | Tag | Purpose |
|---|---|---|---|
| `k8s` | ghcr.io/kcl-lang/k8s | 1.31.2 | Core K8s types (v1.Namespace, v1.Deployment, etc.) |
| `argoproj` | ghcr.io/kcl-lang/argoproj | 3.0.12 | ArgoCD Application CRD |
| `knative-operator` | ghcr.io/kcl-lang/knative-operator | 0.3.0 | KnativeServing, KnativeEventing CRDs |
| `kubevirt` | ghcr.io/kcl-lang/kubevirt | 0.3.0 | NetworkAttachmentDefinition |
| `victoria-metrics-operator` | ghcr.io/kcl-lang/victoria-metrics-operator | 0.45.3 | VMServiceScrape CRD |

### Adding a new app

1. Create `gitops/workloads/apps/<name>.k` exporting `manifests`
2. Add Vault secrets to `secrets/vault_data.sops.yaml` under `vault_data.<name>`
3. Add config section in `gitops/workloads/config.k`
4. Import in `gitops/workloads/main.k` and add `.<name>.manifests` to `resources`
5. Run `cd gitops/workloads && kcl run .` to validate locally
6. Commit and push — ArgoCD will sync

## Secrets management

### Full secret lifecycle

```
secrets/vault_data.sops.yaml (SOPS encrypted in Git)
    ↓ sops --decrypt (ansible/sops-to-vault/)
Vault KV v2 (kv/<section>#<key>)
    ↓ vals eval at render time (ref+vault://kv/<section>#<key>)
K8s Secret / ConfigMap / Helm values (in cluster)
```

### Step 1: SOPS encryption (Git storage)

- File: `secrets/vault_data.sops.yaml`
- Encryption: SOPS 3.11.0 with age (`.sops.yaml` config)
- Age recipient: `age1e2rey5g5p5jkp0fs25r8n4der46cx5wrtdf8exn6yc3g0wvuc4psrg05g3`
- All values encrypted (`encrypted_regex: .*`)
- Structure: top-level keys become Vault paths (with `strip_prefix=vault_data`)

### Step 2: Import to Vault

- `make sops_to_vault` runs `ansible/sops-to-vault/sops_to_vault.yml`
- Decrypts with `sops --decrypt`, recursively walks YAML tree
- Leaf values → `vault_kv2_write` at `kv/<path>`
- Nested dicts → recursive sub-paths (e.g., `mnt_users.mcmp2` → `kv/mnt_users/mcmp2`)
- `strip_prefix=vault_data` strips the top-level key, so `vault_data.grafana` → `kv/grafana`

### Step 3: Vault → KCL at render time (vals)

The KCL CMP plugin runs `kcl run | vals eval`. vals resolves references:

**Format:** `ref+vault://kv/<path>#<key>`

| KCL reference | Vault path | Key | Example |
|---|---|---|---|
| `ref+vault://kv/grafana#adminUser` | `kv/grafana` | `adminUser` | Grafana admin login |
| `ref+vault://kv/vpn_nl#ssh_private_key_base64` | `kv/vpn_nl` | `ssh_private_key_base64` | SSH key (base64) |
| `ref+vault://kv/nats#root_user+` | `kv/nats` | `root_user` | NATS user (note `+` suffix) |
| `ref+vault://kv/sops/gitops#public_key` | `kv/sops/gitops` | `public_key` | SOPS age public key |

**Trailing `+` suffix** (e.g., `ref+vault://kv/nats#root_user+`): explicit expression terminator for inline string interpolation. Without `+`, vals treats everything until end-of-line as the expression. With `+`, the expression ends at `+`, allowing text after it. This is NOT base64 decoding — for that, use `?decode=base64` query parameter.

### Step 4: Vault credentials for ArgoCD

Two K8s secrets in `argocd` namespace (created by `ansible/argocd-vault-setup.yml`):

| Secret | Used by | Contents |
|---|---|---|
| `argocd-vault-credentials` | vals / KCL sidecar | `VAULT_ADDR`, `VAULT_TOKEN` |
| `argocd-vault-plugin-credentials` | AVP sidecar + repo-server | `AVP_TYPE=vault`, `AVP_AUTH_TYPE=token`, `VAULT_ADDR`, `VAULT_TOKEN` |

Both use the same Vault token created with `argocd-vals` policy (read access to all paths).

### vals expression syntax (all supported backends)

General syntax: `ref+BACKEND://PATH[?PARAMS][#FRAGMENT][+]`

- `BACKEND` — provider identifier (see table below)
- `PATH` — backend-specific path to the secret
- `PARAMS` — URL query parameters (`key=value&key2=value2`)
- `FRAGMENT` — `#/key/in/response` extracts a nested value from JSON/YAML response
- `+` — explicit expression terminator for inline interpolation (e.g., `prefix ref+vault://kv/a#b+ suffix`)

**Two prefixes:**
- `ref+BACKEND://...` — regular value reference (resolved by `vals eval`)
- `secretref+BACKEND://...` — marked as secret (preserved as-is when running `vals eval --exclude-secret`, useful for GitOps review workflows)

**Vault-specific query params:**
- `address` — Vault address (defaults to `VAULT_ADDR` env)
- `token_env` — env var containing Vault token (defaults to `VAULT_TOKEN`)
- `token_file` — file path containing Vault token
- `namespace` — Vault namespace (defaults to `VAULT_NAMESPACE` env)
- `auth_method` — `token` (default), `approle`, `kubernetes`, `userpass`
- `decode` — `raw` (default) or `base64` (base64-decode the value before returning)
- `version` — specific secret version to retrieve

### AVP (argocd-vault-plugin) reference formats

| Format | Context | Example |
|---|---|---|
| `<path\|avp.kubernetes.io>` | Inline in raw YAML values | `password: <kv/data/app\|avp.kubernetes.io>` |
| `avp.kubernetes.io/path` annotation | Annotation on Secret/ConfigMap | `avp.kubernetes.io/path: "kv/data/app"` |

AVP is available as a separate sidecar (`avp` container) in argocd-repo-server but is **not currently used** in this repo — all secret resolution goes through vals.

### How secrets reach the cluster

Secrets from Vault are injected at **manifest render time** (in ArgoCD repo-server), not at pod runtime:

1. KCL file contains `ref+vault://...` strings
2. `kcl run` generates YAML with literal `ref+vault://...` strings
3. `vals eval` replaces those strings with actual Vault values
4. ArgoCD applies the resulting YAML to the cluster
5. Secrets appear as K8s `Secret` resources (or inline in ConfigMaps/Helm values)

**Important:** The rendered values are NOT stored in Git — they only exist in the ArgoCD repo-server memory during rendering and in the live cluster as K8s resources.

### Adding new secrets

1. Add key to `secrets/vault_data.sops.yaml` under `vault_data.<section>`
2. Encrypt: `sops secrets/vault_data.sops.yaml` (auto-encrypts on save if configured)
3. Import: `make sops_to_vault`
4. Reference in KCL: `"ref+vault://kv/<section>#<key>"`

## Ansible conventions

- Playbooks run against `ansible/inventory.yml` (nodes: mcmp2–mcmp9, mcmp5 excluded)
- Cluster vars in `ansible/group_vars/all.yaml` (Calico BGP, MetalLB pools, kube-vip)
- Use `make -C ansible ansible_run ANSIBLE_ARGS="..."` for ad-hoc playbook runs
- Python deps in `ansible/.venv/` (created via `make -C ansible ansible_requirements`)

## Boundaries

- NEVER commit plaintext secrets — use SOPS (`secrets/*.sops.yaml` only)
- NEVER edit `kcl.mod.lock` (auto-generated)
- NEVER edit `gitops/infra/tekton-pipelines.yml` (template/partially generated)
- NEVER edit files marked `generated` or `managed by`
- NEVER run `make kubernetes_reset` without explicit user confirmation (destroys cluster state)
- KCL changes affect live cluster via ArgoCD — verify against cluster state before committing
- `.env` contains secrets — never commit or print its contents

## Git workflow

- Branch format: `type/short-description` (feat, fix, chore, docs)
- Conventional commits: `feat:`, `fix:`, `chore:`, `docs:`
- Atomic commits — one logical change per commit
- Run `git diff --check` before committing
- Squash merge on PR
