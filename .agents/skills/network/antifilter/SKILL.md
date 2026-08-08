---
name: antifilter
description: Diagnose and fix sites that do not open due to Russian traffic filtering by routing them through the anti-filter tunnel (BIRD static pins → BGP → nl0 SSH tunnel → vpn_nl). Use when a website is blocked, returns Cloudflare 403 "Attention Required", or is intermittently unreachable from the mansion network.
---

# antifilter

This skill describes how to diagnose why a site does not open from the mansion network and add it to the anti-filter routing so its traffic egresses via the European tunnel (Amsterdam) instead of the filtered Russian uplink.

## Background: how the anti-filter tunnel works

```
[site prefix] → BGP table on router (via 172.25.220.2)? → tunnel (nl0 → vpn_nl → 172.233.47.9, Amsterdam)
              → otherwise → default → pppoe-wan (RU ISP, 80.85.151.129)
```

- **BIRD pod** (`network` ns, `bird-b49d78848-*`, IP 172.24.0.19) holds static pins + imports the full anti-filter BGP table (~16.8k routes) from 45.154.73.71 (AS 65432).
- Routes are exported to the OpenWRT router (Quagga, 172.24.0.1, AS 64513) which installs them with nexthop **172.25.220.2** (the `nl0` tunnel pod on br-public).
- Config lives in Git: `gitops/workloads/apps/bird_data/bird.conf` (embedded in a ConfigMap by `gitops/workloads/apps/bird.k`), deployed via ArgoCD `workloads` app.

### Known coverage gaps (Cloudflare)
Cloudflare proxied sites resolve to IPs in ranges that are **only pointwise covered**:

- NOT covered as a whole: `172.67.0.0/16`, `172.66.x`, `104.20.x`, `104.21.x` (only via `discord` static `104.16.0.0/12`), `188.114.x`
- Covered statically: chatgpt, spaceship.dev, opentofu, terraform, goodreads, etc.

This is intentional (avoid flooding the TCP-based SSH tunnel). Add specific pins, not whole Cloudflare ranges.

## When to use

- A site returns Cloudflare 403 "Attention Required" / blank challenge page from home.
- A site is blocked by RU ISP (TSPU) and unreachable over the main uplink.
- A site is intermittently broken: **different resolvers return Cloudflare IPs in different order**, and only some of them are routed via the tunnel.

## Diagnosis steps

### 1. Resolve the site

```bash
dig +short <site> A          # e.g. pi.dev → 104.21.62.67, 172.67.221.13
dig +short <site> NS         # if darl/melody.ns.cloudflare.com → it is Cloudflare-proxied
```

Also query several resolvers (1.1.1.1, 8.8.8.8, 9.9.9.9) — order differs per resolver, so pin **all** returned IPs.

### 2. Confirm the site is behind Cloudflare

```bash
for ip in $(dig +short <site> A); do whois "$ip" 2>/dev/null | grep -i netname; done
# expect: CLOUDFLARENET
```

### 3. Check routing on the router

Get credentials: `sops -d secrets/vault_data.sops.yaml` → `vault_data.openwrt_router` (ssh_host 172.25.0.1, user root, password).

```bash
sshpass -p "$PASS" ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
  -o StrictHostKeyChecking=no root@172.25.0.1 \
  'ip route get <ip1>; ip route get <ip2>'
```

Interpretation:
- `via 172.25.220.2 dev br-PUBLIC` → already in anti-filter tunnel ✅
- `via 109.195.26.254 dev pppoe-wan` / default → **goes through RU uplink** ❌ (this is the filter problem)

### 4. Verify the failure (optional)

```bash
curl -sS --max-time 15 --resolve <site>:443:<problem-ip> -D - -o /dev/null https://<site>/
# expect HTTP 403 / Attention Required, cf-ray ending in a RU/other region
```

## Fix: add a static pin in BIRD

### 1. Edit `gitops/workloads/apps/bird_data/bird.conf`

Add a block following the existing convention (tabs, comment explaining the reason), e.g. for pi.dev:

```
# pi.dev: 172.67.221.13 is blocked by Cloudflare (HTTP 403) from the main RU
# IP; route it via the anti-filter tunnel instead.
protocol static pi_dev {
	ipv4;
	route 104.21.62.67/32 via 172.25.220.2;
	route 172.67.221.13/32 via 172.25.220.2;
}
```

