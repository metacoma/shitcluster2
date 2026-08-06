#!/bin/sh
# =============================================================================
# spaceship_dns_update.sh
#
# Updates the mansion.metacoma.org delegation (see issue #3, DNS-01 debug):
#   1. Spaceship API (parent zone metacoma.org):
#        A  mansion        -> <public_ip>
#        A  mansion.net    -> <public_ip>
#        NS mansion        -> ns-<public_ip: dots -> dashes>.sslip.io
#   2. BIND ext view: A + wildcard for mansion.metacoma.org (RFC2136/nsupdate)
#
# Fail-safe: on ANY API error (Cloudflare 403, invalid JSON, timeout,
# HTTP != 2xx) records are NOT modified — log the reason and exit with a
# non-zero code (CronJob will see Failed). Order: ADD (PUT) first, DELETE stale
# records only AFTER success — so a broken API never leaves an NXDOMAIN window.
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Error handling (fail-fast) — right at the start
# -----------------------------------------------------------------------------
set -eu

# Enable pipefail where supported (bash/ksh/busybox ash).
# dash does not have it, so all curl calls below capture output directly
# (no pipelines) — an error cannot be masked by the exit status of the last
# pipeline command.
if (set -o pipefail) 2>/dev/null; then
  set -o pipefail
fi

# Required environment variables: fail immediately with a clear message.
# (Do not wait until curl/jq fails on an empty/garbage variable.)
: "${SPACESHIP_API_URL:?SPACESHIP_API_URL is not set}"
: "${SPACESHIP_API_KEY:?SPACESHIP_API_KEY is not set}"
: "${SPACESHIP_API_SECRET:?SPACESHIP_API_SECRET is not set}"
: "${SPACESHIP_DOMAIN:?SPACESHIP_DOMAIN is not set}"
: "${BIND_NS:?BIND_NS is not set}"
: "${BIND_TSIG_KEY:?BIND_TSIG_KEY is not set}"

# Remapping (as in the original) — shorter internal names
API_URL="${SPACESHIP_API_URL}"
API_KEY="${SPACESHIP_API_KEY}"
API_SECRET="${SPACESHIP_API_SECRET}"
DOMAIN="${SPACESHIP_DOMAIN}"

# Optional parameters (defaults)
BIND_TSIG_KEY_NAME="${BIND_TSIG_KEY_NAME:-cert_manager_key}"
BIND_ZONE="${BIND_ZONE:-mansion.metacoma.org}"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Temp files — guaranteed cleanup on any exit (EXIT/INT/TERM)
TMP=""
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT INT TERM
TMP=$(mktemp -d) || die "не удалось создать временный каталог"
BODY="$TMP/body.json"   # последний ответ API
LIST="$TMP/list.json"   # последний успешный GET /records
KEY="$TMP/tsig.key"     # TSIG-ключ для nsupdate

# -----------------------------------------------------------------------------
# 2. Spaceship API HTTP layer
# -----------------------------------------------------------------------------

# Single curl call: --show-error, timeouts, 3 retries on transient failures
# (5xx/429/timeout; 403 is NOT retried — it is a deterministic block).
# Output: HTTP code on stdout, response body in $BODY.
# Instead of --fail we check the code explicitly (check_http) — this keeps the
# 403 page body and gives precise diagnostics (Cloudflare vs API).
api_request() {
  local method="$1" payload="${2:-}"
  local url code rc

  if [ "$method" = "GET" ]; then
    url="${API_URL}/${DOMAIN}?take=100&skip=0"
  else
    url="${API_URL}/${DOMAIN}"
  fi

  # set +e around curl: capture rc ourselves (in dash $? after if without else = 0)
  set +e
  if [ -n "$payload" ]; then
    code=$(curl -sS --show-error \
        --max-time 20 --connect-timeout 5 \
        --retry 3 --retry-delay 2 \
        --request "$method" --url "$url" \
        --header "X-API-Key: ${API_KEY}" \
        --header "X-API-Secret: ${API_SECRET}" \
        --header "content-type: application/json" \
        --data "$payload" \
        --write-out '%{http_code}' \
        --output "$BODY")
  else
    code=$(curl -sS --show-error \
        --max-time 20 --connect-timeout 5 \
        --retry 3 --retry-delay 2 \
        --request "$method" --url "$url" \
        --header "X-API-Key: ${API_KEY}" \
        --header "X-API-Secret: ${API_SECRET}" \
        --write-out '%{http_code}' \
        --output "$BODY")
  fi
  rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    die "curl ${method} ${url} failed (rc=${rc}): $(head -c 200 "$BODY" 2>/dev/null | tr '\n' ' ')"
  fi

  printf '%s' "$code"
}

