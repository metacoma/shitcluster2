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

## KCL conventions

- Never edit generated YAML — always modify the `.k` source file
- New apps go in `gitops/workloads/apps/` as a single `.k` file exporting `manifests`
- Import the app in `gitops/workloads/main.k` and add to `resources` list
- Shared config lives in `gitops/workloads/config.k` (namespaces, Helm versions, Vault refs)
- Vault secret references use format: `ref+vault://kv/<path>#<key>`
- Follow existing patterns in `gitops/workloads/apps/` — do not invent new schemas
- Tmux sessions use schema from `tmux/schema.k` (Tmux, Window, Env types)

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
