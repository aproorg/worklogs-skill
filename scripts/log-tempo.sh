#!/usr/bin/env bash
# Log worklog entries to Atlassian Tempo.
# Reads a JSON array of entries from stdin, each with:
#   { issue_key, description, hours, date }
# Outputs a JSON summary of created/failed worklogs to stdout.
# Usage: echo '[...]' | ./log-tempo.sh
#   or:  ./log-tempo.sh < entries.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

# Validate credentials
if [[ -z "${TEMPO_TOKEN:-}" ]]; then
  echo "ERROR: TEMPO_TOKEN not set in .env" >&2
  exit 1
fi
if [[ -z "${JIRA_BASE_URL:-}" ]]; then
  echo "ERROR: JIRA_BASE_URL not set in .env" >&2
  exit 1
fi
if [[ -z "${JIRA_USER_EMAIL:-}" ]]; then
  echo "ERROR: JIRA_USER_EMAIL not set in .env" >&2
  exit 1
fi
if [[ -z "${JIRA_TOKEN:-}" ]]; then
  echo "ERROR: JIRA_TOKEN not set in .env" >&2
  exit 1
fi

JIRA_BASE_URL="${JIRA_BASE_URL%/}"
JIRA_AUTH_B64=$(printf '%s:%s' "$JIRA_USER_EMAIL" "$JIRA_TOKEN" | base64)

# Resolve Jira accountId (required by Tempo API)
MYSELF_RESP=$(curl -s \
  -H "Authorization: Basic $JIRA_AUTH_B64" \
  -H "Accept: application/json" \
  "${JIRA_BASE_URL}/rest/api/2/myself")

ACCOUNT_ID=$(echo "$MYSELF_RESP" | jq -r '.accountId // empty')
if [[ -z "$ACCOUNT_ID" ]]; then
  echo "ERROR: Could not resolve Jira accountId — check JIRA_TOKEN and JIRA_USER_EMAIL" >&2
  exit 1
fi

# Read entries from stdin
ENTRIES=$(cat)
COUNT=$(echo "$ENTRIES" | jq 'length')

if [[ "$COUNT" -eq 0 ]]; then
  echo '{"created": 0, "failed": 0, "results": []}'
  exit 0
fi

CREATED=0
FAILED=0
RESULTS="[]"

echo "$ENTRIES" | jq -c '.[]' | while IFS= read -r entry; do
  ISSUE_KEY=$(echo "$entry" | jq -r '.issue_key')
  DESCRIPTION=$(echo "$entry" | jq -r '.description // ""')
  HOURS=$(echo "$entry" | jq -r '.hours')
  DATE=$(echo "$entry" | jq -r '.date')
  START_TIME=$(echo "$entry" | jq -r '.start_time // "09:00:00"')

  # Resolve issue key to numeric Jira issue ID (required by Tempo API)
  ISSUE_RESP=$(curl -s \
    -H "Authorization: Basic $JIRA_AUTH_B64" \
    -H "Accept: application/json" \
    "${JIRA_BASE_URL}/rest/api/2/issue/${ISSUE_KEY}?fields=id")
  ISSUE_ID=$(echo "$ISSUE_RESP" | jq -r '.id // empty')

  if [[ -z "$ISSUE_ID" ]]; then
    echo "FAIL: ${ISSUE_KEY} — could not resolve issue ID" >&2
    echo "{\"issue_key\":\"${ISSUE_KEY}\",\"hours\":${HOURS},\"http_code\":0,\"response\":\"Could not resolve issue ID\"}"
    continue
  fi

  # Convert hours to seconds
  SECONDS_SPENT=$(echo "$HOURS" | awk '{printf "%d", $1 * 3600}')

  # Build Tempo API payload (uses numeric issueId, not issueKey)
  PAYLOAD=$(jq -n \
    --argjson issueId "$ISSUE_ID" \
    --arg accountId "$ACCOUNT_ID" \
    --arg desc "$DESCRIPTION" \
    --arg date "$DATE" \
    --argjson seconds "$SECONDS_SPENT" \
    --arg startTime "$START_TIME" \
    '{
      issueId: $issueId,
      timeSpentSeconds: $seconds,
      startDate: $date,
      startTime: $startTime,
      description: $desc,
      authorAccountId: $accountId
    }')

  RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $TEMPO_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "https://api.tempo.io/4/worklogs")

  HTTP_CODE=$(echo "$RESPONSE" | tail -1)
  BODY=$(echo "$RESPONSE" | sed '$d')

  RESULT=$(jq -n \
    --arg key "$ISSUE_KEY" \
    --arg hours "$HOURS" \
    --arg code "$HTTP_CODE" \
    --arg body "$BODY" \
    '{issue_key: $key, hours: ($hours | tonumber), http_code: ($code | tonumber), response: ($body | try fromjson catch $body)}')

  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
    echo "OK: Logged ${HOURS}h to ${ISSUE_KEY}" >&2
  else
    echo "FAIL: ${ISSUE_KEY} — HTTP ${HTTP_CODE}" >&2
  fi

  # Output each result as a JSON line (collected by caller)
  echo "$RESULT"
done | jq -s '{
  created: [.[] | select(.http_code == 200 or .http_code == 201)] | length,
  failed: [.[] | select(.http_code != 200 and .http_code != 201)] | length,
  results: .
}'
