# Implementation Plan: Billable Worklog Generator Skill

**Branch**: `001-billable-worklog-skill` | **Date**: 2026-03-19 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-billable-worklog-skill/spec.md`

## Summary

Build a Claude Code skill that retrieves activity data from six sources (Slack, Gmail, Google Calendar, Github via bash scripts; Notion, Jira via MCP tools) for a given date, estimates hours worked, merges duplicates across sources, and produces a project-organized markdown worklog suitable for client invoicing.

## Technical Context

**Language/Version**: Bash 5.x (retrieval scripts), Markdown (skill definition)
**Primary Dependencies**: curl, jq, MCP servers (Notion via `mcp.notion.com`, Jira via `mcp.atlassian.com`), LiteLLM (estimation reasoning)
**Storage**: File-based — JSON intermediates in `/tmp`, final output in `worklogs/YYYY-MM-DD.md`
**Testing**: Manual invocation and end-to-end validation (no automated test suite)
**Target Platform**: macOS (Claude Code CLI environment)
**Project Type**: Claude Code skill + supporting bash scripts
**Performance Goals**: Complete worklog generation in under 60 seconds (SC-001)
**Constraints**: Must handle partial source failures gracefully; Google OAuth uses "installed" app flow (desktop)
**Scale/Scope**: Single user, <10 projects/day, 6 data sources

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

The project constitution is not yet customized (template only). No gates to enforce. Proceeding with standard best practices.

**Post-Phase 1 re-check**: N/A — no constitution constraints defined.

## Project Structure

### Documentation (this feature)

```text
specs/001-billable-worklog-skill/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
└── tasks.md             # Phase 2 output (created by /speckit.tasks)
```

### Source Code (repository root)

```text
.claude/
└── skills/
    └── worklog.md            # The Claude Code skill definition

scripts/
├── fetch-slack.sh            # Slack API retrieval
├── fetch-gmail.sh            # Gmail API retrieval (OAuth2)
├── fetch-calendar.sh         # Google Calendar API retrieval (OAuth2)
├── fetch-github.sh           # Github API retrieval
└── lib/
    └── google-auth.sh        # Shared Google OAuth2 token refresh

worklogs/                     # Generated output directory
└── YYYY-MM-DD.md             # Daily worklog files
```

**Structure Decision**: Single project layout. The skill file lives in `.claude/skills/` (Claude Code convention). Bash scripts live in `scripts/` at the repo root. MCP-based sources (Notion, Jira) are invoked directly by the skill — no scripts needed. A shared `google-auth.sh` handles OAuth2 token refresh for both Gmail and Calendar scripts.

## Complexity Tracking

No constitution violations to justify.
