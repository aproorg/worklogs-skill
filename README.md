# Worklogs

A Claude Code skill that generates billable worklogs by aggregating activity data from multiple sources, matching entries to billing customers, and optionally logging hours to Jira/Tempo.

## How It Works

Run `/worklog 2026-03-19` in Claude Code. The skill:

1. **Fetches activity** from 6 sources in parallel (Slack, GitHub, Gmail, Google Calendar, Jira, Notion)
2. **Correlates & merges** duplicate entries across sources (e.g., a Jira ticket discussed in Slack and committed in GitHub becomes one line item)
3. **Matches customers** using a Jira-backed cache + learned routing rules
4. **Estimates hours** per entry (calendar duration, commit size, message spans) with optional LiteLLM refinement
5. **Generates a markdown worklog** at `worklogs/YYYY-MM-DD.md`, organized by customer
6. **Creates Jira tickets** for untracked work and **logs hours to Tempo** with calendar-aware scheduling

### Sample Output

```
# Worklog: 2026-03-19

## Customer: Apró
| Description                          | Source   | Est. Hours | Jira Key   |
|--------------------------------------|----------|------------|------------|
| vitinn-pharos: 7 PRs (#157-162, #166)| github   | 3.00       | GENAI-1093 |
| Tech Day presentation + Happy Hour   | calendar | 3.00       | APRO-7     |
| Internal Slack communications        | slack    | 1.00       | APRO-7     |
| **Subtotal**                         |          | **7.00**   |            |

---
**Grand Total: 10.00 hours**
```

## Architecture

```
/worklog YYYY-MM-DD
    │
    ├── scripts/fetch-slack.sh ─────┐
    ├── scripts/fetch-github.sh ────┤
    ├── scripts/fetch-gmail.sh ─────┤  JSON arrays of WorklogEntry
    ├── scripts/fetch-calendar.sh ──┤  (run in parallel)
    ├── scripts/fetch-jira.sh ──────┘
    │
    ├── Notion MCP (mcp.notion.com) ── search for edited pages
    │
    ├── scripts/match-customer.sh ──── customer matching & routing rules
    ├── scripts/build-customer-cache.sh ── Jira → customer index
    │
    ├── Claude Code ── merging, estimation, markdown generation
    │
    ├── scripts/create-jira-ticket.sh ── ticket creation for untracked work
    ├── scripts/resolve-tempo-account.sh ── Tempo account resolution
    └── scripts/log-tempo.sh ─────── hour logging to Tempo
```

**Bash scripts** handle all API calls (Slack, GitHub, Gmail, Calendar, Jira, Tempo) and output structured JSON. **MCP servers** provide authenticated access to Notion. **Claude Code** orchestrates everything — the skill definition (`.claude/commands/worklog.md`) is the "runtime" that ties scripts and MCP tools together.

## Setup

### 1. Clone & configure credentials

```bash
cp .env.example .env  # then fill in values
```

Required in `.env`:

| Variable | Purpose |
|----------|---------|
| `SLACK_BOT_TOKEN` | Slack user token (xoxp-...) |
| `SLACK_USER_EMAIL` | Your Slack email |
| `GOOGLE_OAUTH_CREDENTIALS` | Path to Google OAuth credentials JSON |
| `GITHUB_PERSONAL_ACCESS_TOKEN` | GitHub PAT |
| `GITHUB_USERNAME` | Your GitHub username |

Optional (skip source if missing):

| Variable | Purpose |
|----------|---------|
| `JIRA_BASE_URL` | Jira instance URL |
| `JIRA_USER_EMAIL` | Jira email |
| `JIRA_TOKEN` | Jira API token |
| `TEMPO_TOKEN` | Tempo API token (for hour logging) |
| `LITELLM_URL` | LiteLLM endpoint (for estimation refinement) |
| `LITELLM_API_KEY` | LiteLLM API key |
| `LITELLM_MODEL` | LiteLLM model name |

### 2. Google OAuth

The Gmail and Calendar scripts use OAuth2. On first run, you'll be prompted to authorize via browser. The token is cached in `token.json`.

### 3. MCP Servers

Notion access is configured in `.mcp.json` (OAuth2 3LO via `mcp.notion.com`). Claude Code handles the auth flow automatically.

### 4. Dependencies

- **bash 5.x**, **curl**, **jq** (for scripts)
- **Claude Code** (the skill runtime)

## Usage

```bash
# Generate worklog for a specific date
/worklog 2026-03-19

# Generate worklog for today
/worklog
```

The skill will:
- Fetch and merge activity from all configured sources
- Ask you to assign customers for unmatched entries (learned for future runs)
- Generate `worklogs/YYYY-MM-DD.md`
- Offer to create Jira tickets for entries without them
- Offer to log approved hours to Tempo

### Customer Matching

The system learns customer assignments over time:

- **Jira cache**: Auto-built from tickets with the "Customer Gen AI" field
- **Routing rules**: Persistent rules for internal meetings, Slack channels, etc.
- **User mappings**: Learned from your answers when asked "which customer?"

Manage routing rules:
```bash
bash scripts/save-routing-rule.sh --list
bash scripts/save-routing-rule.sh --pattern "calendar:internal" --jira-key "APRO-7" --customer "Apró"
bash scripts/save-routing-rule.sh --delete "calendar:internal"
```

## Project Structure

```
.claude/commands/worklog.md   # Skill definition (the orchestration logic)
scripts/
  fetch-slack.sh              # Slack message retrieval
  fetch-github.sh             # GitHub PR/commit retrieval
  fetch-gmail.sh              # Gmail thread retrieval
  fetch-calendar.sh           # Google Calendar event retrieval
  fetch-jira.sh               # Jira issue retrieval
  build-customer-cache.sh     # Jira → customer index builder
  match-customer.sh           # Customer matching engine
  save-customer-mapping.sh    # Persist user-learned mappings
  save-routing-rule.sh        # Manage routing rules
  create-jira-ticket.sh       # Create Jira tickets
  resolve-tempo-account.sh    # Resolve Tempo billing accounts
  log-tempo.sh                # Log hours to Tempo
  lib/google-auth.sh          # Google OAuth2 helper
worklogs/
  YYYY-MM-DD.md               # Generated worklogs
  .customer-cache.json         # Cached customer index
  .account-mappings.json       # Tempo account mappings
specs/                         # Feature specifications
```
