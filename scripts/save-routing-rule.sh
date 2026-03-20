#!/usr/bin/env bash
# Save a routing rule that maps a source pattern to a fixed Jira key + customer.
# Routing rules take priority over customer matching — entries that match a rule
# get both a customer AND a pre-assigned Jira key (skipping ticket creation).
#
# Usage: ./save-routing-rule.sh --pattern "calendar:internal" --jira-key "APRO-7" --customer "Apró"
#        ./save-routing-rule.sh --pattern "slack:internal" --jira-key "APRO-7" --customer "Apró"
#        ./save-routing-rule.sh --list
#        ./save-routing-rule.sh --delete "calendar:internal"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_FILE="$REPO_ROOT/worklogs/.customer-cache.json"

if [[ ! -f "$CACHE_FILE" ]]; then
  echo "ERROR: Cache file not found at $CACHE_FILE — run build-customer-cache.sh first" >&2
  exit 1
fi

PATTERN=""
JIRA_KEY=""
CUSTOMER=""
LIST=false
DELETE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pattern) PATTERN="$2"; shift 2 ;;
    --jira-key) JIRA_KEY="$2"; shift 2 ;;
    --customer) CUSTOMER="$2"; shift 2 ;;
    --list) LIST=true; shift ;;
    --delete) DELETE="$2"; shift 2 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# List mode
if [[ "$LIST" == "true" ]]; then
  jq -r '.routing_rules // {} | to_entries[] | "\(.key) → \(.value.jira_key) (\(.value.customer))"' "$CACHE_FILE"
  exit 0
fi

# Delete mode
if [[ -n "$DELETE" ]]; then
  UPDATED=$(jq --arg pattern "$DELETE" 'del(.routing_rules[$pattern])' "$CACHE_FILE")
  echo "$UPDATED" > "$CACHE_FILE"
  echo "Deleted routing rule: $DELETE" >&2
  exit 0
fi

# Add mode — validate required fields
if [[ -z "$PATTERN" || -z "$JIRA_KEY" || -z "$CUSTOMER" ]]; then
  echo "ERROR: --pattern, --jira-key, and --customer are all required" >&2
  echo "Usage: $0 --pattern \"calendar:internal\" --jira-key \"APRO-7\" --customer \"Apró\"" >&2
  exit 1
fi

# Ensure routing_rules exists and add the rule
UPDATED=$(jq \
  --arg pattern "$PATTERN" \
  --arg jira_key "$JIRA_KEY" \
  --arg customer "$CUSTOMER" \
  '.routing_rules //= {} | .routing_rules[$pattern] = {jira_key: $jira_key, customer: $customer}' \
  "$CACHE_FILE")

echo "$UPDATED" > "$CACHE_FILE"
echo "Saved routing rule: $PATTERN → $JIRA_KEY ($CUSTOMER)" >&2
