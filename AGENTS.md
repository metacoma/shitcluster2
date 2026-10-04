<!-- bmad:context -->
<!-- Verified 2026-10-04 against 3d10d4fc3a50f1865ab00c71c19772fc28bc8ef7. Managed by bmad-project-context; edits inside this block are replaced on refresh. Keep anything you want preserved outside the markers. -->

## shitcluster

GitOps repo for a homelab Kubernetes cluster: Ansible (Kubespray) for base infra, KCL for manifest generation, ArgoCD for delivery, SOPS+age and Vault for secrets. Full pipeline: `make flow`; deep deployment guide in `README.md`. KCL changes reach the live cluster via ArgoCD auto-sync — verify against cluster state before committing.

## Policy

- Never commit plaintext secrets — SOPS-encrypt under `secrets/*.sops.yaml` only. Never commit or print `.env` contents.
- Never hand-edit `kcl.mod.lock` (auto-generated) or `gitops/infra/tekton-pipelines.yml` (vendored 26k-line upstream Tekton manifest — `tekton.k` reads it at render time and injects nodeSelectors; hand edits are futile).
- Never edit files marked `generated` or `managed by`.
- Never run `make kubernetes_reset` without explicit user confirmation — it destroys cluster state.
- Branches `type/short-description` (feat, fix, chore, docs); conventional commits; atomic commits; squash merge on PR; `git diff --check` before committing.
- Playbooks target mcmp2–mcmp9; mcmp5 is excluded (hardware issue, temporary — recheck on refresh).

## Where things are

- Required `.env` variables and prerequisites: `README.md` (copy from `.env.sample`).
- Adding an app: create `gitops/workloads/apps/<name>.k` exporting `manifests` → add secrets under `vault_data.<name>` in `secrets/vault_data.sops.yaml` → add config section in `gitops/workloads/config.k` → import in `main.k` → `kcl run .` to validate.
- All namespaces, chart versions, and Vault refs live in the single dict in `gitops/workloads/config.k`.
- Nested Helm apps: use local lambda helpers (`monitoring_app` in `apps/monitoring.k`, `istio_app` in `apps/istio.k`); complex data configs go in subdirs (`apps/vector_data/parsers/*.lua`).
- `gitops/infra/` is flat (no `apps/`): `tekton.k`, `vault_unseal.k`, `mcp_namespace.k`.
- ArgoCD Application JSONs in `argocd/`: `infra` and `workloads` are active; `argocd-vault` and `raw-argocd-vault` are dormant (`raw` unused/retired; both source dirs absent from repo, no apply targets). Auto-sync+selfHeal is in the JSONs; prune/allowEmpty exist only in `kubectl patch` inside Makefile targets.

## Running and verifying

- Validate/render KCL before committing: use the `kcl-validate` skill (Docker env matching the ArgoCD CMP) for `gitops/workloads` and `gitops/infra`.
- `make kubernetes` installs only and does NOT reset — reset is a separate destructive `make kubernetes_reset`.
- Order matters: kubernetes → update_kubeconfig → longhorn → vault → vault-unseal → sops_to_vault (Vault must be running and unsealed) → argocd_prepare (needs SOPS keys) → argocd. `make flow` runs the install-only sequence; wait with `argocd_wait_infra` / `argocd_wait_workloads`.
- Ad-hoc playbooks: `make -C ansible ansible_run ANSIBLE_ARGS="..."`. The venv activation does not carry into the playbook recipe line — `ansible-playbook` resolves from PATH; `ansible_lint` uses the system binary, not `ansible/.venv`.
- Git push/pull auth: `scripts/git-sops-credential` decrypts the GitHub token from SOPS on the fly. New clone: `git config --global credential.helper "$PWD/scripts/git-sops-credential"` (absolute path required), or use GitHub MCP tools.

## Conventions that differ from defaults

- Vault refs `ref+vault://kv/<path>#<key>` resolve via `vals eval` at manifest render time in the ArgoCD repo-server, not at pod runtime; rendered values never land in Git.
- SOPS→Vault import: top-level keys become Vault paths (`strip_prefix=vault_data`), nested dicts become sub-paths. New secrets: edit `secrets/vault_data.sops.yaml`, encrypt with `sops`, `make sops_to_vault`.
- App files in `apps/` export `manifests`, but the directory also holds data subdirs and helper scripts — not every file is a manifest.
- The AVP sidecar exists in argocd-repo-server but is unused; all secret resolution goes through vals.

## Known pitfalls

- `scripts/git-sops-credential` fails silently: if sops fails (missing age key at `~/.config/sops/age/keys.txt`), git just sees "no credentials" — no error surfaces.
- A trailing `+` in a vals ref is an expression terminator for inline interpolation, not base64 — decoding is `?decode=base64`.
- `.sops.yaml` age recipient must be a string, not an array.
- Tekton CRDs and the knative-eventing namespace stay permanently OutOfSync in ArgoCD — expected, operator-managed.

<!-- /bmad:context -->
