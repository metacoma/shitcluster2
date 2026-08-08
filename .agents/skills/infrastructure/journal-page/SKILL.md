---
name: journal-page
description: Create a work log (журнал работ) page in the shitcluster wiki on Forgejo (forgejo.mansion.metacoma.org). Use when the user asks to log completed work, write a summary of a task/deployment into the wiki, or add an entry to the work journal.
---

# Journal Page Skill

Add an entry to the work journal (журнал работ) in the `forgejo_admin/shitcluster` wiki. The journal is a set of flat wiki pages prefixed with `journal-` (e.g. `journal-2026-08-08-mattermost`).

## Facts (verified 2026-08-08)

- Instance: `https://forgejo.mansion.metacoma.org` (in-cluster, Ingress via `mansion-net-tls`)
- Repo: `forgejo_admin/shitcluster` (public)
- Admin user: `forgejo_admin` (password in Vault: `kv/forgejo#admin_password`, file `secrets/vault_data.sops.yaml`)
- Forgejo version: **15.0.6+gitea-1.22.0**
- Wiki git repo: `https://forgejo.mansion.metacoma.org/forgejo_admin/shitcluster.wiki.git` (branch `main`)
- **CRITICAL: wiki pages in subdirectories render as HTTP 500** (both Cyrillic `журнал-работ/` and Latin `journal/`). Journal pages MUST be flat files at the wiki root with the `journal-` prefix.
- **API gotcha**: `POST /wiki/new` with a `title` containing `/` does NOT create a subdir — it creates a junk file `journal%2Ftest-page.-.md` at root. Use git for page creation.
- **Token gotcha**: the raw token is returned in the **`sha1`** field of the create-token response (not `token`). Save it immediately or delete+recreate.
- Git over HTTPS with password is disabled — always use a token.

## 1. Gather the work log context

Before writing, collect (from the conversation/session):

1. **Задача** — the original user request (1-2 sentences).
2. **Что сделано** — files changed, commits/PRs, commands run, current state.
3. **Нюансы и проблемы** — anything that was not obvious: errors hit, root causes, workarounds, gotchas discovered.
4. **Итоговое состояние** — verification results (URLs, statuses, health).
5. **Дальнейшие шаги** — optional follow-ups.

## 2. Prepare the page content

Write the markdown to `/tmp/journal-page.md` using the template below. Page title: `journal-YYYY-MM-DD-<slug>` (e.g. `journal-2026-08-08-mattermost`). Keep the slug short and kebab-case.

```markdown
# Журнал работ: <YYYY-MM-DD> — <Краткое название задачи>

## Задача

<Что просил сделать пользователь, контекст (домашняя лаба, GitOps и т.д.)>

## Что сделано

<Структурировано: файлы, PR/коммиты, команды, шаги>

## Нюансы и проблемы

<Ключевые находки: ошибки, root cause, решения. Важно для будущего.>

## Итоговое состояние

<Проверка: URL, статусы ArgoCD/подов, таблица компонентов>

## Дальнейшие шаги

<Опционально: что осталось>
```

## 3. Publish (single script)

Run from the repo root. The script creates a token (raw value = `sha1`), clones the wiki, adds the page, pushes, deletes the token, and verifies with `curl`.

