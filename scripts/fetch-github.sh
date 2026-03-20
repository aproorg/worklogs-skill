#!/usr/bin/env bash
# Fetch Github activity (commits, PRs, issues) for the user on a given date.
# Outputs JSON array of WorklogEntry objects to stdout.
# Usage: ./fetch-github.sh [YYYY-MM-DD]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

DATE="${1:-$(date +%Y-%m-%d)}"

if [[ -z "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]]; then
  echo "ERROR: GITHUB_PERSONAL_ACCESS_TOKEN not set in .env" >&2
  exit 1
fi
if [[ -z "${GITHUB_USERNAME:-}" ]]; then
  echo "ERROR: GITHUB_USERNAME not set in .env" >&2
  exit 1
fi

AUTH_HEADER="Authorization: token $GITHUB_PERSONAL_ACCESS_TOKEN"

# Strategy: Try Events API first (fast, works for recent dates).
# If no events found, fall back to Search Commits API (works for any date).

# --- Attempt 1: Events API (recent dates only) ---
ALL_EVENTS="[]"
for PAGE in 1 2 3; do
  RESPONSE=$(curl -s -w "\n%{http_code}" \
    -H "$AUTH_HEADER" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/users/${GITHUB_USERNAME}/events?per_page=100&page=${PAGE}")

  HTTP_CODE=$(echo "$RESPONSE" | tail -1)
  BODY=$(echo "$RESPONSE" | sed '$d')

  if [[ "$HTTP_CODE" == "429" ]]; then
    echo "ERROR: Github API rate limited" >&2
    exit 2
  fi
  if [[ "$HTTP_CODE" == "401" || "$HTTP_CODE" == "403" ]]; then
    echo "ERROR: Github authentication failed (HTTP $HTTP_CODE) — check GITHUB_PERSONAL_ACCESS_TOKEN" >&2
    exit 1
  fi
  if [[ "$HTTP_CODE" != "200" ]]; then
    echo "ERROR: Github API returned HTTP $HTTP_CODE" >&2
    exit 2
  fi

  DATE_EVENTS=$(echo "$BODY" | jq --arg date "$DATE" '[.[] | select(.created_at | startswith($date))]')
  ALL_EVENTS=$(echo "$ALL_EVENTS $DATE_EVENTS" | jq -s 'add')

  EARLIEST=$(echo "$BODY" | jq -r 'if length > 0 then last.created_at[:10] else "0000-00-00" end')
  if [[ "$EARLIEST" < "$DATE" || $(echo "$BODY" | jq 'length') -lt 100 ]]; then
    break
  fi
done

EVENTS_COUNT=$(echo "$ALL_EVENTS" | jq 'length')

if [[ "$EVENTS_COUNT" -gt 0 ]]; then
  # Convert events into WorklogEntry objects
  ENTRIES=$(echo "$ALL_EVENTS" | jq --arg date "$DATE" '[
    .[] | . as $event |
    if .type == "PushEvent" then
      ($event.repo.name // "unknown") as $repo |
      ($repo | split("/") | last) as $project |
      ($event.payload.commits // []) | .[] |
      {
        id: ("gh-commit-" + .sha[:12]),
        source: "github",
        project: $project,
        description: (.message | split("\n")[0]),
        estimated_hours: 0.5,
        timestamp: ($date + "T12:00:00Z"),
        correlation_keys: ([("repo:" + $project)] + [(.message // "") | match("[A-Z]+-[0-9]+"; "g").string] // []),
        raw_metadata: { sha: .sha, repo: $repo }
      }
    elif .type == "PullRequestEvent" then
      ($event.repo.name | split("/") | last) as $project |
      {
        id: ("gh-pr-" + ($event.payload.pull_request.id | tostring)),
        source: "github",
        project: $project,
        description: ($event.payload.action + " PR: " + $event.payload.pull_request.title),
        estimated_hours: 0.5,
        timestamp: $event.created_at,
        correlation_keys: ([("repo:" + $project)] + [($event.payload.pull_request.title // "") | match("[A-Z]+-[0-9]+"; "g").string] // []),
        raw_metadata: { pr_number: $event.payload.pull_request.number, repo: $event.repo.name }
      }
    elif .type == "IssuesEvent" then
      ($event.repo.name | split("/") | last) as $project |
      {
        id: ("gh-issue-" + ($event.payload.issue.id | tostring)),
        source: "github",
        project: $project,
        description: ($event.payload.action + " issue: " + $event.payload.issue.title),
        estimated_hours: 0.25,
        timestamp: $event.created_at,
        correlation_keys: ([("repo:" + $project)] + [($event.payload.issue.title // "") | match("[A-Z]+-[0-9]+"; "g").string] // []),
        raw_metadata: { issue_number: $event.payload.issue.number, repo: $event.repo.name }
      }
    elif .type == "IssueCommentEvent" then
      ($event.repo.name | split("/") | last) as $project |
      {
        id: ("gh-comment-" + ($event.id | tostring)),
        source: "github",
        project: $project,
        description: ("Commented on: " + $event.payload.issue.title),
        estimated_hours: 0.25,
        timestamp: $event.created_at,
        correlation_keys: ([("repo:" + $project)] + [($event.payload.issue.title // "") | match("[A-Z]+-[0-9]+"; "g").string] // []),
        raw_metadata: { issue_number: $event.payload.issue.number, repo: $event.repo.name }
      }
    else
      empty
    end
  ] | flatten')
else
  # --- Attempt 2: Search Commits API (works for any date) ---
  echo "Events API returned no results for $DATE, falling back to Search Commits API" >&2

  SEARCH_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -H "$AUTH_HEADER" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/search/commits?q=author:${GITHUB_USERNAME}+author-date:${DATE}&per_page=100&sort=author-date")

  SEARCH_HTTP=$(echo "$SEARCH_RESPONSE" | tail -1)
  SEARCH_BODY=$(echo "$SEARCH_RESPONSE" | sed '$d')

  if [[ "$SEARCH_HTTP" != "200" ]]; then
    echo "ERROR: Github Search API returned HTTP $SEARCH_HTTP" >&2
    exit 2
  fi

  ENTRIES=$(echo "$SEARCH_BODY" | jq --arg date "$DATE" '[
    .items[] |
    (.repository.full_name) as $repo |
    ($repo | split("/") | last) as $project |
    {
      id: ("gh-commit-" + .sha[:12]),
      source: "github",
      project: $project,
      description: (.commit.message | split("\n")[0]),
      estimated_hours: 0.5,
      timestamp: .commit.author.date,
      correlation_keys: ([("repo:" + $project)] + [(.commit.message // "") | match("[A-Z]+-[0-9]+"; "g").string] // []),
      raw_metadata: { sha: .sha, repo: $repo }
    }
  ]')
fi

# Fetch diff stats for commits to improve estimation
ENRICHED=$(echo "$ENTRIES" | jq -c '.[]' | while IFS= read -r entry; do
  SHA=$(echo "$entry" | jq -r '.raw_metadata.sha // empty')
  REPO=$(echo "$entry" | jq -r '.raw_metadata.repo // empty')

  if [[ -n "$SHA" && -n "$REPO" ]]; then
    COMMIT_RESP=$(curl -s -H "$AUTH_HEADER" \
      -H "Accept: application/vnd.github.v3+json" \
      "https://api.github.com/repos/${REPO}/commits/${SHA}" 2>/dev/null || echo '{}')

    ADDITIONS=$(echo "$COMMIT_RESP" | jq '.stats.additions // 0')
    DELETIONS=$(echo "$COMMIT_RESP" | jq '.stats.deletions // 0')
    TOTAL_LINES=$((ADDITIONS + DELETIONS))

    # Tiered estimation based on diff size
    if [[ $TOTAL_LINES -lt 20 ]]; then
      HOURS="0.25"
    elif [[ $TOTAL_LINES -lt 100 ]]; then
      HOURS="0.5"
    elif [[ $TOTAL_LINES -lt 300 ]]; then
      HOURS="1.0"
    else
      HOURS="2.0"
    fi

    # Use actual commit timestamp from API (author date)
    COMMIT_TS=$(echo "$COMMIT_RESP" | jq -r '.commit.author.date // empty')

    echo "$entry" | jq --argjson hours "$HOURS" --argjson add "$ADDITIONS" --argjson del "$DELETIONS" --arg ts "$COMMIT_TS" \
      '.estimated_hours = $hours | .raw_metadata.additions = $add | .raw_metadata.deletions = $del | if $ts != "" then .timestamp = $ts else . end'
  else
    echo "$entry"
  fi
done | jq -s '.')

echo "$ENRICHED"
