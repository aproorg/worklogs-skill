#!/usr/bin/env bash
# Fetch sent emails from Gmail for a given date.
# Outputs JSON array of WorklogEntry objects to stdout.
# Usage: ./fetch-gmail.sh [YYYY-MM-DD]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source Google auth helper
source "$SCRIPT_DIR/lib/google-auth.sh"

DATE="${1:-$(date +%Y-%m-%d)}"
# Format for Gmail query: YYYY/MM/DD
GMAIL_DATE=$(echo "$DATE" | tr '-' '/')
NEXT_DATE=$(date -j -f "%Y-%m-%d" -v+1d "$DATE" "+%Y/%m/%d" 2>/dev/null || date -d "$DATE + 1 day" "+%Y/%m/%d")

# Get access token
ACCESS_TOKEN=$(get_google_access_token) || exit 1

# Search for sent emails on the target date
QUERY="from:me after:${GMAIL_DATE} before:${NEXT_DATE}"
RESPONSE=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "https://gmail.googleapis.com/gmail/v1/users/me/messages?q=$(printf '%s' "$QUERY" | jq -sRr @uri)&maxResults=50")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" == "429" ]]; then
  echo "ERROR: Gmail API rate limited" >&2
  exit 2
fi
if [[ "$HTTP_CODE" == "401" || "$HTTP_CODE" == "403" ]]; then
  echo "ERROR: Gmail authentication failed (HTTP $HTTP_CODE) — re-run to re-authorize Google OAuth" >&2
  exit 1
fi
if [[ "$HTTP_CODE" != "200" ]]; then
  echo "ERROR: Gmail API returned HTTP $HTTP_CODE" >&2
  exit 2
fi

# Get message IDs
MSG_IDS=$(echo "$BODY" | jq -r '.messages // [] | .[].id')

if [[ -z "$MSG_IDS" ]]; then
  echo "[]"
  exit 0
fi

# Fetch each message's metadata
ENTRIES="["
FIRST=true
while IFS= read -r msg_id; do
  [[ -z "$msg_id" ]] && continue

  MSG_RESP=$(curl -s \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "https://gmail.googleapis.com/gmail/v1/users/me/messages/${msg_id}?format=metadata&metadataHeaders=Subject&metadataHeaders=To&metadataHeaders=Date")

  SUBJECT=$(echo "$MSG_RESP" | jq -r '[.payload.headers[] | select(.name == "Subject")][0].value // "No subject"')
  TO=$(echo "$MSG_RESP" | jq -r '[.payload.headers[] | select(.name == "To")][0].value // ""')
  MSG_DATE=$(echo "$MSG_RESP" | jq -r '[.payload.headers[] | select(.name == "Date")][0].value // ""')
  TIMESTAMP=$(echo "$MSG_RESP" | jq -r '.internalDate // "0" | tonumber / 1000 | todate')

  # Derive project from recipient domain or subject keywords
  DOMAIN=$(echo "$TO" | grep -oE '@[a-zA-Z0-9.-]+' | head -1 | tr -d '@' || echo "")

  # Extract Jira ticket IDs from subject
  TICKETS=$(echo "$SUBJECT" | grep -oE '[A-Z]+-[0-9]+' || true)
  CORRELATION="[]"
  if [[ -n "$TICKETS" ]]; then
    CORRELATION=$(echo "$TICKETS" | jq -R -s 'split("\n") | map(select(length > 0))')
  fi

  ENTRY=$(jq -n \
    --arg id "gmail-$msg_id" \
    --arg subject "$SUBJECT" \
    --arg domain "$DOMAIN" \
    --arg ts "$TIMESTAMP" \
    --argjson corr "$CORRELATION" \
    '{
      id: $id,
      source: "gmail",
      project: ($domain | if . == "" then "Uncategorized" else . end),
      description: ("Sent email: " + $subject),
      estimated_hours: 0.25,  # Fixed at 0.25h per email — always within [0.25, 12] cap
      timestamp: $ts,
      correlation_keys: $corr,
      raw_metadata: { subject: $subject, to_domain: $domain }
    }')

  if [[ "$FIRST" == "true" ]]; then
    FIRST=false
  else
    ENTRIES+=","
  fi
  ENTRIES+="$ENTRY"
done <<< "$MSG_IDS"

ENTRIES+="]"
echo "$ENTRIES" | jq '.'
