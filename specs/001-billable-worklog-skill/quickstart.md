# Quickstart: Billable Worklog Generator

## Prerequisites

1. **Claude Code CLI** installed and authenticated
2. **`.env` file** at repo root with:
   - `SLACK_BOT_TOKEN` — Slack user token (`xoxp-*`) with `search:read` scope
   - `SLACK_USER_EMAIL` — Your Slack email for filtering
   - `GOOGLE_OAUTH_CREDENTIALS` — Path to Google OAuth2 `credentials.json`
   - `GITHUB_PERSONAL_ACCESS_TOKEN` — Github PAT with `repo` and `read:user` scopes
   - `GITHUB_USERNAME` — Your Github username
   - `LITELLM_URL`, `LITELLM_API_KEY`, `LITELLM_MODEL` — (Optional) LiteLLM for estimation refinement
3. **`.mcp.json`** configured with Notion and Jira MCP servers (pre-configured in this repo)
4. **Google OAuth consent**: On first run, the Gmail/Calendar scripts will prompt you to authorize via browser. The refresh token is saved to `token.json` for subsequent runs.

## Usage

```bash
# Generate worklog for today
claude skill worklog

# Generate worklog for a specific date
claude skill worklog 2026-03-18
```

## Output

The skill produces a markdown file at `worklogs/YYYY-MM-DD.md`:

```markdown
# Worklog: 2026-03-18

## Project: my-app
| Description | Source | Est. Hours |
|-------------|--------|------------|
| Implemented auth flow (PR #42) | Github, Jira | 2.0 |
| Code review discussion | Slack | 0.5 |
| **Subtotal** | | **2.5** |

## Project: client-portal
| Description | Source | Est. Hours |
|-------------|--------|------------|
| Sprint planning meeting | Calendar | 1.0 |
| Updated requirements doc | Notion | 0.5 |
| **Subtotal** | | **1.5** |

---
**Grand Total: 4.0 hours**
```

## Reviewing the Output

All activities are included by default — review the worklog and remove non-billable items before invoicing. Each entry shows its source(s) so you can trace back to the original activity.

## Troubleshooting

- **"Source skipped: slack"** — Check `SLACK_BOT_TOKEN` in `.env`
- **"Source skipped: gmail/calendar"** — Run the script manually to re-authorize Google OAuth
- **"No activity found"** — Verify the date has actual activity in at least one source
- **Rate limit errors** — The skill reports which source was rate-limited; re-run after a few minutes
