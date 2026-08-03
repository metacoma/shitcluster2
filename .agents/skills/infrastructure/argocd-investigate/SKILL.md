---
name: argocd-investigate
description: Provide a systematic approach to debugging ArgoCD applications, investigating deployment failures, and analyzing logs in a cluster using KCL CMP plugins and Vault.
---

# ArgoCD Investigation Skill

This skill provides a systematic approach to debugging ArgoCD applications, investigating deployment failures, and analyzing logs in a cluster using KCL CMP plugins and Vault.

## Overview
In this environment, the manifest pipeline is: 
`Git repo → ArgoCD repo-server → KCL CMP plugin (my-plugin) → vals eval (Vault resolution) → Kubernetes API`.

Failures can occur at any of these stages.

## Investigation Workflow

### 1. Check Application High-Level Status
Start by identifying which applications are problematic.
```bash
kubectl get applications -n argocd
```
Look for:
- `SYNC STATUS`: `OutOfSync` means Git differs from Cluster.
- `HEALTH STATUS`: `Degraded` or `Progressing` indicates a runtime issue with the resources.

### 2. Deep Dive into Application State
Use `kubectl describe` to find specific error messages and sync history.
```bash
kubectl describe application <app-name> -n argocd
```
**Key sections to analyze:**
- **Operation State**: Look for the `Message` field. This is where Kubernetes API errors (e.g., validation errors, RBAC issues) are reported during sync.
- **Resources**: Check which specific resource is failing or `OutOfSync`.
- **Events**: Recent events often explain why a sync failed or was triggered.

### 3. Analyze ArgoCD Component Logs
Depending on where the failure occurs, check different logs:

#### A. Manifest Generation & Secret Resolution (KCL/Vault)
If the application fails to generate manifests or has `vals` resolution errors:
- **KCL Plugin logs**:
  ```bash
  kubectl logs -n argocd deploy/argocd-repo-server -c my-plugin
  ```
- **Main Repo Server logs**:
  ```bash
  kubectl logs -n argocd deploy/argocd-repo-server -c repo-server
  ```
- **AVP logs (if applicable)**:
  ```bash
  kubectl logs -n argocd deploy/argocd-repo-server -c avp
  ```

#### B. Sync Logic & Health Monitoring
If manifests are correct but the application state is `Degraded` or syncs are looping:
```bash
kubectl logs -n argocd deploy/argocd-application-controller
```

#### C. API and UI Issues
For errors related to the ArgoCD API, authentication, or dashboard:
```bash
kubectl logs -n argocd deploy/argocd-server
```

### 4. Debugging the Workload (Runtime)
If ArgoCD reports `Degraded`, investigate the actual Kubernetes resources in the target namespace.

1. **Find failing pods**:
   ```bash
   kubectl get pods -n <app-namespace> | grep -v Running
   ```
2. **Inspect pod events**:
   ```bash
   kubectl describe pod <pod-name> -n <app-namespace>
   ```
3. **Check application logs**:
   ```bash
   kubectl logs -f <pod-name> -n <app-namespace>
   ```

## Troubleshooting Matrix

| Symptom | Likely Cause | Primary Tool/Log |
| :--- | :--- | :--- |
| `OutOfSync` but no errors | Git change not applied or manual cluster edit | `kubectl describe app` |
| Manifest generation error | KCL syntax error / Missing Vault secret | `repo-server` $\rightarrow$ `my-plugin` logs |
| `Degraded` status | Pod CrashLoopBackOff / Health check failure | `kubectl describe pod` |
| Sync "stuck" or looping | Resource conflict / Invalid spec for K8s version | `app-controller` logs / `describe app` |
| Vault resolution failure | Incorrect `ref+vault://` path or token expired | `repo-server` $\rightarrow$ `my-plugin` logs |
