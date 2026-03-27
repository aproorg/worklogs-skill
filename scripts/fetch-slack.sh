#!/usr/bin/env bash
# Fetch Slack messages sent by the user on a given date.
# Outputs JSON array of WorklogEntry objects to stdout.
# Usage: ./fetch-slack.sh [YYYY-MM-DD]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

# Load .env
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

DATE="${1:-$(date +%Y-%m-%d)}"

# Validate credentials
if [[ -z "${SLACK_BOT_TOKEN:-}" ]]; then
  echo "ERROR: SLACK_BOT_TOKEN not set in .env" >&2
  exit 1
fi
if [[ -z "${SLACK_USER_EMAIL:-}" ]]; then
  echo "ERROR: SLACK_USER_EMAIL not set in .env" >&2
  exit 1
fi

# Resolve Slack username from token (auth.test returns the token owner)
SLACK_USERNAME=$(curl -s -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  "https://slack.com/api/auth.test" | jq -r '.user // empty')

if [[ -z "$SLACK_USERNAME" ]]; then
  echo "ERROR: Could not resolve Slack username from token" >&2
  exit 1
fi

# Use "from:<username> on:<date>" — email addresses and after:/before: don't work reliably
QUERY="from:${SLACK_USERNAME} on:${DATE}"
RESPONSE=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  "https://slack.com/api/search.messages?query=$(printf '%s' "$QUERY" | jq -sRr @uri)&count=100")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" == "429" ]]; then
  echo "ERROR: Slack API rate limited" >&2
  exit 2
fi

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "ERROR: Slack API returned HTTP $HTTP_CODE" >&2
  exit 2
fi

OK=$(echo "$BODY" | jq -r '.ok')
if [[ "$OK" != "true" ]]; then
  ERROR=$(echo "$BODY" | jq -r '.error // "unknown"')
  if [[ "$ERROR" == "invalid_auth" || "$ERROR" == "not_authed" || "$ERROR" == "token_revoked" ]]; then
    echo "ERROR: Slack authentication failed ($ERROR) — check SLACK_BOT_TOKEN" >&2
    exit 1
  fi
  echo "ERROR: Slack API error: $ERROR" >&2
  exit 2
fi

# Parse messages into WorklogEntry objects
# Group by channel and compute time-span-based estimates:
# - Time span of messages in a channel = proxy for conversation duration
# - Estimate 50% of span as active work time (per research.md #7)
# - Minimum 0.25h per channel with activity

# Step 1: Build a user ID → display name map for DM channels
# DM channel names are Slack user IDs (e.g. U068DQDK8U9) — resolve them to real names
DM_USER_IDS=$(echo "$BODY" | jq -r '[.messages.matches // [] | .[].channel.name] | unique | map(select(test("^[UW][A-Z0-9]{8,}$"))) | .[]')
USER_MAP='{}'
if [[ -n "$DM_USER_IDS" ]]; then
  for SLACK_UID in $DM_USER_IDS; do
    UNAME=$(curl -s -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      "https://slack.com/api/users.info?user=$SLACK_UID" | jq -r '.user.real_name // .user.profile.display_name // .user.name // empty')
    if [[ -n "$UNAME" ]]; then
      USER_MAP=$(echo "$USER_MAP" | jq --arg id "$SLACK_UID" --arg name "$UNAME" '. + {($id): $name}')
    fi
  done
  echo "Resolved $(echo "$USER_MAP" | jq 'length') DM user names" >&2
fi

