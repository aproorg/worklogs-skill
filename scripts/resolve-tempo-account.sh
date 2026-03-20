#!/usr/bin/env bash
# Resolve a customer name (and optionally a repo) to a Tempo account ID.
# Uses worklogs/.account-mappings.json for cached mappings.
# Repo-based rules take priority over customer-level mappings.
# Falls back to Tempo API fuzzy matching if no mapping exists.
#
# Usage: ./resolve-tempo-account.sh --customer "CustomerName"
#        ./resolve-tempo-account.sh --customer "CustomerName" --repo "repo-name"
#        ./resolve-tempo-account.sh --list                    (list all Tempo accounts)
#        ./resolve-tempo-account.sh --save --customer "Name" --account-id 123
#        ./resolve-tempo-account.sh --save --repo "repo-name" --account-id 123
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
REPO=""
MODE="resolve"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --customer) CUSTOMER="$2"; shift 2 ;;
    --account-id) ACCOUNT_ID="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
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
    "https://api.tempo.io/4/accounts?limit=200" | jq '[.results[] | select(.status == "OPEN") | {id, key, name}]'
  exit 0
fi

# Save a mapping
if [[ "$MODE" == "save" ]]; then
  if [[ -z "$ACCOUNT_ID" ]]; then
    echo "ERROR: --account-id is required for --save" >&2
    exit 1
  fi
  if [[ -n "$REPO" ]]; then
    SAVE_KEY="repo:${REPO}"
  elif [[ -n "$CUSTOMER" ]]; then
    SAVE_KEY="$CUSTOMER"
  else
    echo "ERROR: --customer or --repo is required for --save" >&2
    exit 1
  fi
  jq --arg key "$SAVE_KEY" --argjson id "$ACCOUNT_ID" \
    '.[$key] = $id' "$MAPPINGS_FILE" > "${MAPPINGS_FILE}.tmp" \
    && mv "${MAPPINGS_FILE}.tmp" "$MAPPINGS_FILE"
  echo "Saved: $SAVE_KEY → account $ACCOUNT_ID" >&2
  jq -n --arg key "$SAVE_KEY" --argjson id "$ACCOUNT_ID" \
    '{key: $key, account_id: $id, saved: true}'
  exit 0
fi

# Resolve mode
if [[ -z "$CUSTOMER" && -z "$REPO" ]]; then
  echo "ERROR: --customer or --repo is required" >&2
  exit 1
fi

# Check repo-based mapping first (highest priority)
if [[ -n "$REPO" ]]; then
  REPO_ID=$(jq -r --arg r "repo:${REPO}" '.[$r] // empty' "$MAPPINGS_FILE" 2>/dev/null || true)
  if [[ -n "$REPO_ID" ]]; then
    jq -n --argjson id "$REPO_ID" --arg repo "$REPO" \
      '{account_id: $id, matched: true, source: "repo_mapping", repo: $repo}'
    exit 0
  fi
fi

# Check customer-level cached mapping
if [[ -n "$CUSTOMER" ]]; then
  CACHED_ID=$(jq -r --arg c "$CUSTOMER" '.[$c] // empty' "$MAPPINGS_FILE" 2>/dev/null || true)
  if [[ -n "$CACHED_ID" ]]; then
    jq -n --argjson id "$CACHED_ID" --arg customer "$CUSTOMER" \
      '{account_id: $id, account_name: $customer, matched: true, source: "cache"}'
    exit 0
  fi
fi

# No cached mapping — try Tempo API fuzzy match
if [[ -z "${TEMPO_TOKEN:-}" ]]; then
  jq -n '{account_id: null, matched: false, reason: "no cached mapping and TEMPO_TOKEN not set"}'
  exit 0
fi

ACCOUNTS=$(curl -s -H "Authorization: Bearer ${TEMPO_TOKEN}" -H "Accept: application/json" \
  "https://api.tempo.io/4/accounts?limit=200" | jq '[.results[] | select(.status == "OPEN")]')

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
