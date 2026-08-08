---
name: forgejo-wiki
description: Create or update a wiki page in the shitcluster repository on Forgejo (forgejo.mansion.metacoma.org) via the REST API or git. Covers auth, the correct API payload format (content_base64), token creation for git, and verification.
---

# Forgejo Wiki Skill

Add a wiki article to the `forgejo_admin/shitcluster` repository on the self-hosted Forgejo instance.

## Facts (verified 2026-02-16)

- Instance: `https://forgejo.mansion.metacoma.org` (in-cluster, Ingress via `mansion-net-tls`)
- Repo: `forgejo_admin/shitcluster` (public)
- Admin user: `forgejo_admin` (password in Vault: `kv/forgejo#admin_password`, file `secrets/vault_data.sops.yaml`)
- Forgejo version: **15.0.6+gitea-1.22.0**
- Wiki is a lazy-initialized git repo: `https://forgejo.mansion.metacoma.org/forgejo_admin/shitcluster.wiki.git`
- **API gotcha**: this Forgejo version expects `title` + `content_base64` in `POST /wiki/new` (NOT `page_name` + `content` — that returns `400 {"message":"%!s(<nil>)"}`)
- **Git auth gotcha**: password auth over HTTPS is disabled for git; you must create a scoped token via the API
- Existing wiki pages: `mansion_network` (сеть/туннели/роутинг), issue #3 (DNS-01 debug)

## 1. Get admin password

```bash
cd /home/ubuntu/shitcluster/repo
FJ_PASS=$(sops -d secrets/vault_data.sops.yaml 2>/dev/null | python3 -c "import yaml,sys; print(yaml.safe_load(sys.stdin)['vault_data']['forgejo']['admin_password'])")
```

## 2. Create a wiki page via API (recommended)

```bash
cd /home/ubuntu/shitcluster/repo
# 1) create a token (raw token is returned ONLY in the create response)
TOKEN=$(python3 - "$FJ_PASS" <<'EOF'
import json, urllib.request, base64, os, sys
PASS = sys.argv[1]
req = urllib.request.Request(
    'https://forgejo.mansion.metacoma.org/api/v1/users/forgejo_admin/tokens',
    data=json.dumps({'name': 'wiki-bot', 'scopes': ['write:repository']}).encode(),
    method='POST',
    headers={'Content-Type': 'application/json',
             'Authorization': 'Basic ' + base64.b64encode(f'forgejo_admin:{PASS}'.encode()).decode()}
)
print(json.load(urllib.request.urlopen(req, timeout=15)).get('token'))
EOF
)

# 2) create the wiki page (title + content_base64!)
python3 - "$TOKEN" <<'EOF'
import json, urllib.request, base64, sys
TOKEN = sys.argv[1]
content = open('/tmp/WIKI_FILE.md', encoding='utf-8').read()   # source markdown
data = {
    'title': 'page-slug',                     # URL slug (e.g. mansion_network)
    'content_base64': base64.b64encode(content.encode()).decode(),
    'message': 'Добавлена вики-статья: <описание>'
}
req = urllib.request.Request(
    'https://forgejo.mansion.metacoma.org/api/v1/repos/forgejo_admin/shitcluster/wiki/new',
    data=json.dumps(data).encode(), method='POST',
    headers={'Content-Type': 'application/json', 'Authorization': 'token ' + TOKEN}
)
resp = urllib.request.urlopen(req, timeout=60)
print(json.load(resp))
EOF

# 3) delete the token (hygiene)
python3 - "$FJ_PASS" <<'EOF'
import urllib.request, base64, sys
PASS = sys.argv[1]
req = urllib.request.Request(
    'https://forgejo.mansion.metacoma.org/api/v1/users/forgejo_admin/tokens/<TOKEN_ID>',
    method='DELETE',
    headers={'Authorization': 'Basic ' + base64.b64encode(f'forgejo_admin:{PASS}'.encode()).decode()}
)
print('deleted:', urllib.request.urlopen(req, timeout=15).status)
EOF
```

## 3. Alternative: create wiki page via git

For bulk operations or when the API misbehaves, push to the wiki git repo directly:

```bash
cd /home/ubuntu/shitcluster/repo
FJ_PASS=$(sops -d secrets/vault_data.sops.yaml 2>/dev/null | python3 -c "import yaml,sys; print(yaml.safe_load(sys.stdin)['vault_data']['forgejo']['admin_password'])")
# create token (see step 2.1), then:
rm -rf /tmp/wiki_clone && git clone "https://forgejo_admin:${TOKEN}@forgejo.mansion.metacoma.org/forgejo_admin/shitcluster.wiki.git" /tmp/wiki_clone
cd /tmp/wiki_clone
cp /tmp/WIKI_FILE.md ./page-slug.md
git add . && git commit -m "Add wiki page: page-slug"
git push origin main   # wiki branch is 'main'
```

Note: the wiki repo is created lazily — the first push/API call initializes it. If `git clone` says "repository does not exist", use the API approach first (or create via UI).

## 4. Verify

```bash
# list wiki pages
curl -s -H "Authorization: token $TOKEN" \
  "https://forgejo.mansion.metacoma.org/api/v1/repos/forgejo_admin/shitcluster/wiki/pages"
# raw content
curl -s -H "Authorization: token $TOKEN" \
  "https://forgejo.mansion.metacoma.org/forgejo_admin/shitcluster/wiki/raw/<slug>"
# or simply: https://forgejo.mansion.metacoma.org/forgejo_admin/shitcluster/wiki/<slug>
```

## Pitfalls

1. **`400 {"message":"%!s(<nil>)"}`** on `POST /wiki/new` — wrong payload fields. This Forgejo version needs `title` + `content_base64` (+ optional `message`). Check the live schema: `https://forgejo.mansion.metacoma.org/swagger.v1.json` → `definitions.CreateWikiPageOptions`.
2. **Git auth**: HTTPS with password fails ("Please make sure you have the correct access rights"). Always create a token via API (`POST /users/{user}/tokens` with scopes `write:repository`).
3. **Token retrieval**: the raw token is returned ONLY in the `201` create response. Listing tokens returns hashes only. If you lose it, delete and recreate with a new name.
4. **Token deletion**: deleting a token using the token itself returns 403; use basic auth (password) to delete.
5. **Wiki repo lazy creation**: `{repo}.wiki.git` may not exist until the first page is created. Toggling `has_wiki` off/on via `PATCH /repos/{owner}/{repo}` does NOT create it.
6. **Wiki default branch is `main`** (unlike the repo's `master`).
7. Issue creation (not wiki) uses the same instance + auth: `POST /api/v1/repos/{owner}/{repo}/issues` with `{"title": ..., "body": ...}`.
