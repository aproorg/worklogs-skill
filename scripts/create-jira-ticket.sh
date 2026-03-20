#!/usr/bin/env bash
# Create a Jira ticket with the Customer Gen AI and Account fields set.
# Usage: ./create-jira-ticket.sh --project PROJ --summary "Ticket summary" --customer "CustomerName"
# Optional: --description "Full description" --type "Task" --account-id 123
# Output: JSON with created issue key and URL
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

# Validate Jira credentials
if [[ -z "${JIRA_BASE_URL:-}" || -z "${JIRA_USER_EMAIL:-}" || -z "${JIRA_TOKEN:-}" ]]; then
  echo "ERROR: JIRA_BASE_URL, JIRA_USER_EMAIL, and JIRA_TOKEN must all be set in .env" >&2
  exit 1
fi

JIRA_BASE_URL="${JIRA_BASE_URL%/}"
AUTH_B64=$(printf '%s:%s' "$JIRA_USER_EMAIL" "$JIRA_TOKEN" | base64)
AUTH_HEADER="Authorization: Basic $AUTH_B64"

# Parse arguments
PROJECT=""
SUMMARY=""
CUSTOMER=""
DESCRIPTION=""
ISSUE_TYPE="Task"
ACCOUNT_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --summary) SUMMARY="$2"; shift 2 ;;
    --customer) CUSTOMER="$2"; shift 2 ;;
    --description) DESCRIPTION="$2"; shift 2 ;;
    --type) ISSUE_TYPE="$2"; shift 2 ;;
    --account-id) ACCOUNT_ID="$2"; shift 2 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PROJECT" || -z "$SUMMARY" ]]; then
  echo "ERROR: --project and --summary are required" >&2
  echo "Usage: $0 --project PROJ --summary \"Summary\" [--customer \"Name\"] [--description \"Desc\"] [--type \"Task\"] [--account-id 123]" >&2
  exit 1
fi

# Build the issue payload
# Start with base fields, then conditionally add customer and description
PAYLOAD=$(jq -n \
  --arg project "$PROJECT" \
  --arg summary "$SUMMARY" \
  --arg description "$DESCRIPTION" \
  --arg issueType "$ISSUE_TYPE" \
  --arg customer "$CUSTOMER" \
  --arg accountId "$ACCOUNT_ID" \
  '
  {
    fields: (
      {
        project: { key: $project },
        summary: $summary,
        issuetype: { name: $issueType }
      }
      + (if $description != "" then {
          description: {
            type: "doc",
            version: 1,
            content: [{
              type: "paragraph",
              content: [{ type: "text", text: $description }]
            }]
          }
        } else {} end)
      + (if $customer != "" then {
          customfield_12513: { value: $customer }
        } else {} end)
      + (if $accountId != "" then {
          customfield_11530: { id: ($accountId | tonumber) }
        } else {} end)
    )
  }')

RESPONSE=$(curl -s -w "\n%{http_code}" \
  -X POST \
  -H "$AUTH_HEADER" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "${JIRA_BASE_URL}/rest/api/3/issue")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" == "201" ]]; then
  ISSUE_KEY=$(echo "$BODY" | jq -r '.key')
  ISSUE_URL="${JIRA_BASE_URL}/browse/${ISSUE_KEY}"
  echo "Created: ${ISSUE_KEY}" >&2
  jq -n --arg key "$ISSUE_KEY" --arg url "$ISSUE_URL" --arg customer "$CUSTOMER" \
    '{issue_key: $key, url: $url, customer: $customer, success: true}'
else
  ERROR_MSG=$(echo "$BODY" | jq -r '.errors // .errorMessages // "Unknown error"' 2>/dev/null || echo "$BODY")
  echo "ERROR: Failed to create ticket (HTTP $HTTP_CODE): $ERROR_MSG" >&2
  jq -n --arg error "$ERROR_MSG" --argjson code "$HTTP_CODE" \
    '{success: false, http_code: $code, error: $error}'
  exit 2
fi
