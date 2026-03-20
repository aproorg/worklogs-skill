#!/usr/bin/env bash
# Fetch Jira issues the user interacted with on a given date.
# Uses Jira REST API v3 /search/jql endpoint with Basic auth.
# Outputs JSON array of WorklogEntry objects to stdout.
# Usage: ./fetch-jira.sh [YYYY-MM-DD]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

DATE="${1:-$(date +%Y-%m-%d)}"

# Validate credentials
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

# Strip trailing slash from base URL
JIRA_BASE_URL="${JIRA_BASE_URL%/}"

# Jira Cloud uses Basic auth: base64(email:api_token)
AUTH_B64=$(printf '%s:%s' "$JIRA_USER_EMAIL" "$JIRA_TOKEN" | base64)
AUTH_HEADER="Authorization: Basic $AUTH_B64"

# Fetch current user's accountId for filtering worklogs
MYSELF_RESP=$(curl -s -H "$AUTH_HEADER" -H "Accept: application/json" \
  "${JIRA_BASE_URL}/rest/api/2/myself" 2>/dev/null || echo '{}')
ACCOUNT_ID=$(echo "$MYSELF_RESP" | jq -r '.accountId // empty')

if [[ -z "$ACCOUNT_ID" ]]; then
  echo "ERROR: Could not resolve Jira accountId — check JIRA_TOKEN and JIRA_USER_EMAIL" >&2
  exit 1
fi

# Compute next day for date range queries
NEXT_DATE=$(date -j -f "%Y-%m-%d" -v+1d "$DATE" "+%Y-%m-%d" 2>/dev/null || date -d "$DATE + 1 day" "+%Y-%m-%d")

# JQL: issues updated by current user on the target date
JQL="(worklogAuthor = currentUser() AND worklogDate = '${DATE}') OR (assignee = currentUser() AND updatedDate >= '${DATE}' AND updatedDate < '${NEXT_DATE}')"
ENCODED_JQL=$(printf '%s' "$JQL" | jq -sRr @uri)

# Use /rest/api/3/search/jql — the new Jira Cloud search endpoint
# (the old /rest/api/2/search and /rest/api/3/search are deprecated/removed)
RESPONSE=$(curl -s -w "\n%{http_code}" \
  -H "$AUTH_HEADER" \
  -H "Accept: application/json" \
  "${JIRA_BASE_URL}/rest/api/3/search/jql?jql=${ENCODED_JQL}&maxResults=50&fields=summary,status,project,updated,worklog,assignee,customfield_12513")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" == "429" ]]; then
  echo "ERROR: Jira API rate limited" >&2
  exit 2
fi
if [[ "$HTTP_CODE" == "401" || "$HTTP_CODE" == "403" ]]; then
  echo "ERROR: Jira authentication failed (HTTP $HTTP_CODE) — check JIRA_TOKEN and JIRA_USER_EMAIL" >&2
  exit 1
fi
if [[ "$HTTP_CODE" != "200" ]]; then
  echo "ERROR: Jira API returned HTTP $HTTP_CODE" >&2
  exit 2
fi

# Check for Jira-level errors
ERROR_MSG=$(echo "$BODY" | jq -r '.errorMessages // [] | .[0] // empty' 2>/dev/null || true)
if [[ -n "$ERROR_MSG" ]]; then
  echo "ERROR: Jira API error: $ERROR_MSG" >&2
  exit 2
fi

# Parse issues into WorklogEntry objects
echo "$BODY" | jq --arg date "$DATE" --arg accountId "$ACCOUNT_ID" '[
  .issues // [] | .[] |
  (.key) as $key |
  (.fields.project.key // "Unknown") as $project_key |
  (.fields.project.name // $project_key) as $project_name |
  (.fields.customfield_12513.value // null) as $customer_name |
  (.fields.summary // "No summary") as $summary |
  (.fields.status.name // "Unknown") as $status |
  (.fields.updated // "") as $updated |

  # Check if the user has worklogs on this date
  (
    [.fields.worklog.worklogs // [] | .[] |
     select(.author.accountId == $accountId) |
     select(.started | startswith($date)) |
     .timeSpentSeconds
    ] | add // 0
  ) as $logged_seconds |

  # Estimate hours: use logged time if available, else default 0.5h
  (if $logged_seconds > 0 then
    ($logged_seconds / 3600 * 100 | round / 100)
  else
    0.5
  end) as $est_hours |

  {
    id: ("jira-" + $key),
    source: "jira",
    project: ($customer_name // $project_key),
    description: ($key + ": " + $summary + " [" + $status + "]"),
    estimated_hours: (if $est_hours > 12 then 12 elif $est_hours < 0.25 then 0.25 else $est_hours end),
    timestamp: $updated,
    correlation_keys: [$key, ("project:" + $project_key)],
    raw_metadata: {
      issue_key: $key,
      project_key: $project_key,
      project_name: $project_name,
      customer_name: $customer_name,
      status: $status,
      logged_seconds: $logged_seconds
    }
  }
]'
