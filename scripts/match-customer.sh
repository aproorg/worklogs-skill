#!/usr/bin/env bash
# Match a worklog entry to a customer using the customer cache.
# Checks routing rules first (which also assign a fixed Jira key),
# then falls back to issue lookup, user mappings, and keyword search.
#
# Usage: ./match-customer.sh --key "value" [--key "value" ...]
#   Keys: --jira-key, --repo, --slack-channel, --keyword, --source-type
# Output: JSON to stdout: {"customer": "Name", "jira_key": "PROJ-123"} or {"customer": "", "jira_key": ""}
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_FILE="$REPO_ROOT/worklogs/.customer-cache.json"

if [[ ! -f "$CACHE_FILE" ]]; then
  jq -n '{customer: "", jira_key: ""}'
  exit 0
fi

JIRA_KEY=""
REPO=""
SLACK_CHANNEL=""
KEYWORD=""
SOURCE_TYPE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jira-key) JIRA_KEY="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --slack-channel) SLACK_CHANNEL="$2"; shift 2 ;;
    --keyword) KEYWORD="$2"; shift 2 ;;
    --source-type) SOURCE_TYPE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

CACHE=$(cat "$CACHE_FILE")

# Priority 0: Routing rules — check source-type-based patterns first
# These assign both a customer AND a fixed Jira key
if [[ -n "$SOURCE_TYPE" ]]; then
  RULE=$(echo "$CACHE" | jq -r --arg pattern "${SOURCE_TYPE}" \
    '.routing_rules[$pattern] // empty | if . != "" and . != null then . else empty end')
  if [[ -n "$RULE" ]]; then
    echo "$RULE" | jq '{customer, jira_key}'
    exit 0
  fi
fi

# Also check repo and slack-channel against routing rules
if [[ -n "$REPO" ]]; then
  RULE=$(echo "$CACHE" | jq -r --arg pattern "repo:${REPO}" \
    '.routing_rules[$pattern] // empty | if . != "" and . != null then . else empty end')
  if [[ -n "$RULE" ]]; then
    echo "$RULE" | jq '{customer, jira_key}'
    exit 0
  fi
fi

if [[ -n "$SLACK_CHANNEL" ]]; then
  RULE=$(echo "$CACHE" | jq -r --arg pattern "slack:${SLACK_CHANNEL}" \
    '.routing_rules[$pattern] // empty | if . != "" and . != null then . else empty end')
  if [[ -n "$RULE" ]]; then
    echo "$RULE" | jq '{customer, jira_key}'
    exit 0
  fi
fi

# Helper: output customer-only match (no fixed Jira key)
emit_customer() {
  jq -n --arg c "$1" '{customer: $c, jira_key: ""}'
}

# Priority 1: Jira issue key → customer (direct lookup)
if [[ -n "$JIRA_KEY" ]]; then
  MATCH=$(echo "$CACHE" | jq -r --arg key "$JIRA_KEY" '.issue_to_customer[$key] // empty')
  if [[ -n "$MATCH" ]]; then
    emit_customer "$MATCH"
    exit 0
  fi
fi

# Priority 2: User-learned mappings (repo, slack channel)
if [[ -n "$REPO" ]]; then
  MATCH=$(echo "$CACHE" | jq -r --arg key "repo:${REPO}" '.user_mappings[$key] // empty')
  if [[ -n "$MATCH" ]]; then
    emit_customer "$MATCH"
    exit 0
  fi
fi

if [[ -n "$SLACK_CHANNEL" ]]; then
  MATCH=$(echo "$CACHE" | jq -r --arg key "slack:${SLACK_CHANNEL}" '.user_mappings[$key] // empty')
  if [[ -n "$MATCH" ]]; then
    emit_customer "$MATCH"
    exit 0
  fi
fi

# Priority 3: Keyword search across customer labels and components
if [[ -n "$KEYWORD" ]]; then
  MATCH=$(echo "$CACHE" | jq -r --arg kw "$KEYWORD" '
    .customers | to_entries[] |
    select(
      (.key | ascii_downcase | contains($kw | ascii_downcase)) or
      (.value.labels[]? | ascii_downcase | contains($kw | ascii_downcase)) or
      (.value.components[]? | ascii_downcase | contains($kw | ascii_downcase))
    ) | .key' | head -1)
  if [[ -n "$MATCH" ]]; then
    emit_customer "$MATCH"
    exit 0
  fi
fi

# No match found
jq -n '{customer: "", jira_key: ""}'
