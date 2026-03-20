#!/usr/bin/env bash
# Fetch Google Calendar events for a given date.
# Outputs JSON array of WorklogEntry objects to stdout.
# Usage: ./fetch-calendar.sh [YYYY-MM-DD]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source Google auth helper
source "$SCRIPT_DIR/lib/google-auth.sh"

DATE="${1:-$(date +%Y-%m-%d)}"

# Get access token
ACCESS_TOKEN=$(get_google_access_token) || exit 1

# Query events for the target date (midnight to midnight in local timezone)
TIME_MIN="${DATE}T00:00:00Z"
TIME_MAX="${DATE}T23:59:59Z"

RESPONSE=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "https://www.googleapis.com/calendar/v3/calendars/primary/events?timeMin=${TIME_MIN}&timeMax=${TIME_MAX}&singleEvents=true&orderBy=startTime&maxResults=50")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" == "429" ]]; then
  echo "ERROR: Google Calendar API rate limited" >&2
  exit 2
fi
if [[ "$HTTP_CODE" == "401" || "$HTTP_CODE" == "403" ]]; then
  echo "ERROR: Calendar authentication failed (HTTP $HTTP_CODE) — re-run to re-authorize Google OAuth" >&2
  exit 1
fi
if [[ "$HTTP_CODE" != "200" ]]; then
  echo "ERROR: Google Calendar API returned HTTP $HTTP_CODE" >&2
  exit 2
fi

# Emit all non-cancelled event time blocks to stderr as scheduling metadata
# This includes Lunch/OOO so the skill knows which slots are occupied by meetings
echo "$BODY" | jq --arg date "$DATE" '[
  .items // [] | .[] |
  select(.status != "cancelled") |
  select(.start.dateTime != null and .end.dateTime != null) |
  {
    summary: (.summary // ""),
    start: .start.dateTime,
    end: .end.dateTime,
    skipped: ((.summary // "" | ascii_downcase | test("^(lunch|out of office)$")))
  }
]' >&2

# Parse events into WorklogEntry objects (excluding Lunch/OOO)
echo "$BODY" | jq --arg date "$DATE" '[
  .items // [] | .[] |
  select(.status != "cancelled") |
  # Skip placeholder events (Lunch, Out of Office) — these are focus-time blocks, not billable work
  select((.summary // "" | ascii_downcase | test("^(lunch|out of office)$")) | not) |
  # Calculate duration in hours
  (
    if .start.dateTime and .end.dateTime then
      ((.end.dateTime | fromdateiso8601) - (.start.dateTime | fromdateiso8601)) / 3600
    elif .start.date then
      8  # All-day event = 8 hours
    else
      0.5  # Fallback
    end
  ) as $duration |
  # Build attendee list
  ([.attendees // [] | .[] | .email] | join(", ")) as $attendees |
  # Extract Jira ticket IDs from summary
  ((.summary // "") | [match("[A-Z]+-[0-9]+"; "g").string]) as $tickets |
  # Build description with optional attendee suffix
  (
    (.summary // "Untitled event") as $title |
    if ($attendees | length) > 0 then
      $title + " (with: " + ($attendees | if length > 60 then .[:60] + "..." else . end) + ")"
    else
      $title
    end
  ) as $desc |
  {
    id: ("cal-" + .id),
    source: "calendar",
    project: (
      .organizer.displayName //
      (.summary // "Uncategorized" | split(" - ") | first) //
      "Uncategorized"
    ),
    description: $desc,
    estimated_hours: (if $duration > 12 then 12 elif $duration < 0.25 then 0.25 else ($duration * 100 | round / 100) end),
    timestamp: (.start.dateTime // (.start.date + "T09:00:00Z")),
    correlation_keys: ($tickets + [("event:" + .id)]),
    raw_metadata: {
      duration_hours: $duration,
      attendee_count: (.attendees // [] | length),
      organizer: .organizer.email
    }
  }
]'
