# shitcluster — Deployment Guide

Full cluster deployment from scratch using Makefile targets.

## Prerequisites

- SSH access to all cluster nodes (mcmp2–mcmp9, mcmp5 excluded)
- `ansible`, `kubectl`, `helm` available on the management machine
- `.env` file with required variables (see below)

## Environment Variables

Copy `.env.sample` to `.env` and fill in the values:

```bash
cp .env.sample .env
```

### Required variables

| Variable | Description | When needed |
|----------|-------------|-------------|
| `KUBECTL_VERSION` | kubectl docker image version | All kubectl commands |
| `HELM_VERSION` | helm docker image version | All helm commands |
| `ARGOCD_HELM_CHART_VERSION` | ArgoCD Helm chart version | `make argocd` |
| `ARGOCD_TIMEOUT` | ArgoCD install timeout | `make argocd` |
| `ARGOCD_NS` | ArgoCD namespace | All ArgoCD commands |
| `VAULT_NS` | Vault namespace | All Vault commands |
| `VAULT_BOOTSTRAP_CONFIGMAP` | Vault bootstrap secret name | All Vault commands |
| `LONGHORN_NS` | Longhorn namespace | All Longhorn commands |
| `VAULT_ADDR` | Vault HTTP address | `argocd_prepare`, `sops_to_vault` |
| `SOPS_AGE_KEY_FILE` | Path to age private key | `sops_to_vault` |
| `SOPS_PUBLIC_KEY` | Age public key for SOPS | `argocd_prepare` |
| `SOPS_AGE_SECRET_KEY` | Age secret key for SOPS | `argocd_prepare` |

> **Note:** `SOPS_PUBLIC_KEY` and `SOPS_AGE_SECRET_KEY` are only needed for `make argocd_prepare`. They are passed as ansible variables, not stored in Vault.

## Deployment Flow

### Step 1: Reset cluster nodes

```bash
make kubernetes_reset
```

Cleans all nodes from previous Kubernetes installations via Kubespray reset playbook.

**Verification:**
```bash
# No kubelet should be running
systemctl status kubelet  # should fail or be inactive
# No CNI plugins
ls /opt/cni/bin/  # should be empty or minimal
```

---

### Step 2: Install Kubernetes (Kubespray)

```bash
make -C ansible kubespray
```

Installs Kubernetes cluster using Kubespray. This includes:
- Network configuration (netplan)
- Cloud-init network disable
- Storage mounts
- Multipath configuration
- Kubernetes control plane and workers
- Calico CNI
- Macvlan DHCP server
- Longhorn storage network NAD

**Verification:**
```bash
# Get kubeconfig
make update_kubeconfig

# Check nodes
kubectl get nodes
# Expected: 7 nodes (mcmp2-mcmp9, excluding mcmp5)

# Check system pods
kubectl get pods -A --field-selector=status.phase!=Running
# Expected: no pods in non-Running state (except init containers)
```

---

### Step 3: Install Longhorn

```bash
make longhorn
```

Installs Longhorn storage in the correct order:
1. Node preparation (apt packages, iSCSI)
2. Whereabouts CNI + Longhorn SAN NAD
3. Longhorn Helm chart
4. BackupTarget CRD

**Verification:**
```bash
# Check Longhorn pods
kubectl get pods -n longhorn-system
# Expected: all pods Running and Ready

# Check storage class
kubectl get sc
# Expected: longhorn storage class present

# Check NAD
kubectl get network-attachment-definitions -n longhorn-system
# Expected: longhorn-san NAD present

# Check Whereabouts
kubectl get pods -n kube-system -l app=whereabouts
# Expected: whereabouts daemonset running on all nodes
```

---

### Step 4: Install Vault

```bash
make vault
```

Installs and initializes HashiCorp Vault:
1. Clones vault-helm chart
2. Installs via Helm
3. Waits for initialization
4. Extracts root token and unseal key
5. Creates `vault-bootstrap` secret

**Verification:**
```bash
# Check Vault pods
kubectl get pods -n vault
# Expected: vault-0 and vault-agent-injector Running

# Check Vault status
kubectl exec -n vault vault-0 -- vault status
# Expected: Sealed: false, Initialized: true

# Check bootstrap secret
kubectl -n vault get secret vault-bootstrap
# Expected: secret exists with root_token and unseal_key
```

---

### Step 5: Import SOPS secrets into Vault

```bash
make sops_to_vault
```

Decrypts `secrets/vault_data.sops.yaml` using SOPS + age and imports all secrets into Vault KV v2.

**Prerequisites:**
- `SOPS_AGE_KEY_FILE` points to valid age key
- `sops` CLI installed (`/usr/local/bin/sops`)
- Vault is running and unsealed