```bash
# 0) content must exist (write it in step 2)
test -f /tmp/journal-page.md || { echo "write /tmp/journal-page.md first (step 2)"; exit 1; }

TOKEN=$(FJ_PASS=$(sops -d secrets/vault_data.sops.yaml 2>/dev/null | python3 -c "import yaml,sys; print(yaml.safe_load(sys.stdin)['vault_data']['forgejo']['admin_password'])") \
python3 - "$FJ_PASS" <<'EOF'
import json, urllib.request, urllib.error, base64, sys, time
PASS = sys.argv[1]; USER = 'forgejo_admin'; BASE = 'https://forgejo.mansion.metacoma.org/api/v1'
def req(method, path, body=None, token=None, password=None):
    h = {'Content-Type': 'application/json'}
    if token: h['Authorization'] = 'token ' + token
    elif password: h['Authorization'] = 'Basic ' + base64.b64encode(f'{USER}:{password}'.encode()).decode()
    r = urllib.request.Request(BASE+path, data=json.dumps(body).encode() if body else None, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=20) as resp:
            raw = resp.read().decode(); return resp.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try: return e.code, json.loads(raw)
        except Exception: return e.code, {'raw': raw[:200]}
# unique token name
name = 'journal-bot-' + str(int(time.time()))
status, tok = req('POST', f'/users/{USER}/tokens', {'name': name, 'scopes': ['write:repository']}, password=PASS)
if status != 201: print('token failed:', status, tok); raise SystemExit(1)
print(tok['sha1'])
EOF
)

PAGE="journal-$(date +%F)-mattermost"   # <-- edit slug
rm -rf /tmp/wiki_clone
git clone -q "https://forgejo_admin:${TOKEN}@forgejo.mansion.metacoma.org/forgejo_admin/shitcluster.wiki.git" /tmp/wiki_clone
cd /tmp/wiki_clone
git config user.email "forgejo@shitcluster.io"
git config user.name "forgejo_admin"
cp /tmp/journal-page.md "./${PAGE}.md"
git add -A
git commit -m "Журнал работ: ${PAGE}"
git push -q origin main
echo "PUSHED: ${PAGE}"

# 4) verify
curl -s -o /dev/null -w "web: %{http_code}\n" \
  "https://forgejo.mansion.metacoma.org/forgejo_admin/shitcluster/wiki/${PAGE}"

# 5) delete the token (hygiene) — basic auth required
FJ_PASS=$(sops -d secrets/vault_data.sops.yaml 2>/dev/null | python3 -c "import yaml,sys; print(yaml.safe_load(sys.stdin)['vault_data']['forgejo']['admin_password'])")
python3 - "$FJ_PASS" <<'EOF'
import json, urllib.request, urllib.error, base64, sys
PASS = sys.argv[1]; USER = 'forgejo_admin'; BASE = 'https://forgejo.mansion.metacoma.org/api/v1'
AUTH = 'Basic ' + base64.b64encode(f'{USER}:{PASS}'.encode()).decode()
status, tokens = 200, json.load(urllib.request.urlopen(urllib.request.Request(BASE + f'/users/{USER}/tokens', headers={'Authorization': AUTH}), timeout=15))
for t in tokens:
    if t['name'].startswith('journal-bot'):
        r = urllib.request.Request(BASE + f"/users/{USER}/tokens/{t['id']}", method='DELETE', headers={'Authorization': AUTH})
        print(f"deleted {t['name']}:", urllib.request.urlopen(r, timeout=15).status)
EOF
rm -rf /tmp/wiki_clone
```

## 4. Verify

- `curl -o /dev/null -w "%{http_code}" https://forgejo.mansion.metacoma.org/forgejo_admin/shitcluster/wiki/<page>` → **200** means the page renders.
- **500** = the page is in a subdirectory (not allowed — see pitfalls) or a broken name.
- Optionally list wiki pages via API: `GET /api/v1/repos/forgejo_admin/shitcluster/wiki/pages`.

## Pitfalls

1. **NO subdirectories in the wiki** — Forgejo 15.0.6 renders subdir pages as HTTP 500. Always use flat `journal-YYYY-MM-DD-<slug>.md` at the wiki root. Do NOT try `журнал-работ/...` or `journal/...`.
2. **Raw token is in `sha1`** — the create-token response has no `token` key on this version; `sha1` IS the token value. Save it immediately (or delete+recreate).
3. **Token names must be unique** — `400 access token name has been used already`. Name tokens with a timestamp suffix, and clean up stale ones before creating.
4. **Delete tokens with basic auth** — deleting with the token itself returns 403.
5. **Wiki API cannot create folders** — `POST /wiki/new` with a slash in title creates a junk root file (`journal%2Ftest-page.-.md`). Use git for everything.
6. **Git needs a token** — password auth over HTTPS is disabled (`Please make sure you have the correct access rights`).
7. **Wiki default branch is `main`** (not `master`).
8. **Cleanup** — always delete temp tokens and the `/tmp/wiki_clone` directory.
9. Content should be factual and reproducible: include PR numbers, exact commands, root causes. The journal is the operational memory of the lab.
