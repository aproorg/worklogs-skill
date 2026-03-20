#!/usr/bin/env bash
# Resolve a customer name to a Tempo account ID.
# Uses worklogs/.account-mappings.json for cached mappings.
# Falls back to Tempo API fuzzy matching if no mapping exists.
#
# Usage: ./resolve-tempo-account.sh --customer "CustomerName"
#        ./resolve-tempo-account.sh --list                    (list all Tempo accounts)
#        ./resolve-tempo-account.sh --save --customer "Name" --account-id 123
#
# Output: JSON {"account_id": 123, "account_name": "...", "matched": true}
#         or   {"account_id": null, "matched": false, "candidates": [...]}
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
MAPPINGS_FILE="$REPO_ROOT/worklogs/.account-mappings.json"

if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

# Ensure mappings file exists
if [[ ! -f "$MAPPINGS_FILE" ]]; then
  mkdir -p "$(dirname "$MAPPINGS_FILE")"
  echo '{}' > "$MAPPINGS_FILE"
fi

# Parse arguments
CUSTOMER=""
ACCOUNT_ID=""
MODE="resolve"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --customer) CUSTOMER="$2"; shift 2 ;;
    --account-id) ACCOUNT_ID="$2"; shift 2 ;;
    --list) MODE="list"; shift ;;
    --save) MODE="save"; shift ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# List all Tempo accounts
if [[ "$MODE" == "list" ]]; then
  if [[ -z "${TEMPO_TOKEN:-}" ]]; then
    echo "ERROR: TEMPO_TOKEN must be set in .env" >&2
    exit 1
  fi
  curl -s -H "Authorization: Bearer ${TEMPO_TOKEN}" -H "Accept: application/json" \
    "https://api.tempo.io/4/accounts" | jq '[.results[] | select(.status == "OPEN") | {id, key, name}]'
  exit 0
fi

# Save a mapping
if [[ "$MODE" == "save" ]]; then
  if [[ -z "$CUSTOMER" || -z "$ACCOUNT_ID" ]]; then
    echo "ERROR: --customer and --account-id are required for --save" >&2
    exit 1
  fi
  jq --arg customer "$CUSTOMER" --argjson id "$ACCOUNT_ID" \
    '.[$customer] = $id' "$MAPPINGS_FILE" > "${MAPPINGS_FILE}.tmp" \
    && mv "${MAPPINGS_FILE}.tmp" "$MAPPINGS_FILE"
  echo "Saved: $CUSTOMER → account $ACCOUNT_ID" >&2
  jq -n --arg customer "$CUSTOMER" --argjson id "$ACCOUNT_ID" \
    '{customer: $customer, account_id: $id, saved: true}'
  exit 0
fi

# Resolve mode
if [[ -z "$CUSTOMER" ]]; then
  echo "ERROR: --customer is required" >&2
  exit 1
fi

# Check cached mapping first
CACHED_ID=$(jq -r --arg c "$CUSTOMER" '.[$c] // empty' "$MAPPINGS_FILE" 2>/dev/null || true)
if [[ -n "$CACHED_ID" ]]; then
  jq -n --argjson id "$CACHED_ID" --arg customer "$CUSTOMER" \
    '{account_id: $id, account_name: $customer, matched: true, source: "cache"}'
  exit 0
fi

# No cached mapping — try Tempo API fuzzy match
if [[ -z "${TEMPO_TOKEN:-}" ]]; then
  jq -n '{account_id: null, matched: false, reason: "no cached mapping and TEMPO_TOKEN not set"}'
  exit 0
fi

ACCOUNTS=$(curl -s -H "Authorization: Bearer ${TEMPO_TOKEN}" -H "Accept: application/json" \
  "https://api.tempo.io/4/accounts" | jq '[.results[] | select(.status == "OPEN")]')

# Try exact name match (case-insensitive)
MATCH=$(echo "$ACCOUNTS" | jq --arg c "$CUSTOMER" '
  [.[] | select(.name | ascii_downcase | contains($c | ascii_downcase))]
  | if length == 1 then .[0] else null end
')

if [[ "$MATCH" != "null" ]]; then
  MATCH_ID=$(echo "$MATCH" | jq '.id')
  MATCH_NAME=$(echo "$MATCH" | jq -r '.name')
  jq -n --argjson id "$MATCH_ID" --arg name "$MATCH_NAME" --arg customer "$CUSTOMER" \
    '{account_id: $id, account_name: $name, matched: true, source: "tempo_api"}'
  exit 0
fi

# No exact match — return candidates
CANDIDATES=$(echo "$ACCOUNTS" | jq '[.[] | {id, key, name}]')
jq -n --argjson candidates "$CANDIDATES" --arg customer "$CUSTOMER" \
  '{account_id: null, matched: false, customer: $customer, candidates: $candidates}'
