---
name: argocd-deploy
description: >
  Deploy ArgoCD to the shitcluster: prepare Vault for ArgoCD, install Helm chart,
  create KCL CMP plugins, and create Application manifests. Use when the user asks
  to deploy, install, or re-deploy ArgoCD on the cluster.
  NOT for troubleshooting existing ArgoCD issues or managing Applications.
---

# ArgoCD Deployment Skill

Deploy ArgoCD (v9.1.0) to the cluster with KCL CMP plugin, AVP, and Application manifests.

## Pre-flight checks

Before deploying, ensure:
- Cluster is accessible (`kubectl get nodes` works)
- Vault is deployed and unsealed (`kubectl get pods -n vault`)
- All SOPS secrets are in Vault (`make sops_to_vault` was run)
- Namespace `argocd` does not exist (or you want to uninstall first)

## Deploy flow

### 1. Prepare Vault for ArgoCD

```bash
cd /home/ubuntu/shitcluster/repo
make argocd_prepare
```

This playbook:
- Creates namespace `argocd`
- Enables KV v2 mount at `kv/` (idempotent)
- Creates test secret `kv/argocd-test`
- Writes SOPS/Age keys to `kv/sops/gitops`
- Creates Vault policy `argocd-vals` (read-all)
- Creates Vault token with that policy
- Creates K8s secrets: `argocd-vault-credentials` + `argocd-vault-plugin-credentials`

Verify:
```bash
kubectl get secret -n argocd argocd-vault-credentials -o jsonpath='{.data.VAULT_ADDR}' | base64 -d; echo
kubectl get secret -n argocd argocd-vault-plugin-credentials -o jsonpath='{.data.VAULT_ADDR}' | base64 -d; echo
```

### 2. Install ArgoCD Helm chart

```bash
cd /home/ubuntu/shitcluster/repo
make argocd
```

This does:
1. Creates `cmp-plugin` ConfigMap with AVP YAML
2. Helm installs `argocd/argo-cd` v9.1.0 into `argocd` namespace
3. Creates `kcl-plugin-config` ConfigMap (with race condition fix: KCL_CACHE_PATH=/tmp)
4. Patches `argocd-repo-server` deployment:
   - initContainer downloads argocd-vault-plugin v1.16.1 to `/custom-tools/`
   - Sidecar `avp` runs AVP with AVP credentials
   - Sidecar `my-plugin` runs KCL/vals with KCL credentials
5. Waits for repo-server pod to be ready

Verify:
```bash
kubectl get pods -n argocd
# All 7 pods should be Running
kubectl get svc -n argocd argocd-server
# Should show LoadBalancer with EXTERNAL-IP 172.25.1.2
```

### 3. Create Applications

```bash
cd /home/ubuntu/shitcluster/repo
make argocd_infra_app
make argocd_workloads_app
```

This creates two Applications:
- **infra** — syncs `gitops/infra` from GitHub (Tekton, SOPS secrets namespace)
- **workloads** — syncs `gitops/workloads` from GitHub (apps, monitoring, networking)

Both use:
- KCL CMP plugin (`kcl-v1.0`) for manifest generation
- Auto-sync with selfHeal + prune
- `SkipDryRunOnMissingResource=true` for workloads

### 4. Wait for sync

```bash
cd /home/ubuntu/shitcluster/repo
make argocd_wait_infra
make argocd_wait_workloads
```

Or check manually:
```bash
kubectl -n argocd get applications
# All should be Synced/Healthy
```

## Uninstall

```bash
cd /home/ubuntu/shitcluster/repo
make argocd_uninstall
```

Then clean up secrets:
```bash
kubectl delete namespace argocd
kubectl delete secret -n vault vault-bootstrap
```

## Full deployment pipeline

```bash
cd /home/ubuntu/shitcluster/repo
make flow
# Equivalent to:
# kubernetes update_kubeconfig longhorn vault sops_to_vault \
#   argocd_prepare argocd argocd_infra_app argocd_workloads_app
```

## Troubleshooting

### Repo-server stuck not ready
```bash
# Check if AVP binary downloaded correctly
kubectl exec -n argocd -c download-tools $(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}') -- ls -la /custom-tools/

# Check AVP sidecar logs
kubectl logs -n argocd -c avp <repo-server-pod> --tail=50
```

### Applications show Missing/OutOfSync
```bash
# Hard refresh
kubectl -n argocd annotate application <name> argocd.argoproj.io/refresh=hard --overwrite

# Check Application source
kubectl -n argocd get application <name> -o jsonpath='{.spec.source}'
# Should point to https://github.com/metacoma/shitcluster2

# Check plugin execution
kubectl -n argocd get application <name> -o jsonpath='{.status.sourceStatus}'
```

### ArgoCD server not accessible
```bash
# Check LoadBalancer IP assignment
kubectl get svc -n argocd argocd-server -o wide

# If EXTERNAL-IP is pending, check MetalLB logs
kubectl logs -n metallb-system -l app=metallb -c controller --tail=50
kubectl logs -n metallb-system -l app=metallb -c speaker --tail=50
```

### Password reset
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

## Key files

| File | Purpose |
|------|---------|
| `argocd/argocd_values.yml` | Helm values (nodeSelector, LoadBalancer IP, server.insecure) |
| `argocd/cmp-plugin-avp.yaml` | AVP ConfigManagementPlugin |
| `argocd/kcl-cmp.yaml` | KCL CMP plugin ConfigMap with race condition fix |
| `argocd/patch-argocd-repo-server.yaml` | Patch for AVP sidecar + KCL/vals sidecar + tool download |
| `argocd/infra.json` | Application "infra" manifest |
| `argocd/workloads.json` | Application "workloads" manifest |
| `ansible/argocd-vault-setup.yml` | Vault setup playbook (policy, token, K8s secrets) |

## Pitfalls

- **KV mount at wrong path:** If Vault KV is mounted at `secret/` instead of `kv/`, the AVP plugin will fail to find secrets. The `argocd_prepare` playbook mounts at `kv/`.
- **Missing Vault credentials:** Both `argocd-vault-credentials` and `argocd-vault-plugin-credentials` must exist in `argocd` namespace.
- **AVP download timeout:** The initContainer downloads AVP at startup. If it hangs, check network access to GitHub releases.
- **KCL plugin race condition:** The `KCL_CACHE_PATH=/tmp` fix prevents double-execution conflicts when ArgoCD runs `kcl run` twice simultaneously.
- **repo-server patch must match:** The sidecar images, volume mounts, and env refs in `patch-argocd-repo-server.yaml` must be consistent with `argocd_values.yml` AVP version.
- **Auto-sync enables selfHeal:** Applications auto-heal and prune. Never edit manifests directly in-cluster — always push to git.
- **`make flow` is destructive for new clusters:** It runs the full kubernetes provisioning pipeline. For existing clusters, use individual steps.
