# Contract: Skill Invocation

The worklog skill is invoked as a Claude Code skill via the `.claude/skills/worklog.md` file.

## Invocation

```
claude skill worklog [DATE]
```

**Parameters**:
- `DATE` (optional): ISO date string `YYYY-MM-DD`. Defaults to today.

## Behavior

1. Validates date parameter (rejects future dates with a warning)
2. Loads `.env` for script credentials
3. Runs bash scripts in parallel for: Slack, Gmail, Calendar, Github
4. Uses MCP tools for: Notion, Jira
5. Collects JSON arrays of `WorklogEntry` from each source
6. Correlates and merges duplicate entries across sources
7. Groups by project, calculates subtotals and grand total
8. Writes output to `worklogs/YYYY-MM-DD.md`

## Script Output Contract

Each bash script in `scripts/` MUST output a JSON array of `WorklogEntry` objects to stdout:

```json
[
  {
    "id": "source-unique-id",
    "source": "slack|gmail|calendar|github",
    "project": "project-name",
    "description": "What happened",
    "estimated_hours": 0.5,
    "timestamp": "2026-03-18T14:30:00Z",
    "correlation_keys": ["PROJ-123", "repo:my-app"],
    "raw_metadata": {}
  }
]
```

**Exit codes**:
- `0`: Success (even if empty array `[]`)
- `1`: Credential error (script writes warning to stderr)
- `2`: API/rate-limit error (script writes warning to stderr)

Scripts MUST NOT write anything to stdout except the JSON array. Diagnostics go to stderr.

## MCP Tool Contract

For Notion and Jira, the skill instructs Claude to:
1. Search for the user's activity on the target date
2. Format results as `WorklogEntry` JSON objects
3. Include these in the aggregation pipeline

## Output File Contract

Output is written to `worklogs/YYYY-MM-DD.md` with this structure:

```markdown
# Worklog: YYYY-MM-DD

## Project: {project_name}
| Description | Source | Est. Hours |
|-------------|--------|------------|
| {description} | {sources} | {hours} |
| **Subtotal** | | **{project_total}** |

[... repeated per project ...]

## Uncategorized
[... entries with no project match ...]

---
**Grand Total: {grand_total} hours**

### Skipped Sources
- {source}: {reason}
```