**Verification:**
```bash
# Check Vault secrets
export VAULT_ADDR=http://172.25.1.4:8200
export VAULT_TOKEN=$(kubectl -n vault get secret vault-bootstrap -o jsonpath='{.data.root_token}' | base64 -d)

vault kv get -mount=kv grafana
vault kv get -mount=kv nats
vault kv get -mount=kv sops/gitops
# Expected: all secrets present with correct keys
```

---

### Step 6: Prepare Vault for ArgoCD

```bash
make argocd_prepare
```

Sets up Vault for ArgoCD:
1. Creates `argocd` namespace
2. Enables KV v2 secrets engine
3. Writes test secret
4. Writes SOPS/Age keys to `kv/sops/gitops`
5. Creates `argocd-vals` policy
6. Creates Vault token for ArgoCD
7. Creates K8s secrets: `argocd-vault-credentials` and `argocd-vault-plugin-credentials`

**Prerequisites:**
- `SOPS_PUBLIC_KEY` and `SOPS_AGE_SECRET_KEY` set in `.env`
- Vault is running and unsealed

**Verification:**
```bash
# Check K8s secrets
kubectl get secrets -n argocd | grep vault
# Expected: argocd-vault-credentials and argocd-vault-plugin-credentials

# Check Vault policy
vault policy list
# Expected: argocd-vals policy present

# Check test secret
vault kv get -mount=kv argocd-test
# Expected: message=hello-from-vault
```

---

### Step 7: Install ArgoCD

```bash
make argocd
```

Installs ArgoCD:
1. Creates `cmp-plugin` configmap (AVP)
2. Installs ArgoCD via Helm
3. Applies KCL CMP plugin config
4. Patches repo-server deployment
5. Restarts repo-server
6. Waits for repo-server to be ready

**Verification:**
```bash
# Check ArgoCD pods
kubectl get pods -n argocd
# Expected: all pods Running and Ready

# Check KCL plugin
kubectl -n argocd logs deploy/argocd-repo-server -c my-plugin --tail=5
# Expected: "serving on /home/argocd/cmp-server/plugins/kcl-v1.0.sock"

# Check AVP plugin
kubectl -n argocd logs deploy/argocd-repo-server -c avp --tail=5
# Expected: no fatal errors
```

---

### Step 8: Create ArgoCD Applications

```bash
make argocd_infra_app
make argocd_workloads_app
```

Creates ArgoCD Application resources for infrastructure and workloads. Each command:
1. Applies the Application JSON
2. Enables auto-sync (prune + self-heal)
3. Triggers hard refresh

**Verification:**
```bash
# Check applications
kubectl get applications -n argocd
# Expected: infra and workloads present

# Check sync status
kubectl get application infra -n argocd -o jsonpath='{.status.sync.status} / {.status.health.status}'
kubectl get application workloads -n argocd -o jsonpath='{.status.sync.status} / {.status.health.status}'
# Expected: Synced / Healthy (may show OutOfSync for operator-managed resources)
```

---

### Step 9: Wait for synchronization

```bash
make argocd_wait_infra
make argocd_wait_workloads
```

Polls ArgoCD applications until they reach `Synced / Healthy` state.

**Verification:**
```bash
# Check all applications
kubectl get applications -n argocd
# Expected: all applications Synced and Healthy

# Check nested applications (workloads contains nested apps)
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
```

---

## Full deployment in one command

```bash
make flow
```

Runs all steps in order:
1. `kubernetes` (reset + install)
2. `update_kubeconfig`
3. `longhorn`
4. `vault`
5. `sops_to_vault`
6. `argocd_prepare`
7. `argocd`
8. `argocd_infra_app`
9. `argocd_workloads_app`

## Troubleshooting

### ArgoCD application stuck in Unknown

```bash
# Force refresh
kubectl -n argocd annotate application <name> argocd.argoproj.io/refresh=hard --overwrite

# Check repo-server logs for plugin errors
kubectl -n argocd logs deploy/argocd-repo-server --tail=50 | grep -i error
```

### Helm repo update fails (DNS)

```bash
# Fix DNS on all nodes
make -C ansible ansible_run ANSIBLE_ARGS="-vv --become --become-user=root fix_dns.yml"
```

### SOPS decryption fails

```bash
# Check sops config format
cat .sops.yaml
# age key must be a string, not an array

# Test decryption manually
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops --decrypt secrets/vault_data.sops.yaml
```

### Longhorn pods pending

```bash
# Check node taints and tolerations
kubectl describe pod -n longhorn-system <pod-name>

# Check storage nodes
kubectl get nodes -l node-role.kubernetes.io/worker=
```

## Known issues

| Issue | Status | Workaround |
|-------|--------|------------|
| `ssh-tunnel` pod pending (node selector) | Open | Add toleration for control-plane taint |
| Tekton CRDs OutOfSync in infra | Expected | Operator-managed resources |
| knative-eventing namespace OutOfSync | Expected | Created by knative-operator |
