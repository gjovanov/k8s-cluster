#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

# Load .env if CF_Token / CF_Zone_ID not already exported
if [[ -z "${CF_Token:-}" || -z "${CF_Zone_ID:-}" ]]; then
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  else
    echo "ERROR: .env not found at $ENV_FILE and CF_Token/CF_Zone_ID not set" >&2
    exit 1
  fi
fi

: "${CF_Token:?CF_Token is required}"
: "${CF_Zone_ID:?CF_Zone_ID is required}"

API="https://api.cloudflare.com/client/v4/zones/${CF_Zone_ID}/dns_records"

cf_api() {
  local method=$1 url=$2
  shift 2
  curl -s -X "$method" "$url" \
    -H "Authorization: Bearer ${CF_Token}" \
    -H "Content-Type: application/json" \
    "$@"
}

cmd_list() {
  local page=1 per_page=100
  while true; do
    resp=$(cf_api GET "${API}?page=${page}&per_page=${per_page}")
    count=$(echo "$resp" | jq '.result | length')
    echo "$resp" | jq -r '.result[] | [.id, .type, .name, .content, .priority // "", .proxied] | @tsv'
    if (( count < per_page )); then
      break
    fi
    ((page++))
  done
}

cmd_add() {
  local type=$1 name=$2 content=$3 priority=${4:-}

  # Check for existing record
  existing=$(cf_api GET "${API}?type=${type}&name=${name}&content=${content}")
  match_count=$(echo "$existing" | jq '.result | length')

  if (( match_count > 0 )); then
    echo "SKIP: ${type} ${name} → ${content} already exists"
    return 0
  fi

  # Build JSON payload
  local data
  data=$(jq -n \
    --arg type "$type" \
    --arg name "$name" \
    --arg content "$content" \
    '{type: $type, name: $name, content: $content, proxied: false, ttl: 1}')

  # Add priority for MX records
  if [[ -n "$priority" ]]; then
    data=$(echo "$data" | jq --argjson pri "$priority" '. + {priority: $pri}')
  fi

  resp=$(cf_api POST "$API" -d "$data")
  ok=$(echo "$resp" | jq -r '.success')

  if [[ "$ok" == "true" ]]; then
    echo "OK:   ${type} ${name} → ${content}"
  else
    echo "FAIL: ${type} ${name} → ${content}" >&2
    echo "$resp" | jq '.errors' >&2
    return 1
  fi
}

cmd_update() {
  local record_id=$1 json_patch=$2

  resp=$(cf_api PATCH "${API}/${record_id}" -d "$json_patch")
  ok=$(echo "$resp" | jq -r '.success')

  if [[ "$ok" == "true" ]]; then
    echo "UPDATED: ${record_id}"
    echo "$resp" | jq '{name: .result.name, proxied: .result.proxied, content: .result.content}'
  else
    echo "FAIL: could not update ${record_id}" >&2
    echo "$resp" | jq '.errors' >&2
    return 1
  fi
}

cmd_delete() {
  local record_id=$1
  resp=$(cf_api DELETE "${API}/${record_id}")
  ok=$(echo "$resp" | jq -r '.success')

  if [[ "$ok" == "true" ]]; then
    echo "DELETED: ${record_id}"
  else
    echo "FAIL: could not delete ${record_id}" >&2
    echo "$resp" | jq '.errors' >&2
    return 1
  fi
}

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [args...]

Commands:
  list                                    List all DNS records
  add <TYPE> <NAME> <CONTENT> [PRIORITY]  Add a DNS record (idempotent)
  delete <RECORD_ID>                      Delete a DNS record by ID

Examples:
  $(basename "$0") list
  $(basename "$0") add A coturn.roomler.live 94.130.141.98
  $(basename "$0") add MX roomler.live aspmx.l.google.com 1
  $(basename "$0") delete abc123
EOF
}

case "${1:-}" in
  list)   cmd_list ;;
  add)    shift; cmd_add "$@" ;;
  update) shift; cmd_update "$@" ;;
  delete) shift; cmd_delete "$@" ;;
  *)      usage; exit 1 ;;
esac
