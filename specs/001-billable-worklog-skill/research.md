# Research: Billable Worklog Generator Skill

## 1. Google OAuth2 "Installed App" Flow for Gmail & Calendar

**Decision**: Use the `credentials.json` (installed app type) with offline refresh tokens. Store the refresh token in `.env` or a `token.json` file after initial browser-based consent.

**Rationale**: The existing `credentials.json` uses the "installed" client type, which is designed for desktop/CLI apps. The standard flow is: (1) first run opens a browser for consent, (2) stores a refresh token locally, (3) subsequent runs exchange the refresh token for short-lived access tokens via `curl` to `https://oauth2.googleapis.com/token`.

**Alternatives considered**:
- Service account: Would require Google Workspace admin setup, overkill for single-user.
- API key: Not supported for Gmail/Calendar user data.

## 2. Slack API — User Activity Retrieval

**Decision**: Use Slack Web API with a user token (`xoxp-*`) to search messages authored by the user on a given date.

**Rationale**: The `search.messages` endpoint with `from:<user>` and `after:<date> before:<next_date>` filters returns all user messages. The user token (vs bot token) is required for `search.messages`. Channel names in results provide project context.

**Alternatives considered**:
- `conversations.history` per channel: Requires listing all channels first, much slower, rate-limit heavy.
- Slack export: Requires admin access, not suitable for real-time daily use.

## 3. Github API — Commit and PR Activity

**Decision**: Use Github REST API with personal access token to query events and commits for the user on a given date.

**Rationale**: The `/users/{username}/events` endpoint returns push events, PR events, and issue events for a given day. For commit detail (diff size), follow up with `/repos/{owner}/{repo}/commits/{sha}` to get `stats.additions` and `stats.deletions` for hour estimation.

**Alternatives considered**:
- GraphQL API: More flexible but adds complexity; REST is sufficient for daily granularity.
- `gh` CLI: Would work but adds a dependency; raw `curl` is more portable.

## 4. Gmail API — Sent Emails as Work Signals

**Decision**: Use Gmail API to list messages sent by the user on the target date, extracting subject lines and recipients as work activity signals.

**Rationale**: Sent emails indicate active work communication. The `users.messages.list` endpoint with query `from:me after:YYYY/MM/DD before:YYYY/MM/DD+1` returns message IDs, then `users.messages.get` retrieves subjects and metadata.

**Alternatives considered**:
- IMAP: More complex auth setup, no advantage over REST API.
- Full body parsing: Overkill; subject + recipient + timestamp is sufficient for worklog context.

## 5. Google Calendar — Meeting Duration

**Decision**: Use Google Calendar API to list events for the target date, extracting title, duration, and attendees.

**Rationale**: `events.list` with `timeMin` and `timeMax` parameters returns all events. Duration is directly available from `start`/`end` fields — the most reliable time estimate of any source.

**Alternatives considered**:
- Only count accepted events: Spec says include all activities for user review, so include all.

## 6. Cross-Source Correlation Strategy

**Decision**: Use keyword-based matching to correlate activities across sources. Match on: Jira ticket IDs (e.g., `PROJ-123`), Github repo names, and overlapping time windows.

**Rationale**: Jira ticket IDs are the strongest correlation signal — they appear in commit messages, Slack threads, and Jira itself. Github repo names map to project names. Time-window overlap (e.g., Slack messages during a calendar meeting) provides a secondary signal. When correlated, merge into a single entry with the longest time estimate and list all sources.

**Alternatives considered**:
- LLM-based semantic matching: Too slow and expensive for a 60-second budget; keyword matching is deterministic and fast.
- No correlation: Leads to >10% hour over-counting (violates SC-006).

## 7. Hour Estimation Heuristics

**Decision**: Use source-specific heuristics, with LiteLLM as an optional refinement pass.

**Rationale**: Each source has natural time signals:
- **Calendar**: Use event duration directly.
- **Github commits**: Base estimate on diff size — e.g., <20 lines → 0.25h, 20-100 lines → 0.5h, 100-300 → 1h, 300+ → 2h.
- **Slack**: Compute time span of conversation thread on a topic; estimate 50% of span as active work.
- **Gmail**: 0.25h per sent email (conservative estimate for composition time).
- **Jira**: Use status transition timestamps if available; otherwise 0.5h per ticket interaction.
- **Notion**: 0.5h per page edit (heuristic; Notion API doesn't expose edit duration).

LiteLLM can optionally refine estimates by reasoning about the combined context, but the heuristic pass ensures the 60-second budget is met even without LLM calls.

**Alternatives considered**:
- Pure LLM estimation: Too slow for 60s target; heuristics are a reliable baseline.
- User-configured rates: Adds setup friction; heuristics + user review is simpler.

## 8. MCP Tool Usage for Notion & Jira

**Decision**: The Claude Code skill will directly invoke MCP tools (Notion search/fetch, Jira issue search) within the skill's prompt instructions. No bash scripts needed for these sources.

**Rationale**: MCP servers are already configured in `.mcp.json` with OAuth2 3LO. The skill markdown can instruct Claude to use Notion's `notion-search` and Jira's tools to find the user's activity for the target date. This avoids duplicating auth logic in bash.

**Alternatives considered**:
- Bash scripts with Notion/Jira REST APIs: Would require managing OAuth tokens separately, defeating the purpose of MCP.

## 9. Output Format

**Decision**: Markdown file with project headings, tables (Description | Source | Est. Hours), project subtotals, and a grand total.

**Rationale**: Markdown is human-readable, version-controllable, and easily copied into invoicing tools. Table format matches the spec requirements (FR-004, FR-008, FR-009).

**Alternatives considered**:
- JSON output: Less readable for direct invoicing use.
- CSV: Loses project grouping structure.
