---
name: kcl-validate
description: Validate, compile, and format KCL (Kubernetes Configuration Language) manifests using a Docker container matching the ArgoCD environment. Use when you need to ensure KCL files are syntactically correct before committing them to Git.
---

# KCL Validation Skill

This skill provides instructions for validating, compiling, and formatting KCL (Kubernetes Configuration Language) manifests using a Docker container that matches the environment used by ArgoCD in the shitcluster.

## Purpose

Ensure that KCL manifests are syntactically correct and compile successfully before they are committed to Git and synced by ArgoCD. This prevents "Sync Failed" errors in ArgoCD due to KCL compilation errors.

## Tooling

- **Docker Image**: `ghcr.io/metacoma/kcl-vals:latest`
- **KCL Version**: 0.11.2 (as of current image)

## Procedures

### 1. Validate and Compile Manifests

To check if a KCL module compiles and to see the resulting YAML output, run the following command from the root of the repository:

```bash
docker run --rm -v $(pwd)/<module_path>:/app -w /app ghcr.io/metacoma/kcl-vals:latest kcl run .
```

Replace `<module_path>` with the path to the KCL module you are working on (e.g., `gitops/workloads` or `gitops/infra`).

**Expected Result**: The command should output a stream of Kubernetes YAML manifests if successful, or an error message indicating the line and cause of the failure.

### 2. Format KCL Files

To ensure consistent formatting across the repository:

```bash
docker run --rm -v $(pwd)/<module_path>:/app -w /app ghcr.io/metacoma/kcl-vals:latest kcl fmt .
```

This will format all `.k` files within the specified module directory.

## Best Practices

- Run `kcl run` after every change to a `.k` file before committing.
- Use `kcl fmt` to maintain clean and consistent code style.
- If you encounter dependency errors, ensure that the `kcl.mod` file is present in the module directory.