# Step 1b: Resolve group DM (mpdm-*) channel names to participant names
# mpdm names embed Slack usernames: mpdm-levy--hlodver--pall-1
# Fetch users.list once and map usernames → real names, excluding the current user
MPIM_CHANNELS=$(echo "$BODY" | jq -r '[.messages.matches // [] | .[].channel.name] | unique | map(select(startswith("mpdm-"))) | .[]')
if [[ -n "$MPIM_CHANNELS" ]]; then
  # Fetch full user list (username → real_name map)
  USERNAME_MAP=$(curl -s -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    "https://slack.com/api/users.list?limit=500" | jq '[.members[] | {(.name): .real_name}] | add // {}')

  for MPIM in $MPIM_CHANNELS; do
    # Parse usernames: strip "mpdm-" prefix and trailing "-N" suffix, split on "--"
    PARSED_NAMES=$(echo "$MPIM" | sed 's/^mpdm-//; s/-[0-9]*$//' | tr '-' '\n' | grep -v '^$' | grep -v "^${SLACK_USERNAME}$")
    DISPLAY_PARTS=""
    for UNAME in $PARSED_NAMES; do
      REAL=$(echo "$USERNAME_MAP" | jq -r --arg u "$UNAME" '.[$u] // empty')
      if [[ -n "$REAL" ]]; then
        # Use first name only for brevity
        FIRST=$(echo "$REAL" | awk '{print $1}')
        DISPLAY_PARTS="${DISPLAY_PARTS:+$DISPLAY_PARTS, }$FIRST"
      else
        DISPLAY_PARTS="${DISPLAY_PARTS:+$DISPLAY_PARTS, }$UNAME"
      fi
    done
    if [[ -n "$DISPLAY_PARTS" ]]; then
      USER_MAP=$(echo "$USER_MAP" | jq --arg id "$MPIM" --arg name "$DISPLAY_PARTS" '. + {($id): $name}')
    fi
  done
  echo "Resolved $(echo "$MPIM_CHANNELS" | wc -l | tr -d ' ') group DM names" >&2
fi

# Step 2: Generate worklog entries, substituting user IDs with names
# Then cap total Slack hours at 1.0h for the day (proportionally scale down if needed)
ENTRIES=$(echo "$BODY" | jq --arg date "$DATE" --argjson user_map "$USER_MAP" '
  [.messages.matches // [] | .[]] |
  group_by(.channel.name) |
  map(
    # Per-channel grouping
    (.[0].channel.name // "unknown") as $channel_raw |
    # Resolve DM user IDs to display names
    ($user_map[$channel_raw] // null) as $resolved_name |
    (if $resolved_name then $resolved_name else $channel_raw end) as $channel_display |
    # Collect all timestamps in this channel
    ([.[] | .ts | split(".")[0] | tonumber] | sort) as $times |
    # Time span in hours (used for display only)
    (if ($times | length) > 1 then
      (($times | last) - ($times | first)) / 3600
    else
      0
    end) as $span |
    # Estimate based on message count: 5min per message, min 0.25h
    ([(. | length) * (5/60), 0.25] | max | . * 4 | round / 4) as $raw_hours |
    # Collect all ticket IDs from messages in this channel
    ([.[] | (.text // "") | [match("[A-Z]+-[0-9]+"; "g").string] | .[]] | unique) as $tickets |
    # Is this a DM?
    ($user_map[$channel_raw] != null) as $is_dm |
    # Use first message as representative
    {
      id: ("slack-ch-" + $channel_raw + "-" + $date),
      source: "slack",
      project: $channel_display,
      description: (
        if (. | length) == 1 then
          (.[0].text | if length > 120 then .[:120] + "..." else . end)
        else
          "\(. | length) messages" +
          (if $is_dm then " with \($channel_display)" else " in #\($channel_display)" end) +
          if ($span > 0) then " (over \($span * 60 | round)min)" else "" end
        end
      ),
      estimated_hours: $raw_hours,
      timestamp: (.[0].ts | split(".")[0] | tonumber | todate),
      correlation_keys: ([("channel:" + $channel_raw)] + $tickets),
      raw_metadata: {
        channel: $channel_raw,
        channel_display: $channel_display,
        is_dm: $is_dm,
        message_count: (. | length),
        time_span_hours: $span
      }
    }
  )
')

# Cap total Slack hours at 1.0h — scale down proportionally
MAX_SLACK_HOURS=1.0
echo "$ENTRIES" | jq --argjson cap "$MAX_SLACK_HOURS" '
  (map(.estimated_hours) | add // 0) as $total |
  if $total > $cap then
    ($cap / $total) as $scale |
    map(.estimated_hours = ((.estimated_hours * $scale * 100 | round) / 100))
  else
    .
  end
'