# Any non-2xx = fatal; 403 (Cloudflare) gets a dedicated message.
# Called BEFORE any modification — records are untouched.
check_http() {
  local code="$1" what="$2"
  case "$code" in
    2*) return 0 ;;
    403)
      die "Cloudflare блокирует запрос (HTTP 403) для ${what}. Вероятно, основной IP в бан-листе. Записи НЕ тронуты."
      ;;
    *)
      die "HTTP ${code} от API (${what}). Записи НЕ тронуты. Ответ: $(head -c 200 "$BODY" 2>/dev/null | tr '\n' ' ')"
      ;;
  esac
}

# JSON validation (jq -e): a Cloudflare page/empty response != valid JSON
require_json() {
  local what="$1"
  if ! jq -e . "$BODY" >/dev/null 2>&1; then
    die "${what}: API вернул не-JSON: $(head -c 200 "$BODY" 2>/dev/null | tr '\n' ' ')"
  fi
}

spaceship_list() {
  local code
  code=$(api_request GET)
  check_http "$code" "GET records"
  require_json "GET records"
  cp "$BODY" "$LIST"
}

spaceship_put() {
  local payload="$1" what="$2" code
  code=$(api_request PUT "$payload")
  check_http "$code" "PUT ${what}"
  if [ -s "$BODY" ]; then
    require_json "PUT ${what}"
  fi
}

spaceship_delete() {
  local payload="$1" what="$2" code
  code=$(api_request DELETE "$payload")
  check_http "$code" "DELETE ${what}"
  if [ -s "$BODY" ]; then
    require_json "DELETE ${what}"
  fi
}

# -----------------------------------------------------------------------------
# 3. Business logic
# -----------------------------------------------------------------------------

get_public_ip() {
  local url ip
  for url in \
    https://ident.me \
    https://ifconfig.es \
    https://ip.tyk.nu \
    https://api.seeip.org \
    https://eth0.me \
    https://api64.ipify.org; do
    if ip=$(curl -fsSL --max-time 5 --connect-timeout 3 "$url" 2>/dev/null); then
      ip=$(printf '%s' "$ip" | tr -d '[:space:]')
      # strictly: response must be ONLY an IPv4 — no HTML/Cloudflare pages
      if printf '%s' "$ip" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
        # and octets in the 0–255 range
        if awk -v ip="$ip" 'BEGIN{split(ip,o,"\\."); ok=(o[1]<=255 && o[2]<=255 && o[3]<=255 && o[4]<=255); exit !ok}'; then
          echo "$ip"
          return 0
        fi
      fi
      # stdout is reserved for the result (echo "$ip" below) — diagnostics to stderr only
      printf 'WARN: пропускаем %s: ответ не является IPv4 (%s)\n' "$url" "$ip" >&2
    else
      printf 'WARN: пропускаем %s: недоступен\n' "$url" >&2
    fi
  done
  die "не удалось определить публичный IPv4"
}

ip2sslip() {
  local ip="$1" dashed
  dashed=$(printf '%s' "$ip" | tr '.' '-')
  echo "ns-${dashed}.sslip.io"
}

filter_records() {
  local name="$1" type="$2"
  jq -r --arg name "$name" --arg type "$type" '
    .items[]
    | select(.name == $name and .type == $type)
    | .address // .cname // .nameserver
  ' "$LIST"
}

