# vless_server

Ansible role for the **Xray VLESS + XHTTP + REALITY** server that backs the
shitcluster anti-filter tunnel. It is the server-side peer of the in-cluster
client in `gitops/workloads/apps/vless_tunnel.k` (sing-box). The cluster dials
`vless_reality_public_address:443`; this role owns what answers on the other end.

This is an **edge** role: its hosts are not part of the Kubernetes cluster. It
runs from `ansible/edge/inventory.yml` (group `vless_servers`, host `vpn-nl` →
`vpn.nl-ams.net.metacoma.org`, Ubuntu 24.04.2 x86_64), not `ansible/inventory.yml`.

## Why it exists

The endpoint originally came up by hand. On 2026-10-22 an `unattended-upgrades`
reboot (`vpn_nl`) killed it — there was no systemd unit, no package, nothing to
bring it back, and ~21k routed prefixes fell over. This role makes the server
reproducible and self-healing (`Restart=always`), and pins the version so a
silent upgrade can't break the client handshake again.

## Quickstart

Prereq: a working Vault token (the make target pulls it from `vault-bootstrap`).

```bash
# Always from the REPOSITORY ROOT (see "CWD trap" below).
make -C ansible ansible_edge_run ANSIBLE_ARGS="--check"   # dry run, NO --diff
make -C ansible ansible_edge_run                          # converge + verify
```

Direct equivalent:

```bash
VAULT_ADDR=http://172.25.1.4:8200 \
VAULT_TOKEN="$(kubectl -n vault get secret vault-bootstrap \
  -o jsonpath='{.data.root_token}' | base64 -d)" \
ANSIBLE_ROLES_PATH=ansible/roles \
ansible/.venv/bin/ansible-playbook -i ansible/edge/inventory.yml \
  ansible/edge/vless_server.yml --check
```

`ANSIBLE_ROLES_PATH=ansible/roles` is required because the playbook lives in
`ansible/edge/` but the role is in `ansible/roles/` (Ansible only auto-searches
`<playbook_dir>/roles`). The `ansible_edge_run` make target sets it for you.

Tags: `preflight,install,config,service,harden,verify` (plus `always`).
`--check` runs `xray -test` and the decoy probe (both read-only as the `xray`
user). Do **not** pass `--diff` — the `config.json` diff contains the REALITY
private key.

## Where the secrets live

Nothing sensitive is in this repo or in `inventory*`/`group_vars`. Only Vault
*paths* are stored (see `ansible/edge/inventory.yml`). The role reads them at run
time with `community.hashi_vault.vault_kv2_get`, `no_log: true`:

| Needed for | Vault path | Field |
|---|---|---|
| REALITY server private key | `kv/vless_tunnel_server` | `reality_private_key` |
| VLESS client id | `kv/vless_tunnel` | `uuid` |
| REALITY short id | `kv/vless_tunnel` | `reality_short_id` |
| ssh into the edge host | `kv/vpn_nl` | `ssh_private_key_base64` |

Source of truth is `secrets/vault_data.sops.yaml` (sections `vault_data.vless_tunnel_server`
and `vault_data.vless_tunnel`); it is imported into Vault with `make sops_to_vault`.
The server keeps a copy at `/root/vless_server.env` (0600) — that file is the
manual-install leftover; the role is authoritative and does not read it.

Least-privilege: the Vault policy `edge-deploy` grants `read` only on
`kv/data/vless_tunnel_server`, `kv/data/vless_tunnel`, `kv/data/vpn_nl`. Mint a
token against it instead of root for CI:

```bash
vault policy read edge-deploy            # inspect
vault token create -policy=edge-deploy   # narrow token
```

## Rotation (REALITY key pair)

The order matters — REALITY is bound to a single key pair, so a downtime window
is unavoidable. Do it exactly in this sequence:

1. Generate a pair **on the server**: `xray x25519` (note: output line is
   `Password (PublicKey):`, that is the *public* key).
2. In `secrets/vault_data.sops.yaml`, update `vless_tunnel_server.reality_private_key`
   **and** `vless_tunnel.reality_public_key` (+ `reality_short_id` if changed).
   Re-encrypt: `sops -e -i secrets/vault_data.sops.yaml`. Branch → PR → squash merge.
3. `make sops_to_vault`.
4. `make -C ansible ansible_edge_run` — re-renders `config.json`, restarts Xray.
5. Bump `config_revision` in `gitops/workloads/config.k` by +1 → PR → ArgoCD
   rolls the client pod so it picks up the new public key + short id.

Client (`reality_public_key`/`reality_short_id`) and server (`reality_private_key`)
must always be the same pair. Rotating only one side breaks the tunnel.

## Rollback

The client is GitOps-managed; roll it back with `git revert` on the `config.k` /
`vless_tunnel.k` commit → ArgoCD. For the server, revert the SOPS/Vault key to the
previous pair and re-run this role. The manual env backup from the 2026-10-22
recovery is `/root/vless_server.env.bak-20261022` (do not rely on it long-term —
migrate and retire it).

## Pitfalls (all learned the hard way)

- **`--diff` leaks the private key.** The `config.json` template diff prints it.
  Use `--check` without `--diff`. Never paste the diff into a PR/tracker.
- **Never run `xray -test` as root.** Xray opens the access log during validation;
  a root run creates `/var/log/xray/access.log` as `root:root 0600` and the service
  (which runs as `xray`) then crash-loops with `status=23`. `verify.yml` runs the
  test as the `xray` user for exactly this reason.
- **CWD matters.** Run edge playbooks from the repository root. From `ansible/`,
  `host_group_vars` searches `ansible/group_vars` and dumps 63 kubespray variables
  (`calico_*`, `kube_vip_*`, `metallb_*`, `ntp_*`, `crio_*`) onto the VPS. From the
  root it gets 11, all edge-only. The `ansible_edge_run` target `cd ..` for you.
- **No `unzip` on the host.** Ubuntu 24.04 base ships `python3` but not `unzip`, so
  `install.yml` extracts the release with `python3 -m zipfile -e`. Don't "fix" this
  back to `unarchive`/`unzip`.
- **Use `get_url`, not `get_uri`.** The controller venv ships `ansible-core` with
  `get_uri` absent (`module get_uri was not found` at resolution). `get_url`
  downloads on the target (its own Python 3.12) and verifies `sha256` the same way.
- **Version pin is load-bearing.** Keep `xray_version < v26.9.8`. `preflight.yml`
  hard-fails at/above `xray_incompatible_min` (default `v26.9.8`) because Xray
  `>= v26.9.8` only accepts the hybrid PQ key share, and the pinned client
  (`sing-box-lx 1.14.0-lx.26`) still sends classic X25519. Full matrix in
  `vars/main.yml`. Only set `xray_skip_version_gate=true` if you have also bumped
  the client image past `v1.14.0-lx.36`.
- **Changing client-visible values re-renders the client ConfigMap.** Editing
  `kv/vless_tunnel` in Vault (or `config.k`) makes ArgoCD roll the `vless-tunnel`
  pod. Coordinate with the rotation procedure; never hand-edit one side.
