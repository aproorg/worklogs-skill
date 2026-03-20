# Feature Specification: Billable Worklog Generator Skill

**Feature Branch**: `001-billable-worklog-skill`
**Created**: 2026-03-19
**Status**: Draft
**Input**: User description: "Implement a claude code skills setup that retrieves data from multiple sources to generate my billable worklog for the date requested."

## Clarifications

### Session 2026-03-19

- Q: Should Notion & Jira use MCP tools (via `.mcp.json` OAuth2 3LO) or bash scripts like the other sources? → A: Hybrid — use MCP tools for Notion & Jira; bash scripts for Slack, Gmail, Calendar, Github.
- Q: Should activities be pre-filtered for billability, or include everything for user review? → A: Include all retrieved activities with source labels; user removes non-billable items during review.
- Q: When duplicate/related activities are detected across sources, how should they appear in the output? → A: Merge into a single entry with the best time estimate, listing all contributing sources.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Generate Daily Worklog (Priority: P1)

As a freelancer/consultant, I want to run a single Claude Code skill command with a date and receive a complete billable worklog organized by project, so I don't have to manually piece together what I worked on across multiple tools.

**Why this priority**: This is the core value proposition — transforming scattered activity data into a structured billable output. Without this, the feature has no purpose.

**Independent Test**: Can be fully tested by invoking the skill with a specific date and verifying that a markdown file is produced containing project-organized tables with descriptions and estimated hours.

**Acceptance Scenarios**:

1. **Given** credentials are configured in `.env` and the user has activity data for the requested date, **When** the user invokes the worklog skill with a date (e.g., `2026-03-18`), **Then** a markdown file is generated containing billable entries organized by project in table format.
2. **Given** the user has no activity on the requested date across any data source, **When** the user invokes the skill, **Then** the output clearly states no billable activity was found for that date.
3. **Given** the user invokes the skill without specifying a date, **When** the skill runs, **Then** it defaults to the current date (today).

---

### User Story 2 - Multi-Source Data Retrieval (Priority: P1)

As a user, I want data to be fetched from all configured sources (Slack, Notion, Gmail, Google Calendar, Jira, Github) so that my worklog reflects all channels where I performed work.

**Why this priority**: Equal to P1 because the quality of the worklog depends entirely on comprehensive data retrieval. Each source captures a different facet of work activity.

**Independent Test**: Can be tested by verifying each retrieval script fetches data from its respective source for a given date, and the combined output includes entries from multiple sources.

**Acceptance Scenarios**:

1. **Given** valid credentials for all six data sources, **When** the skill fetches data for a date, **Then** activities from each source are included in the output.
2. **Given** one data source has invalid or missing credentials, **When** the skill runs, **Then** it gracefully skips that source, warns the user, and still produces output from the remaining sources.
3. **Given** a data source returns no activity for the requested date, **When** the skill runs, **Then** that source is omitted from the output (no empty sections).

---

### User Story 3 - Work Effort Estimation (Priority: P2)

As a user, I want the system to estimate hours worked per activity based on available signals (commit size, message timestamps, document edit complexity, meeting duration), so I have a reasonable starting point for my time entries.

**Why this priority**: Estimation adds significant value over a simple activity list, but users will always need to review and adjust estimates. The raw activity list (P1) is useful even without estimation.

**Independent Test**: Can be tested by providing known activity data (e.g., a commit with 50 lines changed, a 30-minute calendar event) and verifying the output includes reasonable hour estimates.

**Acceptance Scenarios**:

1. **Given** a Github commit with a known number of lines changed, **When** the skill processes it, **Then** the estimated hours reflect the complexity (e.g., a 5-line typo fix gets less time than a 200-line feature).
2. **Given** a Google Calendar event with a defined duration, **When** the skill processes it, **Then** the estimated hours match the calendar event duration.
3. **Given** Slack messages spanning a conversation from 10:00 AM to 11:30 AM on a topic, **When** the skill processes them, **Then** the estimated time reflects the conversation span (approximately 1.5 hours).

---

### User Story 4 - Project-Organized Output (Priority: P2)

As a user, I want my worklog grouped by project so I can easily transfer entries to per-client invoices or timesheets.

**Why this priority**: Organizational structure is essential for usability but depends on the data retrieval (P1) being functional first.

**Independent Test**: Can be tested by providing activity data that spans multiple projects and verifying the output groups entries under distinct project headings.

**Acceptance Scenarios**:

1. **Given** activities from multiple projects (e.g., different Jira projects, Github repos, Slack channels), **When** the skill generates the worklog, **Then** entries are grouped under their respective project names.
2. **Given** an activity that cannot be associated with a specific project, **When** the skill processes it, **Then** it appears under an "Uncategorized" section.

---

### Edge Cases

