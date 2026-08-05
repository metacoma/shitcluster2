#!/bin/sh
set -eu

API_URL="${SPACESHIP_API_URL}"
API_KEY="${SPACESHIP_API_KEY}"
API_SECRET="${SPACESHIP_API_SECRET}"
DOMAIN="${SPACESHIP_DOMAIN}"
BIND_NS="${BIND_NS}"
BIND_TSIG_KEY="${BIND_TSIG_KEY}"
BIND_TSIG_KEY_NAME="${BIND_TSIG_KEY_NAME:-cert_manager_key}"
BIND_ZONE="${BIND_ZONE:-mansion.metacoma.org}"

get_public_ip() {
  for url in \
    https://ident.me \
    https://ifconfig.es \
    https://ip.tyk.nu \
    https://api.seeip.org \
    https://eth0.me \
    https://api64.ipify.org; do
    ip=$(curl -sL --max-time 5 --connect-timeout 3 "$url" 2>/dev/null | tr -d '[:space:]')
    if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
      echo "$ip"
      return 0
    fi
  done
  echo "ERROR: failed to detect public IP" >&2
  return 1
}

spaceship_list() {
  curl -s --request GET \
       --url "${API_URL}/${DOMAIN}?take=100&skip=0" \
       --header "X-API-Key: ${API_KEY}" \
       --header "X-API-Secret: ${API_SECRET}"
}

spaceship_delete_record() {
  payload=$(printf '[
    {
      "type": "%s",
      "name": "%s",
      "address": "%s"
    }
  ]' "$1" "$2" "$3")

  curl -s --request DELETE \
       --url "${API_URL}/${DOMAIN}" \
       --header "X-API-Key: ${API_KEY}" \
       --header "X-API-Secret: ${API_SECRET}" \
       --header "content-type: application/json" \
       --data "$payload"
}

spaceship_add_a_record() {
  payload=$(printf '{
    "force": true,
    "items": [
      {
        "type": "%s",
        "name": "%s",
        "ttl": 300,
        "address": "%s"
      }
    ]
  }' "$1" "$2" "$3")

  curl -s --request PUT \
       --url "${API_URL}/${DOMAIN}" \
       --header "X-API-Key: ${API_KEY}" \
       --header "X-API-Secret: ${API_SECRET}" \
       --header "content-type: application/json" \
       --data "$payload"
}

spaceship_delete_ns_record() {
  payload=$(printf '[
    {
      "type": "%s",
      "name": "%s",
      "nameserver": "%s"
    }
  ]' "$1" "$2" "$3")

  curl -s --request DELETE \
       --url "${API_URL}/${DOMAIN}" \
       --header "X-API-Key: ${API_KEY}" \
       --header "X-API-Secret: ${API_SECRET}" \
       --header "content-type: application/json" \
       --data "$payload"
}

spaceship_add_ns_record() {
  payload=$(printf '{
    "force": true,
    "items": [
      {
        "type": "%s",
        "name": "%s",
        "ttl": 600,
        "nameserver": "%s"
      }
    ]
  }' "$1" "$2" "$3")

  curl -s --request PUT \
       --url "${API_URL}/${DOMAIN}" \
       --header "X-API-Key: ${API_KEY}" \
       --header "X-API-Secret: ${API_SECRET}" \
       --header "content-type: application/json" \
       --data "$payload"
}

filter_records() {
  jq -r --arg name "$1" --arg type "$2" '
    .items[]
    | select(.name == $name and .type == $type)
    | .address // .cname // .nameserver
  '
}

ip2sslip() {
  local ip="$1"
  echo "ns-${ip//./-}.sslip.io"
}

update_a_record() {
  local record_type="$1"
  local record_name="$2"
  local new_ip="$3"

  local records
  records=$(spaceship_list | filter_records "$record_name" "$record_type")

  for old_addr in $records; do
    echo "Removing old A record: ${record_name} => ${old_addr}"
    spaceship_delete_record "$record_type" "$record_name" "$old_addr"
  done

  echo "Adding A record: ${record_name} => ${new_ip}"
  spaceship_add_a_record "$record_type" "$record_name" "$new_ip"
}

update_ns_record() {
  local record_name="$1"
  local new_ip="$2"

  local old_ns
  old_ns=$(spaceship_list | filter_records "$record_name" "NS")

  for old_ns_addr in $old_ns; do
    echo "Removing old NS record: ${record_name} => ${old_ns_addr}"
    spaceship_delete_ns_record "NS" "$record_name" "$old_ns_addr"
  done

  local sslip
  sslip=$(ip2sslip "$new_ip")
  echo "Adding NS record: ${record_name} => ${sslip}"
  spaceship_add_ns_record "NS" "$record_name" "$sslip"
}

bind_nsupdate() {
  local ip="$1"
  local keyfile
  keyfile=$(mktemp)

  # Write TSIG key file for nsupdate
  cat > "${keyfile}" <<EOF
key "${BIND_TSIG_KEY_NAME}" {
  algorithm hmac-sha256;
  secret "${BIND_TSIG_KEY}";
};
EOF
  chmod 600 "${keyfile}"

  echo "Updating BIND ext view: ${BIND_ZONE} A => ${ip}"
  nsupdate -v -k "${keyfile}" <<EOF
server ${BIND_NS}
zone ${BIND_ZONE}.
update delete ${BIND_ZONE}. A
update add ${BIND_ZONE}. 300 A ${ip}
update delete *.${BIND_ZONE}. A
update add *.${BIND_ZONE}. 300 A ${ip}
send
EOF

  rm -f "${keyfile}"
}

PUBLIC_IP=$(get_public_ip)
echo "Public IP: ${PUBLIC_IP}"

update_a_record "A" "mansion" "${PUBLIC_IP}"
update_a_record "A" "mansion.net" "${PUBLIC_IP}"
update_ns_record "mansion" "${PUBLIC_IP}"

bind_nsupdate "${PUBLIC_IP}"

echo "DNS records updated successfully"
