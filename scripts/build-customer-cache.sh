#!/usr/bin/env bash
# Build/refresh customer cache from recent Jira tickets.
# Queries Jira for tickets with customfield_12513 (Customer Gen AI) set,
# extracts customer→project/repo mappings, and writes to worklogs/.customer-cache.json.
#
# If the cache is fresh (< 24h old), outputs it as-is unless --force is passed.
#
# Usage: ./build-customer-cache.sh [--force]
# Output: JSON customer cache to stdout
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
CACHE_FILE="$REPO_ROOT/worklogs/.customer-cache.json"

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
FORCE="${1:-}"

# Check cache freshness (24h = 86400s)
if [[ -f "$CACHE_FILE" && "$FORCE" != "--force" ]]; then
  if [[ "$(uname)" == "Darwin" ]]; then
    CACHE_AGE=$(( $(date +%s) - $(stat -f %m "$CACHE_FILE") ))
  else
    CACHE_AGE=$(( $(date +%s) - $(stat -c %Y "$CACHE_FILE") ))
  fi
  if [[ "$CACHE_AGE" -lt 86400 ]]; then
    echo "Cache is fresh (${CACHE_AGE}s old), using existing cache" >&2
    cat "$CACHE_FILE"
    exit 0
  fi
fi

echo "Building customer cache from Jira..." >&2

# Load existing user_mappings and routing_rules from cache (if any) so we don't lose learned data
EXISTING_USER_MAPPINGS='{}'
EXISTING_ROUTING_RULES='{}'
if [[ -f "$CACHE_FILE" ]]; then
  EXISTING_USER_MAPPINGS=$(jq '.user_mappings // {}' "$CACHE_FILE" 2>/dev/null || echo '{}')
  EXISTING_ROUTING_RULES=$(jq '.routing_rules // {}' "$CACHE_FILE" 2>/dev/null || echo '{}')
fi

# Query Jira for recent tickets that have the customer field set
# Look back 90 days for a good spread of customer data
JQL="\"Customer Gen AI (migrated)\" is not EMPTY AND updated >= -90d ORDER BY updated DESC"
ENCODED_JQL=$(printf '%s' "$JQL" | jq -sRr @uri)

ALL_ISSUES='[]'
START_AT=0
MAX_RESULTS=100

while true; do
  RESPONSE=$(curl -s -w "\n%{http_code}" \
    -H "$AUTH_HEADER" \
    -H "Accept: application/json" \
    "${JIRA_BASE_URL}/rest/api/3/search/jql?jql=${ENCODED_JQL}&startAt=${START_AT}&maxResults=${MAX_RESULTS}&fields=summary,project,customfield_12513,customfield_11530,labels,components")

  HTTP_CODE=$(echo "$RESPONSE" | tail -1)
  BODY=$(echo "$RESPONSE" | sed '$d')

  if [[ "$HTTP_CODE" != "200" ]]; then
    echo "ERROR: Jira API returned HTTP $HTTP_CODE" >&2
    # If we have an existing cache, fall back to it
    if [[ -f "$CACHE_FILE" ]]; then
      echo "Falling back to existing cache" >&2
      cat "$CACHE_FILE"
      exit 0
    fi
    exit 2
  fi

  PAGE_ISSUES=$(echo "$BODY" | jq '.issues // []')
  PAGE_COUNT=$(echo "$PAGE_ISSUES" | jq 'length')
  TOTAL=$(echo "$BODY" | jq '.total // 0')

  ALL_ISSUES=$(echo "$ALL_ISSUES" "$PAGE_ISSUES" | jq -s '.[0] + .[1]')

  START_AT=$((START_AT + PAGE_COUNT))
  if [[ "$START_AT" -ge "$TOTAL" || "$PAGE_COUNT" -eq 0 ]]; then
    break
  fi
done

ISSUE_COUNT=$(echo "$ALL_ISSUES" | jq 'length')
echo "Fetched $ISSUE_COUNT issues with customer data" >&2

# Build the cache structure:
# {
#   "last_updated": "ISO timestamp",
#   "customers": {
#     "CustomerName": {
#       "jira_projects": ["PROJ1", "PROJ2"],
#       "issue_keys": ["PROJ-1", "PROJ-2"],
#       "labels": ["label1"],
#       "components": ["comp1"]
#     }
#   },
#   "reverse_index": {
#     "jira_project:PROJ": "CustomerName",
#     ...
#   },
#   "user_mappings": {
#     "repo:my-repo": "CustomerName",
#     "slack:#channel": "CustomerName"
#   }
# }

CACHE=$(echo "$ALL_ISSUES" | jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson user_mappings "$EXISTING_USER_MAPPINGS" --argjson routing_rules "$EXISTING_ROUTING_RULES" '
  # Build issue→customer map first (before grouping)
  (reduce .[] as $issue ({};
    ($issue.fields.customfield_12513.value // null) as $customer |
    if $customer then .[$issue.key] = $customer else . end
  )) as $issue_to_customer |

  # Group by customer name
  group_by(.fields.customfield_12513.value) |
  map(select(.[0].fields.customfield_12513.value != null)) |

  # Build customers object
  reduce .[] as $group ({};
    ($group[0].fields.customfield_12513.value) as $customer |
    .[$customer] = {
      jira_projects: ([$group[].fields.project.key] | unique),
      issue_count: ($group | length),
      labels: ([$group[].fields.labels // [] | .[]] | unique),
      components: ([$group[].fields.components // [] | .[].name] | unique)
    }
  ) |

  # Build the full cache
  {
    last_updated: $now,
    customers: .,
    issue_to_customer: $issue_to_customer,
    user_mappings: $user_mappings,
    routing_rules: $routing_rules
  }
')

# Ensure worklogs directory exists
mkdir -p "$REPO_ROOT/worklogs"

echo "$CACHE" > "$CACHE_FILE"

CUSTOMER_COUNT=$(echo "$CACHE" | jq '.customers | length')
echo "Cache built: $CUSTOMER_COUNT customers from $ISSUE_COUNT issues" >&2

# Also extract customer→account mappings from tickets that have both fields set
# and merge into .account-mappings.json (without overwriting user-saved mappings)
ACCOUNT_MAPPINGS_FILE="$REPO_ROOT/worklogs/.account-mappings.json"
if [[ ! -f "$ACCOUNT_MAPPINGS_FILE" ]]; then
  echo '{}' > "$ACCOUNT_MAPPINGS_FILE"
fi

LEARNED_ACCOUNTS=$(echo "$ALL_ISSUES" | jq '
  [.[] | select(.fields.customfield_12513.value != null and .fields.customfield_11530.id != null) |
    {customer: .fields.customfield_12513.value, account_id: .fields.customfield_11530.id}
  ] | unique_by(.customer) | reduce .[] as $m ({}; .[$m.customer] = $m.account_id)
')

LEARNED_COUNT=$(echo "$LEARNED_ACCOUNTS" | jq 'length')
if [[ "$LEARNED_COUNT" -gt 0 ]]; then
  # Merge: existing mappings take precedence (user may have overridden)
  jq -s '.[0] * .[1]' <(echo "$LEARNED_ACCOUNTS") "$ACCOUNT_MAPPINGS_FILE" > "${ACCOUNT_MAPPINGS_FILE}.tmp" \
    && mv "${ACCOUNT_MAPPINGS_FILE}.tmp" "$ACCOUNT_MAPPINGS_FILE"
  echo "Learned $LEARNED_COUNT customer→account mappings from Jira tickets" >&2
fi

echo "$CACHE"
