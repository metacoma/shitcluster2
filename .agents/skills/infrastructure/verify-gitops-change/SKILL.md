---
name: verify-gitops-change
description: Monitor and verify that a specific ArgoCD application has successfully synced to a target git revision and reached a Healthy state, reporting any issues found during the process without modifying resources.
---

# GitOps Change Verification Skill

This skill provides a standardized procedure for verifying that changes committed to Git have been successfully applied to the cluster by ArgoCD. It ensures that the application is not only "Synced" but also "Healthy", and captures any warnings generated during the process.

## Constraints
- **NO MODIFICATIONS**: You are strictly forbidden from modifying any resource state, triggering manual syncs (unless explicitly asked), or attempting to fix errors found.
- **OBSERVATION ONLY**: Your role is to observe and report.

## Verification Workflow

### 1. Establish Target Revision
First, determine the exact commit hash that should be deployed.
```bash
git rev-parse origin/<branch_name> # usually master
```

### 2. Monitor Sync Progress
Poll the ArgoCD Application status until the revision in the cluster matches the target revision. Use `timeout` for all shell commands to prevent hanging.

**Command:**
```bash
timeout <seconds> kubectl get application <app-name> -n argocd -o json
```

**Success Criteria for Sync:**
- `status.sync.revision` == Target Commit Hash.
- `status.sync.status` == `"Synced"`.

### 3. Verify Health Status
Once synced, verify that the application's health status is optimal.

**Success Criteria for Health:**
- `status.health.status` == `"Healthy"`.

### 4. Collect Warnings and Errors
Inspect the `status.conditions` array in the Application manifest. Look for:
- `RepeatedResourceWarning`: Indicates duplicate resources defined in KCL/YAML.
- Any condition where `type` suggests a failure or warning.

### 5. Final Reporting
Generate a report with the following structure:

**Deployment Verification Report**
- **Application**: `<app-name>`
- **Target Revision**: `<hash>`
- **Actual Revision**: `<hash>`
- **Sync Status**: `Synced` / `OutOfSync`
- **Health Status**: `Healthy` / `Degraded` / `Progressing`
- **Warnings/Errors**: 
  - [ ] None
  - [ ] `<Warning Type>: <Message>`

## Example Polling Loop (Bash)
To avoid excessive API calls, use a loop with a sleep interval:
```bash
timeout 300s bash -c 'until [ "$(kubectl get application <app-name> -n argocd -o jsonpath="{.status.sync.revision}")" == "<target_hash>" ]; do echo "Waiting for sync..."; sleep 15; done'
```