# Payload builders (Spaceship API format preserved)
a_payload() {       # (type name value) -> A/AAAA
  printf '{"force":true,"items":[{"type":"%s","name":"%s","ttl":300,"address":"%s"}]}' "$1" "$2" "$3"
}
ns_payload() {      # (name nameserver)
  printf '{"force":true,"items":[{"type":"NS","name":"%s","ttl":600,"nameserver":"%s"}]}' "$1" "$2"
}
delete_a_payload() {  # (type name address)
  printf '[{"type":"%s","name":"%s","address":"%s"}]' "$1" "$2" "$3"
}
delete_ns_payload() { # (name nameserver)
  printf '[{"type":"NS","name":"%s","nameserver":"%s"}]' "$1" "$2"
}

# ADD-before-DELETE: first PUT the new value (idempotent, force:true);
# on failure — die BEFORE deleting old ones. Only stale values that differ
# from the target are deleted (an up-to-date record is not recreated).
update_a_record() {
  local record_type="$1" record_name="$2" new_ip="$3"
  local records old_addr payload

  spaceship_list
  records=$(filter_records "$record_name" "$record_type")

  log "UPSERT ${record_type} ${record_name} -> ${new_ip}"
  payload=$(a_payload "$record_type" "$record_name" "$new_ip")
  spaceship_put "$payload" "${record_type} ${record_name}"

  for old_addr in $records; do
    if [ "$old_addr" != "$new_ip" ]; then
      log "DELETE stale ${record_type} ${record_name} = ${old_addr}"
      payload=$(delete_a_payload "$record_type" "$record_name" "$old_addr")
      spaceship_delete "$payload" "${record_type} ${record_name}=${old_addr}"
    fi
  done
}

update_ns_record() {
  local record_name="$1" new_ip="$2"
  local sslip old_ns old_ns_addr payload

  sslip=$(ip2sslip "$new_ip")
  spaceship_list
  old_ns=$(filter_records "$record_name" "NS")

  log "UPSERT NS ${record_name} -> ${sslip}"
  payload=$(ns_payload "$record_name" "$sslip")
  spaceship_put "$payload" "NS ${record_name}"

  for old_ns_addr in $old_ns; do
    if [ "$old_ns_addr" != "$sslip" ]; then
      log "DELETE stale NS ${record_name} = ${old_ns_addr}"
      payload=$(delete_ns_payload "$record_name" "$old_ns_addr")
      spaceship_delete "$payload" "NS ${record_name}=${old_ns_addr}"
    fi
  done
}

bind_nsupdate() {
  local ip="$1"

  cat > "$KEY" <<EOF
key "${BIND_TSIG_KEY_NAME}" {
  algorithm hmac-sha256;
  secret "${BIND_TSIG_KEY}";
};
EOF
  chmod 600 "$KEY"

  log "BIND: обновление ext-view ${BIND_ZONE} (A + wildcard -> ${ip})"
  if nsupdate -v -k "$KEY" <<EOF
server ${BIND_NS}
zone ${BIND_ZONE}.
update delete ${BIND_ZONE}. A
update add ${BIND_ZONE}. 300 A ${ip}
update delete *.${BIND_ZONE}. A
update add *.${BIND_ZONE}. 300 A ${ip}
send
EOF
  then
    log "BIND: nsupdate OK"
  else
    die "nsupdate завершился с ошибкой для зоны ${BIND_ZONE}"
  fi
}

# -----------------------------------------------------------------------------
# 4. Main flow
# -----------------------------------------------------------------------------
log "=== spaceship-dns-updater: старт ==="

PUBLIC_IP=$(get_public_ip)
log "Public IP: ${PUBLIC_IP}"

# Fail-safe: before any change, make sure the API is alive (2xx + valid JSON).
# 403/non-JSON here = immediate exit, records untouched.
log "API probe: GET ${API_URL}/${DOMAIN} ..."
spaceship_list
log "API OK — начинаем обновление"

update_a_record "A" "mansion" "${PUBLIC_IP}"
update_a_record "A" "mansion.net" "${PUBLIC_IP}"
update_ns_record "mansion" "${PUBLIC_IP}"

bind_nsupdate "${PUBLIC_IP}"

log "DNS records updated successfully"
