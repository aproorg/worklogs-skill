---
description: Generate a billable worklog by retrieving activity data from multiple sources (Slack, Github, Gmail, Calendar, Notion, Jira), estimating hours, merging duplicates, matching to billing customers, producing a project-organized markdown file, and optionally creating Jira tickets and logging hours to Tempo.
---

## User Input

```text
$ARGUMENTS
```

The input above is the target date in `YYYY-MM-DD` format (optional — defaults to today if empty or blank).

## Step 1: Validate Input

1. If a date was provided, validate it matches `YYYY-MM-DD` format.
2. If the date is in the future, create `worklogs/YYYY-MM-DD.md` with:
   ```
   # Worklog: YYYY-MM-DD
   No activity data available — date is in the future.
   ```
   Then stop.
3. Set `DATE` to the validated date (or today if none provided).

## Step 2: Check Credentials

Load `.env` from the repo root. Verify these required keys exist:
- `SLACK_BOT_TOKEN`
- `SLACK_USER_EMAIL`
- `GOOGLE_OAUTH_CREDENTIALS`
- `GITHUB_PERSONAL_ACCESS_TOKEN`
- `GITHUB_USERNAME`

If any are missing, report which credentials are missing and stop with an error. Do NOT proceed with partial credentials — the user needs to fix `.env` first.

