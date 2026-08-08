---
name: forgejo-repo
description: Create a new repository on the self-hosted Forgejo instance (forgejo.mansion.metacoma.org) via the REST API. Covers auth, the correct token scopes, the create-repo payload, and verification.
---

# Forgejo Repository Creation Skill

Create a repository on the self-hosted Forgejo instance as the `forgejo_admin` user.

## Facts (verified 2026-02-16)

- Instance: `https://forgejo.mansion.metacoma.org` (in-cluster, Ingress via `mansion-net-tls`)
- Admin user: `forgejo_admin` (password in Vault: `kv/forgejo#admin_password`, file `secrets/vault_data.sops.yaml`)
- Forgejo version: **15.0.6+gitea-1.22.0**
- Existing repos: `forgejo_admin/shitcluster` (public), `forgejo_admin/rnd-service` (private, created via this skill)
- **API gotcha #1**: the create-token response returns the raw token in the **`sha1`** field, NOT `token`
- **API gotcha #2**: creating a repo requires token scopes **`write:repository` + `write:user`**. With only `write:repository` you get `403 {"message":"token does not have at least one of required scope(s): [write:user]"}`
- **API gotcha #3**: token names must be unique — a stale token with the same name returns `400 {"message":"access token name has been used already"}`
- **API gotcha #4**: deleting a token with the token itself returns 403; use basic auth (username + password) to delete

## 1. Get admin password

```bash
cd /home/ubuntu/shitcluster/repo
FJ_PASS=$(sops -d secrets/vault_data.sops.yaml 2>/dev/null | python3 -c "import yaml,sys; print(yaml.safe_load(sys.stdin)['vault_data']['forgejo']['admin_password'])")
```

## 2. Create a repository (recommended)

```bash
cd /home/ubuntu/shitcluster/repo
python3 - "$FJ_PASS" <<'EOF'
import json, urllib.request, urllib.error, base64, yaml, subprocess, sys

PASS = sys.argv[1]
USER = 'forgejo_admin'
BASE = 'https://forgejo.mansion.metacoma.org/api/v1'

def req(method, path, body=None, token=None, password=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'token ' + token
    elif password:
        headers['Authorization'] = 'Basic ' + base64.b64encode(f'{USER}:{password}'.encode()).decode()
    r = urllib.request.Request(BASE + path, data=json.dumps(body).encode() if body else None, method=method, headers=headers)
    try:
        with urllib.request.urlopen(r, timeout=20) as resp:
            raw = resp.read().decode()
            return resp.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {'raw': raw[:200]}

# 1) clean up stale tokens with our bot name (unique-name requirement)
status, tokens = req('GET', f'/users/{USER}/tokens', password=PASS)
for t in (tokens or []):
    if t['name'] == 'repo-create-bot':
        req('DELETE', f"/users/{USER}/tokens/{t['id']}", password=PASS)
        print('deleted stale token', t['id'])

# 2) create token — REQUIRED scopes: write:repository + write:user
status, tok = req('POST', f'/users/{USER}/tokens',
                  {'name': 'repo-create-bot', 'scopes': ['write:repository', 'write:user']}, password=PASS)
if status != 201:
    print('token create failed:', status, tok); raise SystemExit(1)
TOKEN = tok['sha1']   # raw token is in 'sha1' on this Forgejo version
print('token created')

# 3) create the repo
REPO_NAME = 'rnd-service'          # <-- change me
body = {
    'name': REPO_NAME,
    'description': 'Описание репозитория',
    'private': True,               # or False for public
    'auto_init': False,            # True to create README/LICENSE/.gitignore
    'default_branch': 'main',
}
status, repo = req('POST', '/user/repos', body, token=TOKEN)
print('create repo status:', status)
if status == 201:
    print('repo:', repo['full_name'], '| url:', repo['html_url'],
          '| private:', repo['private'], '| default_branch:', repo['default_branch'])
else:
    print('error:', repo)

# 4) delete the token (hygiene)
status, _ = req('DELETE', f'/users/{USER}/tokens/repo-create-bot', password=PASS)
print('token deleted:', status)
EOF
```

## 3. Alternative: create repo under an organization

Same flow, but POST to `/orgs/{org}/repos` instead of `/user/repos`:

```python
# instead of req('POST', '/user/repos', ...):
status, repo = req('POST', f'/orgs/{ORG_NAME}/repos', body, token=TOKEN)
```

## 4. Verify

```bash
# check existence / get details
curl -s -H "Authorization: token $TOKEN" \
  "https://forgejo.mansion.metacoma.org/api/v1/repos/forgejo_admin/rnd-service" | python3 -m json.tool
# or simply open: https://forgejo.mansion.metacoma.org/forgejo_admin/rnd-service
```

## 5. Clone the new repo

Requires a token with `write:repository` (HTTPS password auth is disabled):

```bash
git clone "https://forgejo_admin:${TOKEN}@forgejo.mansion.metacoma.org/forgejo_admin/rnd-service.git"
```

## Pitfalls

1. **`403 token does not have at least one of required scope(s): [write:user]`** — the create-repo endpoint requires `write:user` scope in addition to `write:repository`. Include both.
2. **Raw token location**: this Forgejo version returns the token in `sha1` on token creation; the `token` key may be absent. Token listing returns hashes only (`sha_last_eight`), so save the raw token immediately or delete+recreate.
3. **`400 access token name has been used already`** — token names are unique per user. Delete stale tokens with the same name first (list via `GET /users/{user}/tokens`, delete by id).
4. **Token deletion 403** — deleting a token authenticated with the token itself fails; always use basic auth (username:password).
5. **`auto_init: False`** creates an empty repo with no default branch objects — `git clone` warns about an empty repo but works. Set `auto_init: True` (and optionally `readme`, `license`, `gitignores`) to pre-initialize.
6. **Private by default**: set `private: False` explicitly for a public repo.
7. The repo is created under the authenticated user (`forgejo_admin`); for orgs use `POST /orgs/{org}/repos`.