- What happens when the requested date is in the future? The skill returns an empty worklog with a note that the date is in the future.
- What happens when the `.env` file is missing or has no valid credentials? The skill exits with a clear error message listing which credentials are missing.
- What happens when API rate limits are hit during data retrieval? The script reports which source was rate-limited and continues with other sources.
- What happens when a data source returns extremely large amounts of data (e.g., hundreds of Slack messages)? The skill aggregates and summarizes rather than listing every individual message.
- What happens when the same work appears in multiple sources (e.g., a Jira ticket discussed in Slack and committed in Github)? The skill merges related items into a single entry with the best time estimate, listing all contributing sources (e.g., "Slack, Github, Jira").
- What happens when credentials exist but the user has no permissions for a specific resource (e.g., private Slack channel)? The script reports an access error for that resource and continues.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST provide a Claude Code skill (markdown file in `.claude/skills/`) that accepts a date parameter and produces a billable worklog.
- **FR-002**: System MUST use a hybrid data retrieval approach: bash scripts for Slack, Gmail, Google Calendar, and Github; MCP tool invocations for Notion and Jira (via MCP servers configured in `.mcp.json` with OAuth2 3LO authentication).
- **FR-003**: System MUST read API credentials from the `.env` file for bash-script sources (Slack, Gmail, Google Calendar, Github). Notion and Jira authenticate via their MCP server OAuth2 flows and do not require `.env` entries.
- **FR-004**: System MUST produce a markdown file output organized by project, with each project containing a table of billable items (description, estimated hours).
- **FR-005**: System MUST estimate hours worked for each activity based on available signals from the data source (e.g., commit diff size, calendar event duration, message timestamp spans, document edit volume).
- **FR-006**: System MUST gracefully handle missing or invalid credentials by skipping unavailable sources and reporting which sources were skipped.
- **FR-007**: System MUST default to the current date when no date is provided by the user.
- **FR-008**: System MUST include a summary row per project showing total estimated hours.
- **FR-009**: System MUST include a grand total of estimated hours across all projects at the end of the worklog.
- **FR-010**: Each bash script MUST output structured data (JSON) that can be consumed by the skill for aggregation and formatting.
- **FR-011**: System MUST attempt to correlate related activities across sources (e.g., a Jira ticket ID mentioned in a commit message and a Slack thread) and merge them into a single worklog entry with the best time estimate, listing all contributing sources. This avoids duplicate hour counting.
- **FR-012**: System MUST save the generated worklog to a predictable file path (e.g., `worklogs/YYYY-MM-DD.md`).
- **FR-013**: System MUST include all retrieved activities in the output (no pre-filtering for billability) and clearly label each entry with its data source, so the user can review and remove non-billable items.

### Key Entities

- **WorklogEntry**: An individual activity — contains source label (which tool it came from), project name, description, estimated hours, and raw metadata used for estimation. All entries are included by default; the user determines billability during review.
- **Project**: A grouping of worklog entries — identified by project name derived from Jira project, Github repo, Slack channel, or calendar event organizer/topic.
- **DataSource**: A configured external service — has a type (Slack/Notion/Gmail/Calendar/Jira/Github), access method (bash script via `.env` credentials OR MCP tool via OAuth2), credential status (valid/missing/invalid), and a retrieval mechanism.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: User can generate a complete daily worklog in under 60 seconds by running a single skill command. Measured via manual timing of end-to-end invocation during validation.
- **SC-002**: The generated worklog correctly captures activities from all data sources that have valid credentials configured.
- **SC-003**: Hour estimates are within a reasonable range — user needs to adjust fewer than 50% of line items by more than 30 minutes. Validated by manual review of a representative worklog during acceptance testing.
- **SC-004**: The worklog output is immediately usable for client invoicing without structural reformatting (project grouping, description, hours columns).
- **SC-005**: When a data source is unavailable, the skill still completes successfully with data from remaining sources (no full failures from partial outages).
- **SC-006**: Duplicate activities appearing across multiple sources are grouped or flagged, resulting in no more than 10% over-counting of hours.

## Assumptions

- The Google OAuth credentials in `.env` cover both Gmail and Google Calendar access (single OAuth token with appropriate scopes).
- Notion and Jira are accessed via MCP servers configured in `.mcp.json` (Notion: `https://mcp.notion.com/mcp`, Jira: `https://mcp.atlassian.com/v1/mcp`) using OAuth2 3LO authentication — no `.env` entries needed for these two sources.
- The user works across a manageable number of projects per day (fewer than 10) — the output format is optimized for daily granularity, not weekly/monthly summaries.
- LiteLLM credentials in `.env` are available for the skill to use when Claude needs to reason about work effort estimation. Required keys: `LITELLM_URL`, `LITELLM_API_KEY`, `LITELLM_MODEL`. If absent, the skill falls back to heuristic estimation only.
- Project identification is primarily derived from: Github repository names, Jira project keys, Slack channel names, and Google Calendar event titles/organizers.
