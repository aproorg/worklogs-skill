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

# Strategy: Always use Search APIs for commits (reliable, date-accurate).
# Use Events API only for PR/issue events that Search doesn't cover.

# --- 1. Search Commits (primary source of truth for code work) ---
SEARCH_RESPONSE=$(curl -s -w "\n%{http_code}" \
  -H "$AUTH_HEADER" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/search/commits?q=author:${GITHUB_USERNAME}+author-date:${DATE}&per_page=100&sort=author-date")

SEARCH_HTTP=$(echo "$SEARCH_RESPONSE" | tail -1)
SEARCH_BODY=$(echo "$SEARCH_RESPONSE" | sed '$d')

COMMIT_ENTRIES="[]"
if [[ "$SEARCH_HTTP" == "200" ]]; then
  COMMIT_ENTRIES=$(echo "$SEARCH_BODY" | jq --arg date "$DATE" '[
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
  echo "Search Commits: found $(echo "$COMMIT_ENTRIES" | jq 'length') commits" >&2
elif [[ "$SEARCH_HTTP" == "401" || "$SEARCH_HTTP" == "403" ]]; then
  echo "ERROR: Github authentication failed (HTTP $SEARCH_HTTP) — check GITHUB_PERSONAL_ACCESS_TOKEN" >&2
  exit 1
elif [[ "$SEARCH_HTTP" == "429" ]]; then
  echo "ERROR: Github API rate limited" >&2
  exit 2
else
  echo "WARN: Github Search Commits API returned HTTP $SEARCH_HTTP" >&2
fi

# --- 2. Search PRs created/merged on this date ---
PR_RESPONSE=$(curl -s -w "\n%{http_code}" \
  -H "$AUTH_HEADER" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/search/issues?q=author:${GITHUB_USERNAME}+created:${DATE}+is:pr&per_page=100")

PR_HTTP=$(echo "$PR_RESPONSE" | tail -1)
PR_BODY=$(echo "$PR_RESPONSE" | sed '$d')

PR_ENTRIES="[]"
if [[ "$PR_HTTP" == "200" ]]; then
  PR_ENTRIES=$(echo "$PR_BODY" | jq --arg date "$DATE" '[
    .items[] |
    (.repository_url | split("/") | last) as $project |
    (.repository_url | ltrimstr("https://api.github.com/repos/")) as $repo |
    {
      id: ("gh-pr-" + (.id | tostring)),
      source: "github",
      project: $project,
      description: ("opened PR: " + .title),
      estimated_hours: 0.5,
      timestamp: .created_at,
      correlation_keys: ([("repo:" + $project)] + [(.title // "") | match("[A-Z]+-[0-9]+"; "g").string] // []),
      raw_metadata: { pr_number: .number, repo: $repo }
    }
  ]')
  echo "Search PRs: found $(echo "$PR_ENTRIES" | jq 'length') PRs" >&2
else
  echo "WARN: Github Search Issues API returned HTTP $PR_HTTP" >&2
fi

# --- 3. Events API for issue/comment events (supplement only) ---
EVENT_ENTRIES="[]"
for PAGE in 1 2 3; do
  RESPONSE=$(curl -s -w "\n%{http_code}" \
    -H "$AUTH_HEADER" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/users/${GITHUB_USERNAME}/events?per_page=100&page=${PAGE}")

  HTTP_CODE=$(echo "$RESPONSE" | tail -1)
  BODY=$(echo "$RESPONSE" | sed '$d')

  if [[ "$HTTP_CODE" != "200" ]]; then
    echo "WARN: Events API returned HTTP $HTTP_CODE on page $PAGE" >&2
    break
  fi

  DATE_EVENTS=$(echo "$BODY" | jq --arg date "$DATE" '[
    .[] | select(.created_at | startswith($date)) |
    . as $event |
    if .type == "IssuesEvent" then
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
  ]')

  EVENT_ENTRIES=$(echo "$EVENT_ENTRIES $DATE_EVENTS" | jq -s 'add')

  EARLIEST=$(echo "$BODY" | jq -r 'if length > 0 then last.created_at[:10] else "0000-00-00" end')
  if [[ "$EARLIEST" < "$DATE" || $(echo "$BODY" | jq 'length') -lt 100 ]]; then
    break
  fi
done
echo "Events API: found $(echo "$EVENT_ENTRIES" | jq 'length') issue/comment events" >&2

# --- 4. Merge all sources, deduplicate by id ---
ENTRIES=$(echo "$COMMIT_ENTRIES $PR_ENTRIES $EVENT_ENTRIES" | jq -s '
  add | group_by(.id) | map(first)
')

# --- 5. Enrich with diff stats ---
ENRICHED=$(echo "$ENTRIES" | jq -c '.[]' | while IFS= read -r entry; do
  SHA=$(echo "$entry" | jq -r '.raw_metadata.sha // empty')
  REPO=$(echo "$entry" | jq -r '.raw_metadata.repo // empty')
  PR_NUMBER=$(echo "$entry" | jq -r '.raw_metadata.pr_number // empty')

  if [[ -n "$SHA" && -n "$REPO" ]]; then
    # Enrich commits via commit stats API
    COMMIT_RESP=$(curl -s -H "$AUTH_HEADER" \
      -H "Accept: application/vnd.github.v3+json" \
      "https://api.github.com/repos/${REPO}/commits/${SHA}" 2>/dev/null || echo '{}')

    ADDITIONS=$(echo "$COMMIT_RESP" | jq '.stats.additions // 0')
    DELETIONS=$(echo "$COMMIT_RESP" | jq '.stats.deletions // 0')
    TOTAL_LINES=$((ADDITIONS + DELETIONS))

    HOURS=$(awk -v lines="$TOTAL_LINES" 'BEGIN {
      h = lines / 500;
      if (h < 1.0) h = 1.0;
      h = int(h * 4 + 0.5) / 4;
      printf "%.2f", h;
    }')

    # Use actual commit timestamp from API (author date)
    COMMIT_TS=$(echo "$COMMIT_RESP" | jq -r '.commit.author.date // empty')

    echo "$entry" | jq --argjson hours "$HOURS" --argjson add "$ADDITIONS" --argjson del "$DELETIONS" --arg ts "$COMMIT_TS" \
      '.estimated_hours = $hours | .raw_metadata.additions = $add | .raw_metadata.deletions = $del | if $ts != "" then .timestamp = $ts else . end'

  elif [[ -n "$PR_NUMBER" && -n "$REPO" ]]; then
    # Enrich PRs via pulls API (gets additions/deletions/changed_files)
    PR_RESP=$(curl -s -H "$AUTH_HEADER" \
      -H "Accept: application/vnd.github.v3+json" \
      "https://api.github.com/repos/${REPO}/pulls/${PR_NUMBER}" 2>/dev/null || echo '{}')

    ADDITIONS=$(echo "$PR_RESP" | jq '.additions // 0')
    DELETIONS=$(echo "$PR_RESP" | jq '.deletions // 0')
    TOTAL_LINES=$((ADDITIONS + DELETIONS))

    HOURS=$(awk -v lines="$TOTAL_LINES" 'BEGIN {
      h = lines / 500;
      if (h < 1.0) h = 1.0;
      h = int(h * 4 + 0.5) / 4;
      printf "%.2f", h;
    }')

    echo "$entry" | jq --argjson hours "$HOURS" --argjson add "$ADDITIONS" --argjson del "$DELETIONS" \
      '.estimated_hours = $hours | .raw_metadata.additions = $add | .raw_metadata.deletions = $del'
  else
    echo "$entry"
  fi
done | jq -s '.')

# --- 6. Post-process: absorb PRs that duplicate a nearby commit (same repo, within 15min) ---
FINAL=$(echo "$ENRICHED" | jq '
  (map(select(.id | startswith("gh-commit-")))) as $commits |
  (map(select(.id | startswith("gh-commit-") | not))) as $others |

  # Filter out PRs that duplicate a nearby commit (same repo, within 15min)
  [$others[] |
    . as $entry |
    (.project) as $entry_project |
    (.timestamp | fromdateiso8601) as $entry_ts |
    if ($entry.id | startswith("gh-pr-")) and ([$commits[] | select(
      .project == $entry_project and
      (((.timestamp | fromdateiso8601) - $entry_ts) | if . < 0 then -. else . end) < 900
    )] | length > 0) then
      empty
    else
      $entry
    end
  ] as $unique_others |

  $commits + $unique_others | sort_by(.timestamp)
')

echo "$FINAL"
