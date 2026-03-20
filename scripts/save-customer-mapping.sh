#!/usr/bin/env bash
# Save a user-learned customer mapping to the cache.
# This is called after the user answers a "which customer?" prompt,
# so future runs auto-match the same source.
#
# Usage: ./save-customer-mapping.sh --key "repo:my-repo" --customer "CustomerName"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_FILE="$REPO_ROOT/worklogs/.customer-cache.json"

MAPPING_KEY=""
CUSTOMER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) MAPPING_KEY="$2"; shift 2 ;;
    --customer) CUSTOMER="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$MAPPING_KEY" || -z "$CUSTOMER" ]]; then
  echo "ERROR: --key and --customer are required" >&2
  exit 1
fi

if [[ ! -f "$CACHE_FILE" ]]; then
  echo "ERROR: Cache file not found at $CACHE_FILE — run build-customer-cache.sh first" >&2
  exit 1
fi

# Update the user_mappings in the cache
UPDATED=$(jq --arg key "$MAPPING_KEY" --arg customer "$CUSTOMER" \
  '.user_mappings[$key] = $customer' "$CACHE_FILE")

echo "$UPDATED" > "$CACHE_FILE"
echo "Saved: $MAPPING_KEY → $CUSTOMER" >&2
