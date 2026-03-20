# Data Model: Billable Worklog Generator Skill

## Entities

### WorklogEntry (JSON intermediate)

Produced by each data source script/tool, consumed by the skill for aggregation.

```json
{
  "id": "string",              // Unique identifier (e.g., "slack-msg-12345", "gh-commit-abc123")
  "source": "string",          // One of: "slack", "notion", "gmail", "calendar", "jira", "github"
  "project": "string",         // Derived project name (repo name, Jira project key, channel name, etc.)
  "description": "string",     // Human-readable activity description
  "estimated_hours": "number", // Estimated hours worked (from heuristic)
  "timestamp": "string",       // ISO 8601 timestamp of the activity
  "correlation_keys": [        // Keys for cross-source matching
    "string"                   // e.g., "PROJ-123", "repo:my-app", "channel:proj-alpha"
  ],
  "raw_metadata": {}           // Source-specific data used for estimation (diff stats, duration, etc.)
}
```

**Fields**:
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | string | yes | Source-prefixed unique ID |
| source | enum | yes | Data source identifier |
| project | string | yes | Project name (derived from source context) |
| description | string | yes | What the user did |
| estimated_hours | number | yes | Hours estimate from heuristic |
| timestamp | string | yes | When the activity occurred (ISO 8601) |
| correlation_keys | string[] | no | Identifiers for cross-source matching |
| raw_metadata | object | no | Source-specific raw data |

### MergedEntry (post-correlation)

After cross-source correlation, related entries are merged.

```json
{
  "project": "string",
  "description": "string",        // Best/most descriptive from merged entries
  "sources": ["string"],          // All contributing sources
  "estimated_hours": "number",    // Highest estimate from merged entries (no double-counting)
  "entries": ["WorklogEntry"]     // Original entries that were merged
}
```

### ProjectGroup (output structure)

```json
{
  "name": "string",                // Project name
  "entries": ["MergedEntry"],      // All entries for this project
  "total_hours": "number"          // Sum of estimated_hours for the project
}
```

### WorklogOutput (final)

```json
{
  "date": "string",                // YYYY-MM-DD
  "projects": ["ProjectGroup"],    // Grouped by project
  "grand_total_hours": "number",   // Sum across all projects
  "skipped_sources": ["string"],   // Sources that failed/were unavailable
  "warnings": ["string"]           // Any issues encountered
}
```

## State Transitions

WorklogEntry flows through three stages:

```
[Raw JSON from scripts/MCP] → WorklogEntry → MergedEntry → ProjectGroup → Markdown Output
```

1. **Retrieval**: Each script outputs a JSON array of `WorklogEntry` objects.
2. **Correlation**: Entries with matching `correlation_keys` are merged into `MergedEntry` objects. The highest `estimated_hours` is kept; all sources are listed.
3. **Grouping**: `MergedEntry` objects are grouped by `project` into `ProjectGroup` objects.
4. **Formatting**: `ProjectGroup` objects are rendered into the markdown output.

## Validation Rules

- `estimated_hours` must be > 0 and <= 12 (sanity cap for a single activity in a day)
- `source` must be one of the six known sources
- `project` defaults to "Uncategorized" if derivation fails
- `timestamp` must fall within the requested date (midnight to midnight)
- `correlation_keys` are case-insensitive for matching (e.g., "PROJ-123" matches "proj-123")

## Project Name Derivation

| Source | Project derived from |
|--------|---------------------|
| Github | Repository name (e.g., `owner/repo` → `repo`) |
| Jira | Project key (e.g., `PROJ-123` → `PROJ`) |
| Slack | Channel name (e.g., `#proj-alpha` → `proj-alpha`) |
| Gmail | Subject line keyword match or recipient domain |
| Calendar | Event title or organizer |
| Notion | Page parent database/workspace name |