Rules:
- `/32` for single IPs, `/24` for ranges (like `chatgpt`). Do NOT add `172.67.0.0/16` etc. wholesale.
- Pin **every** A record the site currently returns. Re-check DNS before committing — Cloudflare IPs rotate.
- Protocol name: short, descriptive (`<domain_with_underscores>`).

### 2. Validate syntax

Local Docker may be unavailable (we run inside a pod), so use the running BIRD pod:

```bash
POD=$(kubectl -n network get pod -l app=bird -o jsonpath='{.items[0].metadata.name}')
kubectl -n network cp gitops/workloads/apps/bird_data/bird.conf $POD:/tmp/bird.conf -c bird
kubectl -n network exec $POD -c bird -- bird -p -c /tmp/bird.conf   # exit 0 = OK
```

### 3. Commit and open a PR

Local `git push` has no credentials for `github.com/metacoma/shitcluster2` — use the GitHub MCP tools instead:

```bash
git checkout -b fix/<site>-antifilter origin/master
git add gitops/workloads/apps/bird_data/bird.conf
git commit -m "fix: route <site> via anti-filter tunnel (Cloudflare 403 from RU IP)"
```

1. `create_branch` (`fix/<site>-antifilter`, base master)
2. `get_file_contents` for `gitops/workloads/apps/bird_data/bird.conf` on master → note its `sha`
3. `create_or_update_file` with the full new content, `sha` from step 2, branch from step 1
4. `create_pull_request` (base `master`, head `fix/<site>-antifilter`)
5. `merge_pull_request` with `merge_method: squash`
6. Clean up local branch: `git checkout <orig-branch> && git branch -D fix/<site>-antifilter`

### 4. Wait for ArgoCD sync and reload BIRD

ArgoCD auto-syncs the `workloads` app (~1-3 min). Check/force:

```bash
export ARGOCD_OPTS='--grpc-web'
ARGOCD_SERVER=$(kubectl -n argocd get svc argocd-server -o jsonpath='{.spec.clusterIP}')
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
echo y | argocd login "$ARGOCD_SERVER:80" --username admin --password "$ARGOCD_PASS" --insecure --grpc-web
argocd app get workloads --server "$ARGOCD_SERVER:80"   # expect: Synced to master (<sha>), Healthy
```

⚠️ **ConfigMap updates do NOT restart the BIRD pod.** Reload the running process:

```bash
kubectl -n network exec $POD -c bird -- birdc -s /run/bird/bird.ctl configure
# expect: "Reconfigured"
kubectl -n network exec $POD -c bird -- birdc -s /run/bird/bird.ctl show protocols all <name>
# expect: Routes: N imported, N preferred
```

## Verification

### 1. Router sees the route via the tunnel

```bash
sshpass -p "$PASS" ssh ... root@172.25.0.1 'ip route get <ip>'
# expect: via 172.25.220.2 dev br-PUBLIC
```

### 2. Site opens over every pinned IP

```bash
curl -sS --max-time 15 -o /dev/null -w "HTTP %{http_code} | %{remote_ip}\n" https://<site>/
for ip in <ip1> <ip2>; do
  curl -sS --max-time 15 --resolve <site>:443:$ip -o /dev/null -w "HTTP %{http_code} | %{remote_ip}\n" https://<site>/
done
# expect: HTTP 200 for all; cf-ray header ends in -AMS (Amsterdam exit)
```

Confirm egress region:

```bash
curl -sS --max-time 15 --resolve <site>:443:<ip> -D - -o /dev/null https://<site>/ | grep -i cf-ray
# e.g. cf-ray: a28171ebafaefb7d-AMS
```

## Gotchas

- **Multiple A records**: pin ALL of them. Resolver order varies; a browser can hit the unpinned IP first and fail.
- **Cloudflare IPs rotate**: after some weeks re-run `dig +short <site> A`; add any new IPs to the same protocol block.
- **Do not add whole Cloudflare ranges**: keep pins specific to keep tunnel load sane (TCP-based SSH tunnel, UDP-sensitive).
- **`birdc configure` vs pod restart**: configure reloads the config from the mounted file in-place; deleting the pod also works but is heavier.
- **BGP propagation is fast** once BIRD is reconfigured; the router installs routes immediately via zebra.
- **IPv6**: the tunnel stack is IPv4-only; if a site only has AAAA records, you may need to force IPv4 or pin A records.
