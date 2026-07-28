# AGENTS.md

## Purpose

This file contains instructions for local coding agents working in the `shitcluster2` repository. It is designed to provide essential context regarding the repository structure, development workflow, and validation procedures to ensure consistent and safe contributions.

## Repository overview

`shitcluster2` is a GitOps project for managing a Kubernetes cluster. It employs a layered approach to infrastructure and application management:
- **Base Infrastructure**: Automated via Ansible (using Kubespray for Kubernetes, alongside network and storage setup).
- **Cluster Services**: Orchestrated via a root `Makefile` using Helm and Terraform/OpenTofu (e.g., Vault, ArgoCD, Longhorn).
- **Continuous Delivery**: Managed by ArgoCD.
- **Configuration Management**: Uses KCL (Kubernetes Configuration Language) to define both infrastructure (`gitops/infra`) and workloads (`gitops/workloads`), as well as tmux session configurations (`tmux/`).
- **Secret Management**: Secrets are encrypted using SOPS.

## Repository map

```text
ansible/                - Base infrastructure automation (Kubespray, network, storage).
ansible/group_vars/     - Ansible group variables.
ansible/host_vars/      - Ansible host-specific variables.
gitops/                - KCL-based GitOps configurations.
gitops/infra/          - Infrastructure definitions (KCL modules).
gitops/workloads/      - Application definitions (KCL modules).
gitops/workloads/apps/ - Source KCL files for individual applications.
tmux/                  - KCL definitions for generating tmux session configurations.
tmux/sessions/         - Individual tmux session definitions in KCL.
secrets/               - Encrypted secrets managed with SOPS.
vault-data/            - HashiCorp Vault configuration (Terraform/OpenTofu).
misc/                  - General utility scripts (e.g., Calico fixes).
Makefile               - Top-level orchestration for bootstrapping the cluster and services.
main.k                 - Root KCL entrypoint, primarily for rendering tmux sessions.
LLM_REPO_MAP.md        - Detailed map and guide for LLM agents.
```

## Development workflow

### KCL Changes
1. **Analyze Patterns**: Inspect existing patterns in `gitops/workloads/apps/` or `tmux/`.
2. **Schema Adherence**: Follow established schemas, particularly those in `tmux/schema.k`.
3. **Minimal Edits**: Modify the smallest possible source files (e.g., `gitops/workloads/config.k` or specific app `.k` files).
4. **Avoid Manual Manifest Edits**: Do not edit generated YAML manifests directly; always modify the KCL source.

### Ansible Changes
1. **Linting**: Run `make -C ansible ansible_lint` to verify playbook syntax and style.
2. **Testing**: Use `make -C ansible ansible_ping` to verify connectivity to nodes.

### General Workflow
1. **Context First**: Read `AGENTS.md` and `LLM_REPO_MAP.md`.
2. **Verification**: Run `git diff --check` before committing.
3. **Minimalism**: Prioritize minimal, focused changes over broad refactorings.

## Validation and build commands

### Cluster Orchestration (via root Makefile)
- `make kubernetes`: Full cluster setup including reset and installation via Ansible.
- `make vault`: Installs and initializes HashiCorp Vault.
- `make argocd`: Installs and configures ArgoCD.
- `make longhorn`: Installs Longhorn storage.

### Ansible Validation
- `make -C ansible ansible_lint`: Lints Ansible playbooks.
- `make -C ansible ansible_ping`: Pings Kubernetes nodes.

### KCL Tooling (if installed)
- **Validate Infrastructure**: Navigate to `gitops/infra` and run `kcl run .`
- **Validate Workloads**: Navigate to `gitops/workloads` and run `kcl run .`
- `kcl fmt .`: Formats KCL files in the current directory.
- `kcl run .`: Executes KCL to validate and generate output.

## Safety rules

### Files to avoid editing manually
- `kcl.mod.lock`: Automatically generated lock files.
- `gitops/infra/tekton-pipelines.yml`: Treated as a template/partially generated.
- Any file explicitly marked as `generated` or `managed by` an external process.

### Infrastructure Safety
- **Cluster Access**: Changing KCL infrastructure files may impact the live cluster via ArgoCD. Verify changes against the current cluster state before applying.
- **Secrets**: Do not commit plaintext secrets. Use SOPS for encrypting files in the `secrets/` directory.
- **Privileged Operations**: Be cautious with `make kubernetes` or `make kubernetes_reset` as these can destroy existing cluster states.

## Contribution conventions

### Git Conventions
- **Branching**: Create descriptive feature branches (e.g., `feat/add-rabbitmq-config`).
- **Commits**: Focus on atomic commits.
- **Verification**: Always run `git diff --check` and review the diff carefully before finalizing changes.

### KCL Conventions
- **Modularity**: Place new application definitions in `gitops/workloads/apps/` as separate `.k` files.
- **Configuration**: Centralize shared configurations in `gitops/workloads/config.k` where appropriate.