Optional keys (skip source if missing, don't error):
- `JIRA_BASE_URL`, `JIRA_USER_EMAIL`, `JIRA_TOKEN` (all three needed for Jira)
- `TEMPO_TOKEN` (needed for Tempo logging in Step 12)
- `LITELLM_URL`, `LITELLM_API_KEY`, `LITELLM_MODEL`

## Step 3: Build Customer Cache

Run the customer cache builder to ensure we have an up-to-date customer index from Jira:

```bash
bash scripts/build-customer-cache.sh
```

This script:
- Queries Jira for tickets with the "Customer Gen AI (migrated)" field set (last 90 days)
- Builds a mapping of `issue_key → customer` and `user_mappings` (learned from previous runs)
- Caches to `worklogs/.customer-cache.json` (refreshes if >24h old)
- Preserves user-learned mappings across rebuilds

If Jira credentials are missing, skip this step. Entries won't have customer data but the worklog will still be generated.

## Step 4: Retrieve Activity Data

Run all 5 bash scripts **in parallel**, capturing stdout (JSON) and stderr (diagnostics) separately:

```bash
bash scripts/fetch-slack.sh $DATE
bash scripts/fetch-github.sh $DATE
bash scripts/fetch-gmail.sh $DATE
bash scripts/fetch-calendar.sh $DATE
bash scripts/fetch-jira.sh $DATE
```

For each script:
- Exit code 0: Parse stdout as JSON array of WorklogEntry objects.
- Exit code 1: Record source as skipped (credential error). Note the stderr message.
- Exit code 2: Record source as skipped (API error). Note the stderr message.

**Do not stop on individual script failures** — continue with successful sources and record failed ones in `skipped_sources`.

**Calendar filtering**: The calendar script automatically skips "Lunch" and "Out of Office" events — these are focus-time blocks used for coding work, not billable meetings. They are excluded from the worklog but their time slots are used for scheduling GitHub entries in Tempo (see Step 12).

**Calendar schedule metadata**: The calendar script emits a JSON array of **all** event time blocks (including skipped ones) to stderr. Each block has `{summary, start, end, skipped}`. Parse this from stderr and retain it — it is needed in Step 12 to build the day's timeline for Tempo scheduling. The `skipped: true` blocks (Lunch, OOO) represent available coding time; `skipped: false` blocks are real meetings that occupy time slots.

## Step 5: Retrieve Notion Activity (MCP)

Use the Notion MCP tool to find pages the user created or edited on the target date:

1. First, resolve the user's Notion ID by calling `notion-get-users` with `user_id: "self"`. Cache the returned user ID for the filter.

2. Use `notion-search` with both `created_date_range` and `created_by_user_ids` filters to find pages **the user created** on the target date:
   ```json
   {
     "query": " ",
     "filters": {
       "created_date_range": {
         "start_date": "YYYY-MM-DD",
         "end_date": "YYYY-MM-DD+1"
       },
       "created_by_user_ids": ["<user-id-from-step-above>"]
     },
     "page_size": 25
   }
   ```
   Where `end_date` is the day after the target date (the range is exclusive on the end).
   **Important**: The `query` field must be a non-empty string (use a single space `" "`) — empty strings are rejected by the API. Do NOT put the date string in the `query` field — that performs a text search, not a date filter.

2. For each result:
   - Set `source` = "notion"
   - Set `project` = parent database name or workspace name
   - Set `description` = "Edited: " + page title
   - Set `estimated_hours` = 0.5 per page edit
   - Set `timestamp` = page last_edited_time
   - Add correlation keys from page title (extract Jira ticket IDs if present)
3. Format as WorklogEntry JSON objects.

**Limitation**: The Notion search API only supports filtering by `created_date_range`, not by last-edited date. Pages that were edited (but not created) on the target date will not be found. This is a known gap.

If Notion MCP is not configured or returns an error, record "notion" in skipped_sources and continue.

## Step 6: Cross-Source Correlation and Merging

Combine all WorklogEntry arrays from Steps 4-5 into a single list, then merge duplicates:

**Matching rules** (case-insensitive):
1. **Jira ticket ID match**: Entries sharing a Jira ticket ID (e.g., "PROJ-123") in correlation_keys are related.
2. **Repo name match**: Entries sharing a "repo:name" correlation key are related.
3. **Time-window overlap**: Slack messages timestamped during a calendar event window likely relate to that meeting.

**Merge rules**:
- **Calendar entries are never merged with each other.** Each calendar event must remain a separate line item in the final report. Calendar entries may still be correlated with non-calendar entries (e.g., a Slack conversation during a meeting window), but two calendar events must never collapse into one row.
- When entries match, create a MergedEntry:
  - `project`: Use the most specific project name (Jira project key > repo name > channel name > domain)
  - `description`: Use the most descriptive entry (longest meaningful description)
  - `sources`: List all contributing source types (e.g., ["github", "jira", "slack"])
  - `estimated_hours`: Use the **highest** single estimate among merged entries (no summing — this prevents double-counting)
  - `entries`: Keep references to all original entries

- Entries with no matches remain as standalone MergedEntries.
- **Note**: Internal Slack DMs are NOT merged here — they are consolidated later in Step 7 after routing rules identify them as internal (see "Post-routing consolidation").

## Step 7: Customer Matching

For each MergedEntry, determine the billing customer **and optionally a fixed Jira key** using the customer cache. The `match-customer.sh` script now returns JSON: `{"customer": "Name", "jira_key": "PROJ-123"}`. A non-empty `jira_key` means this entry has a pre-assigned ticket and should skip ticket creation in Step 12.

### Matching priority:
0. **Routing rules** (highest priority): Call `bash scripts/match-customer.sh --source-type "calendar:internal"` or `--source-type "slack:internal"` for internal meetings and Slack messages. Routing rules return both a customer AND a fixed Jira key.
   - **Internal meetings**: Calendar events where all attendees share the same domain (e.g., `@apro.is`) or have no external participants.
   - **Internal Slack**: DMs, internal channels (no external guests), or messages not related to a specific customer project.
1. **Jira entries**: Already have customer from `raw_metadata.customer_name` (set by fetch-jira.sh via `customfield_12513`). Use directly.
2. **Jira key in correlation_keys**: Run `bash scripts/match-customer.sh --jira-key "GENAI-123"` — returns `{"customer": "Name", "jira_key": ""}`.
3. **Repo name**: Run `bash scripts/match-customer.sh --repo "repo-name"` — checks routing rules, then user mappings.
4. **Slack channel**: Run `bash scripts/match-customer.sh --slack-channel "#channel-name"` — checks routing rules, then user mappings.
5. **Keyword**: Run `bash scripts/match-customer.sh --keyword "some-keyword"` — fuzzy-match against customer names, labels, and components.

### For unmatched entries:
When an entry has no customer match, present the user with a prompt:

> **Which customer does this belong to?**
> Entry: {description} (source: {sources})
> Available customers: {list from cache}
> Options: [customer name] / "skip" / "new: CustomerName"

Based on the user's answer:
- If a customer name: assign it and save the mapping with `bash scripts/save-customer-mapping.sh --key "repo:X" --customer "Name"` (using the most useful correlation key as the mapping key)
- If "skip": leave the entry in Uncategorized
- If "new: Name": use that customer name and save the mapping

**Important**: Group similar unmatched entries together. If 3 GitHub PRs all come from the same repo, ask once for the repo, not three times.

Set each MergedEntry's `customer` field. If the match returned a `jira_key`, set the entry's `jira_key` field — this will appear in the Jira Key column and be used for Tempo logging without needing ticket creation.

### Post-routing consolidation:

After all entries have been matched, **merge entries that share the same routed `jira_key` from routing rules and come from the same source type**. This prevents internal chats from appearing as separate line items.

Specifically:
1. Group all entries where `jira_key` was assigned by a routing rule (not from correlation_keys) and `source` is the same (e.g., all `slack` entries routed to `APRO-7`).
2. For each such group, **always** collapse them into a single MergedEntry (even if only one entry exists):
   - `description`: "Internal comms" (a single generic label — do not list individual names or channels)
   - `sources`: deduplicated union of all source types
   - `estimated_hours`: sum of all individual estimates, **capped at 1.0h maximum**. Internal Slack communication is overhead, not primary billable work — never log more than 1h regardless of volume.
   - `jira_key`: the shared routed key (e.g., `APRO-7`)
   - `customer`: the shared customer
3. This consolidation applies to any source type routed by rules (Slack DMs, internal calendar events, etc.), but **calendar entries are still never merged with each other** per the existing rule in Step 6.

**Example**: Three internal Slack DMs (with Halldór, Páll, and Guðmundur) each routed to APRO-7 become a single entry:
| Internal comms | slack | 1.00 | APRO-7 |

### Managing routing rules:
Routing rules persist in the customer cache and survive rebuilds. To manage them:
```bash
# Add a rule
bash scripts/save-routing-rule.sh --pattern "calendar:internal" --jira-key "APRO-7" --customer "Apró"
# List all rules
bash scripts/save-routing-rule.sh --list
# Delete a rule
bash scripts/save-routing-rule.sh --delete "calendar:internal"
```

## Step 8: Project Grouping

Group all MergedEntries by `customer` (or `project` if no customer):
- Normalize project names: strip prefixes, lowercase comparison, merge obvious variants (e.g., "my-app" and "my_app")
- Calculate `total_hours` per project = sum of all entry `estimated_hours` in that project
- Entries where customer/project = "Uncategorized" or empty go under an "Uncategorized" section

## Step 9: LiteLLM Estimation Refinement (Optional)

If `LITELLM_URL` and `LITELLM_API_KEY` are set in `.env`:

1. Send all grouped entries to LiteLLM with this prompt:
   > Review these worklog entries and their hour estimates. Adjust any estimates that seem unreasonable based on the activity type, description, and context. Return the same structure with adjusted estimated_hours values. Keep adjustments modest — the heuristic estimates are a reasonable baseline.

2. Replace estimated_hours with LiteLLM's refined values.
3. Recalculate project subtotals and grand total.

If LiteLLM credentials are not configured, skip this step — heuristic estimates are the final values.

## Step 10: Generate Markdown Output

Create the output file at `worklogs/YYYY-MM-DD.md` with this structure:

```markdown
# Worklog: YYYY-MM-DD

## Customer: {customer_name}
| Description | Source | Est. Hours | Jira Key |
|-------------|--------|------------|----------|
| {description} | {comma-separated sources} | {hours} | {jira_key or ""} |
| **Subtotal** | | **{project_total}** | |

[... repeated for each customer, sorted by total_hours descending ...]

## Uncategorized
| Description | Source | Est. Hours | Jira Key |
|-------------|--------|------------|----------|
| {description} | {sources} | {hours} | {jira_key or ""} |
| **Subtotal** | | **{subtotal}** | |

---
**Grand Total: {grand_total} hours**

### Skipped Sources
- {source}: {reason from stderr}
```

**Formatting rules**:
- Round all hours to 2 decimal places
- Sort customers by total hours (descending)
- The "Jira Key" column contains the Jira issue key (e.g., "PROJ-123") if the entry has one in its correlation_keys — this is used by Step 12 for Tempo logging
- If no entries exist for any source, output: "No billable activity found for YYYY-MM-DD."
- Always include the Skipped Sources section if any sources were skipped
- Omit the Uncategorized section if there are no uncategorized entries
- Omit the Skipped Sources section if all sources succeeded

## Step 11: Report Summary

After writing the file, report to the user:
- File path: `worklogs/YYYY-MM-DD.md`
- Number of customers found
- Grand total hours
- Any skipped sources
- Entries without Jira keys (candidates for ticket creation)
- Reminder: "Review the worklog and adjust estimates before proceeding."

## Step 12: Create Missing Jira Tickets & Log to Tempo

After the user has reviewed and approved the worklog, execute Phase 1 and Phase 2 **in order**. Do NOT skip Phase 1.

### Phase 1: Create Jira Tickets for Untracked Work (MANDATORY before Phase 2)

**You MUST check for entries without Jira keys before proceeding to Phase 2.** Scan the worklog for entries that have a customer but an empty Jira Key column. If any exist, you MUST present them to the user before showing the Tempo logging prompt.

1. Scan the worklog markdown for all entries where the Jira Key column is empty but the customer is set (not "Uncategorized").
2. If there are zero such entries, proceed directly to Phase 2.
3. If there are entries missing Jira keys, present them grouped by customer:
   ```
   These entries have no Jira ticket and cannot be logged to Tempo without one:

   **Apró**:
   - vitinn-pharos: 7 PRs (#157-162, #166) — 3.00h (github)
   - vitinn-infra: PR #281 — 0.50h (github)

   Would you like to create Jira tickets for these? [yes / skip]
   If skipped, these entries will be excluded from Tempo logging.
   ```
4. If confirmed, for each entry, first resolve the Tempo account. If the entry has a repo name (from GitHub source), pass it with `--repo` for repo-specific account resolution:
   ```bash
   # For entries with a repo name (GitHub-sourced):
   bash scripts/resolve-tempo-account.sh --customer "{customer_name}" --repo "{repo_name}"
   # For entries without a repo name:
   bash scripts/resolve-tempo-account.sh --customer "{customer_name}"
   ```
   The script checks repo-based mappings first (e.g., `vitinn-infra` → account 154), then falls back to customer-level mappings. Repo mappings are stored in `worklogs/.account-mappings.json` with `repo:` prefixed keys.
   - If the result has `"matched": true`, use the returned `account_id`.
   - If `"matched": false`, present the user with the list of candidates from the result and ask them to pick the correct Tempo account. Once they choose, save the mapping:
     ```bash
     # Save repo-level mapping (preferred for GitHub entries):
     bash scripts/resolve-tempo-account.sh --save --repo "{repo_name}" --account-id {chosen_id}
     # Or save customer-level mapping (fallback for non-GitHub entries):
     bash scripts/resolve-tempo-account.sh --save --customer "{customer_name}" --account-id {chosen_id}
     ```
   Then create the ticket with the account:
   ```bash
   bash scripts/create-jira-ticket.sh \
     --project "GENAI" \
     --summary "{entry description}" \
     --customer "{customer_name}" \
     --account-id "{account_id}" \
     --description "Auto-created from worklog {DATE}. Source: {sources}"
   ```
5. Update the worklog markdown with the newly created Jira keys.
6. **Only after Phase 1 is resolved** (tickets created or user chose to skip), proceed to Phase 2.

**Important**: Use the Jira project from the customer cache (default: "GENAI" if all customers share one project). The `--customer` flag sets the `customfield_12513` (Customer Gen AI) field. The `--account-id` flag sets the `customfield_11530` (Account) field — this is the Tempo account used for billing.

### Phase 2: Log Hours to Tempo

**Only proceed after Phase 1 is complete**, and only if:
1. `TEMPO_TOKEN` is set in `.env`
2. `JIRA_BASE_URL`, `JIRA_USER_EMAIL`, and `JIRA_TOKEN` are set in `.env`
3. The user explicitly confirms they want to log to Tempo

**Process**:
1. Parse the worklog markdown to extract entries that have a Jira Key.
2. Present a **numbered list** of all loggable entries for the user to review and approve:

   ```
   Entries to log to Tempo for YYYY-MM-DD:

   1. [PROJ-123] Description here — 1.50h
   2. [PROJ-456] Another entry — 0.50h
   3. [PROJ-789] Third entry — 2.00h
   ...
   Total: X.XXh

   Reply with which items to log and any hour adjustments. Examples:
   - "all" — log everything as-is
   - "1,2,3" or "1-3" — log only those items
   - "all but 3" — log everything except item 3
   - "3 = 1.0" — adjust item 3 to 1.0h (spaces around = are fine)
   - "all but 2, 5 = 0.5" — skip item 2, adjust item 5 to 0.5h
   - "none" or "cancel" — skip Tempo logging
   ```

3. Parse the user's response using **natural language interpretation** — do not require strict syntax. Understand the user's intent:
   - **"all"**: Log all entries with their listed hours.
   - **Item selection**: Numbers, ranges ("1-3"), comma-separated ("1,2,3"), or exclusions ("all but 2", "all except 3,5").
   - **Hour edits**: Any pattern like "N = X", "N=X", "item N: Xh", or "set N to X" adjusts that item's hours.
   - **Combinations**: The user may combine selection and edits in any natural phrasing, e.g. "all but 2, 3 = 1.0" or "log 1-5 except 3, and change 4 to 0.5h".
   - **"none"**, **"cancel"**, **"skip"**: Skip Tempo logging entirely.

4. Build a JSON array of the approved entries (with any adjusted hours), distributing `start_time` values throughout the day using calendar-aware scheduling:

   **Scheduling algorithm**:

   The scheduler maintains an **occupied timeline** — a sorted list of `[start, end)` intervals representing time already claimed. Every placed entry adds an interval. No two entries may overlap.

   1. **Derive the working window from actual activity** — do NOT assume 09:00-18:00. Collect all timestamps from every entry (GitHub commits, calendar events, Slack messages, etc.) and use the earliest and latest as the day's bounds. Round the earliest down and latest up to the nearest hour. For example, if the earliest commit is at 06:47 and the last Slack message is at 23:12, the window is 06:00-24:00.

   2. **Phase 1 — Place calendar entries first** (fixed-time, highest priority):
      - For each calendar-sourced entry, place it at its actual meeting start time.
      - Add the interval `[meeting_start, meeting_start + hours]` to the occupied timeline.

   3. **Phase 2 — Place GitHub entries by commit timestamp** (preferred-time, medium priority):
      - Sort GitHub entries by their commit timestamp (earliest first).
      - For each entry, compute preferred start = commit time rounded down to nearest half-hour.
      - Call `find_slot(preferred_start, duration)` (see below) to get a non-overlapping start time.
      - Add the interval `[start, start + hours]` to the occupied timeline.

   4. **Phase 3 — Place remaining entries sequentially** (flexible-time, fill gaps):
      - For all non-calendar, non-GitHub entries (Slack, Jira, Notion, etc.), sort by timestamp if available, otherwise by hours descending (place larger entries first for better packing).
      - For each entry, call `find_slot(window_start, duration)` to find the earliest available gap.
      - Add the interval `[start, start + hours]` to the occupied timeline.

   5. **Format** all `start_time` values as `HH:MM:SS`.

   **`find_slot(preferred_start, duration)` algorithm**:
   - Starting from `preferred_start`, scan the occupied timeline for a gap where `gap_length >= duration`.
   - A gap exists between consecutive occupied intervals (or between `preferred_start` and the first interval, or after the last interval until `window_end`).
   - Return the start of the first gap that fits. If `preferred_start` itself falls inside an occupied interval, jump to that interval's end and continue scanning.
   - If no gap fits before `window_end`, extend the window and place at the end (this handles days with >24h of logged work gracefully).
   - Round the returned start time down to the nearest minute (avoid sub-minute precision).

   **Example**: Day has commits at 07:15 (1.5h), 09:42 (2.0h), and a meeting at 10:00-11:00 (1.0h). Working window: 07:00-23:00.
   - Phase 1: Meeting placed at 10:00-11:00. Timeline: `[10:00, 11:00]`.
   - Phase 2: 07:15 commit → preferred 07:00, gap [07:00, 10:00] fits 1.5h → placed at 07:00-08:30. Timeline: `[07:00, 08:30], [10:00, 11:00]`.
   - Phase 2: 09:42 commit → preferred 09:30, gap [08:30, 10:00] = 1.5h, need 2.0h → doesn't fit. Next gap [11:00, 23:00] → placed at 11:00-13:00. Timeline: `[07:00, 08:30], [10:00, 11:00], [11:00, 13:00]`.
   - Phase 3: Remaining entries fill gaps starting from 08:30, then 13:00+.

   ```json
   [
     { "issue_key": "PROJ-123", "description": "Meeting X", "hours": 1.0, "date": "YYYY-MM-DD", "start_time": "10:00:00" },
     { "issue_key": "PROJ-456", "description": "Early morning work", "hours": 1.5, "date": "YYYY-MM-DD", "start_time": "07:00:00" },
     { "issue_key": "PROJ-789", "description": "Code review", "hours": 2.0, "date": "YYYY-MM-DD", "start_time": "11:00:00" },
     ...
   ]
   ```
5. Pipe it to the Tempo logging script:
   ```bash
   echo '$JSON_ARRAY' | bash scripts/log-tempo.sh
   ```
6. Report the results: how many worklogs were created, how many failed, and any error details. If hours were adjusted, note the changes made.

**Important**: Entries without a Jira Key cannot be logged to Tempo — inform the user which entries were skipped and suggest they manually assign Jira tickets if needed.

## Validation Rules

- `estimated_hours` must be >= 0.5 and <= 14 per entry. Clamp outliers (round up entries below 0.5 to 0.5). GitHub entries have a minimum of 1.0h (enforced in fetch-github.sh).
- `source` must be one of: slack, gmail, calendar, github, notion, jira
- `timestamp` must fall within the requested date
- Correlation key matching is case-insensitive
