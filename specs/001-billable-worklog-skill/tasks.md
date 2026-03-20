# Tasks: Billable Worklog Generator Skill

**Input**: Design documents from `/specs/001-billable-worklog-skill/`
**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/

**Tests**: Not requested — no test tasks included.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization — create directory structure, config templates, and output directories

- [x] T001 Create project directory structure: `scripts/`, `scripts/lib/`, `.claude/skills/`, `worklogs/`
- [x] T002 [P] Create `.env.example` with all required credential keys (SLACK_BOT_TOKEN, SLACK_USER_EMAIL, GOOGLE_OAUTH_CREDENTIALS, GITHUB_PERSONAL_ACCESS_TOKEN, GITHUB_USERNAME, LITELLM_URL, LITELLM_API_KEY, LITELLM_MODEL) in `.env.example`
- [x] T003 [P] Add `worklogs/` and `.env` to `.gitignore`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Shared library and utilities that MUST be complete before any retrieval script can work

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [x] T004 Implement Google OAuth2 token refresh helper in `scripts/lib/google-auth.sh` — reads `GOOGLE_OAUTH_CREDENTIALS` from `.env`, exchanges refresh token via `https://oauth2.googleapis.com/token`, outputs access token to stdout, handles token expiry and first-run consent flow per research.md decision #1

**Checkpoint**: Foundation ready — user story implementation can now begin

---

## Phase 3: User Story 2 — Multi-Source Data Retrieval (Priority: P1)

**Goal**: Fetch activity data from all 6 configured sources (Slack, Gmail, Calendar, Github via bash; Notion, Jira via MCP) for a given date, outputting structured JSON per the WorklogEntry schema.

**Independent Test**: Invoke each script with a known date and verify it outputs a valid JSON array of WorklogEntry objects to stdout, with diagnostics on stderr. Verify MCP instructions retrieve Notion/Jira data.

### Implementation for User Story 2

- [x] T005 [P] [US2] Implement Slack retrieval script in `scripts/fetch-slack.sh` — uses `search.messages` API with user token (`xoxp-*`), filters by `from:<user>` and date range, outputs JSON array of WorklogEntry objects, derives project from channel name, exit codes per contract (0=success, 1=cred error, 2=API error)
- [x] T006 [P] [US2] Implement Github retrieval script in `scripts/fetch-github.sh` — uses `/users/{username}/events` endpoint filtered by date, follows up with `/repos/{owner}/{repo}/commits/{sha}` for diff stats, outputs JSON array of WorklogEntry objects, derives project from repo name, includes correlation_keys with repo reference
- [x] T007 [P] [US2] Implement Gmail retrieval script in `scripts/fetch-gmail.sh` — sources `scripts/lib/google-auth.sh` for OAuth2 token, queries `users.messages.list` with `from:me after:YYYY/MM/DD before:YYYY/MM/DD+1`, fetches subject/recipients via `users.messages.get`, outputs JSON array of WorklogEntry objects, estimates 0.25h per sent email
- [x] T008 [P] [US2] Implement Google Calendar retrieval script in `scripts/fetch-calendar.sh` — sources `scripts/lib/google-auth.sh` for OAuth2 token, queries `events.list` with `timeMin`/`timeMax` for the target date, extracts title/duration/attendees, outputs JSON array of WorklogEntry objects, uses event duration as estimated_hours

**Note**: All scripts MUST distinguish permission/access errors (e.g., private channel, insufficient OAuth scopes) from other API errors in stderr output, providing actionable messages like "Access denied to #channel-name — check Slack token scopes."

**Checkpoint**: All 4 bash retrieval scripts can independently retrieve and output structured WorklogEntry JSON for a given date. Each script handles missing credentials (exit 1) and API/permission errors (exit 2) gracefully. MCP-based retrieval (Notion, Jira) is documented in Phase 4 after the skill file is created.

---

## Phase 4: User Story 1 — Generate Daily Worklog (Priority: P1) 🎯 MVP

**Goal**: A single Claude Code skill command that accepts a date, orchestrates all data retrieval, aggregates results, and produces a markdown worklog file at `worklogs/YYYY-MM-DD.md`.

**Independent Test**: Invoke `claude skill worklog 2026-03-18` and verify a markdown file is produced at `worklogs/2026-03-18.md` containing project-organized tables with descriptions, sources, and estimated hours. Verify default-to-today behavior when no date is given.

### Implementation for User Story 1

- [x] T011 [US1] Create the Claude Code skill definition in `.claude/skills/worklog.md` — define skill name, parameters (optional DATE defaulting to today), validation (reject future dates), orchestration flow: (1) load .env, (2) run 4 bash scripts in parallel capturing stdout JSON + stderr warnings, (3) invoke Notion MCP search, (4) invoke Jira MCP search, (5) collect all WorklogEntry arrays, (6) handle partial failures (skip sources with exit code != 0, record in skipped_sources)
- [x] T009 [P] [US2] Document MCP-based Notion retrieval instructions in `.claude/skills/worklog.md` (Notion section) — instruct Claude to use `notion-search` to find pages edited by user on target date, format results as WorklogEntry JSON with source="notion", derive project from parent database/workspace, estimate 0.5h per page edit. **Depends on T011** (skill file must exist).
- [x] T010 [P] [US2] Document MCP-based Jira retrieval instructions in `.claude/skills/worklog.md` (Jira section) — instruct Claude to search Jira issues updated by user on target date, format results as WorklogEntry JSON with source="jira", derive project from Jira project key, include ticket ID in correlation_keys, estimate 0.5h per ticket interaction. **Depends on T011** (skill file must exist).
- [x] T012 [US1] Add aggregation logic to skill in `.claude/skills/worklog.md` — instruct Claude to: parse all WorklogEntry JSON arrays, perform basic project grouping by `project` field, calculate per-project subtotals and grand total of estimated_hours, handle empty results ("no billable activity found" message)
- [x] T013 [US1] Add markdown output formatting to skill in `.claude/skills/worklog.md` — generate output per the Output File Contract: project headings, tables (Description | Source | Est. Hours), subtotal rows, Uncategorized section for entries with no project, grand total, skipped sources section with reasons, write to `worklogs/YYYY-MM-DD.md`

**Checkpoint**: End-to-end worklog generation works — user runs one command, gets a complete markdown worklog. This is the MVP.

---

## Phase 5: User Story 3 — Work Effort Estimation (Priority: P2)

**Goal**: Improve hour estimation accuracy using source-specific heuristics so that estimates are a reasonable starting point (fewer than 50% of items need >30min adjustment per SC-003).

**Independent Test**: Provide known activity data (e.g., a commit with 50 lines changed → ~0.5h, a 30-minute calendar event → 0.5h, a Slack thread spanning 1.5 hours → ~0.75h) and verify estimates match the heuristic rules.

### Implementation for User Story 3

- [x] T014 [P] [US3] Enhance Github estimation heuristics in `scripts/fetch-github.sh` — implement tiered estimation based on diff size: <20 lines → 0.25h, 20-100 lines → 0.5h, 100-300 lines → 1h, 300+ lines → 2h (per research.md decision #7)
- [x] T015 [P] [US3] Enhance Slack estimation heuristics in `scripts/fetch-slack.sh` — compute time span of conversation threads per topic/channel, estimate 50% of span as active work time (per research.md decision #7)
- [x] T016 [P] [US3] Add estimation cap and validation to all scripts — enforce `estimated_hours` > 0 and <= 12 per data-model.md validation rules, clamp outliers
- [x] T017 [US3] Add optional LiteLLM refinement pass to skill in `.claude/skills/worklog.md` — if LITELLM_URL and LITELLM_API_KEY are configured, instruct Claude to call LiteLLM to review and refine hour estimates based on combined context across all entries; skip if credentials are missing (heuristics are the baseline)

**Checkpoint**: Hour estimates are source-aware and use appropriate heuristics. LiteLLM provides optional refinement.

---

## Phase 6: User Story 4 — Project-Organized Output (Priority: P2)

**Goal**: Intelligent project derivation and cross-source correlation so that related activities are merged and grouped under correct project names, avoiding duplicate hour counting (SC-006: <10% over-counting).

**Independent Test**: Provide activity data spanning multiple projects with cross-source overlaps (e.g., a Jira ticket `PROJ-123` mentioned in a commit message and Slack thread) and verify: entries merge into a single item with the best time estimate, all sources listed, and correct project grouping.

### Implementation for User Story 4

- [x] T018 [US4] Add cross-source correlation logic to skill in `.claude/skills/worklog.md` — instruct Claude to: match entries by correlation_keys (Jira ticket IDs, repo names), detect time-window overlaps (e.g., Slack messages during a calendar meeting), merge matched entries into MergedEntry objects keeping highest estimated_hours and listing all contributing sources
- [x] T019 [US4] Enhance project name derivation in skill in `.claude/skills/worklog.md` — implement derivation rules per data-model.md: Github → repo name, Jira → project key, Slack → channel name, Gmail → subject keyword/recipient domain, Calendar → event title/organizer, Notion → parent database name; normalize inconsistent project names across sources
- [x] T020 [US4] Handle Uncategorized entries in skill in `.claude/skills/worklog.md` — entries that cannot be associated with a specific project appear under an "Uncategorized" section per US4 acceptance scenario #2

**Checkpoint**: Cross-source duplicates are merged, projects are intelligently derived, and the output is organized for direct use in client invoicing.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Edge cases, robustness, and documentation improvements

- [x] T021 [P] Add rate-limit handling to all bash scripts in `scripts/fetch-*.sh` — detect HTTP 429 responses, report which source was rate-limited to stderr, exit with code 2
- [x] T022 [P] Add large data set handling to all bash scripts in `scripts/fetch-*.sh` — when a source returns excessive results (>100 Slack messages, >50 emails, >30 calendar events, >50 Github events), aggregate and summarize by thread/topic/repo rather than listing every individual item
- [x] T023 [P] Add future date validation to skill in `.claude/skills/worklog.md` — return empty worklog with note when requested date is in the future
- [x] T024 Add missing `.env` validation to skill in `.claude/skills/worklog.md` — on startup, check for required credential keys and exit with clear error listing which credentials are missing
- [x] T025 Run quickstart.md validation — verify the documented usage flow works end-to-end
- [x] T026 [P] Validate SC-001 (performance) — run end-to-end worklog generation and verify completion in under 60 seconds; document any bottlenecks
- [x] T027 [P] Validate SC-003 (estimation accuracy) — run worklog for a day with known activities and manually verify fewer than 50% of items need >30min adjustment
- [x] T028 [P] Validate SC-006 (duplicate over-counting) — run worklog for a day with known cross-source overlaps and verify merged output has <10% over-counted hours

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion — BLOCKS all user stories
- **US2 (Phase 3)**: Depends on Foundational — scripts need google-auth.sh
- **US1 (Phase 4)**: Depends on US2 — skill orchestrates the scripts
- **US3 (Phase 5)**: Depends on US2 — enhances existing scripts
- **US4 (Phase 6)**: Depends on US1 — enhances the skill's aggregation logic
- **Polish (Phase 7)**: Depends on US1 being complete (MVP functional)

### User Story Dependencies

- **User Story 2 (P1)**: Can start after Foundational (Phase 2) — retrieval scripts are independent of each other
- **User Story 1 (P1)**: Depends on US2 — needs scripts to exist before orchestrating them
- **User Story 3 (P2)**: Can start after US2 — enhances scripts independently of the skill
- **User Story 4 (P2)**: Depends on US1 — enhances aggregation logic in the skill

### Within Each User Story

- US2: All 4 bash scripts are independent ([P]); MCP instructions (T009, T010) moved to Phase 4 after T011 creates the skill file
- US1: Skill definition → aggregation → output formatting (sequential)
- US3: All estimation enhancements are independent ([P]), LiteLLM depends on skill
- US4: Correlation → project derivation → uncategorized handling (sequential)

### Parallel Opportunities

- **Phase 1**: T002 and T003 can run in parallel
- **Phase 3 (US2)**: T005, T006, T007, T008 can ALL run in parallel (4 independent scripts)
- **Phase 5 (US3)**: T014, T015, T016 can ALL run in parallel (independent script enhancements)
- **Phase 7**: T021, T022, T023 can run in parallel
- **Cross-phase**: US3 (Phase 5) can start as soon as US2 is complete, in parallel with US1

---

## Parallel Example: User Story 2

```bash
# Launch all 4 retrieval scripts in parallel (different files, no dependencies):
Task T005: "Implement Slack retrieval in scripts/fetch-slack.sh"
Task T006: "Implement Github retrieval in scripts/fetch-github.sh"
Task T007: "Implement Gmail retrieval in scripts/fetch-gmail.sh"
Task T008: "Implement Calendar retrieval in scripts/fetch-calendar.sh"
```

## Parallel Example: User Story 3

```bash
# Launch all estimation enhancements in parallel (different files):
Task T014: "Enhance Github estimation in scripts/fetch-github.sh"
Task T015: "Enhance Slack estimation in scripts/fetch-slack.sh"
Task T016: "Add estimation cap to all scripts"
```

---

## Implementation Strategy

### MVP First (User Stories 2 + 1)

1. Complete Phase 1: Setup (T001-T003)
2. Complete Phase 2: Foundational — google-auth.sh (T004)
3. Complete Phase 3: US2 — all 6 retrieval sources (T005-T010)
4. Complete Phase 4: US1 — skill orchestration + output (T011-T013)
5. **STOP and VALIDATE**: Run `claude skill worklog` and verify end-to-end output
6. MVP is usable at this point with basic estimation and project grouping

### Incremental Delivery

1. Setup + Foundational → Infrastructure ready
2. Add US2 (retrieval) → Individual scripts work → Validate each
3. Add US1 (skill) → End-to-end worklog generation → **MVP!**
4. Add US3 (estimation) → Better hour estimates → Validate accuracy
5. Add US4 (project org) → Cross-source correlation + intelligent grouping → Validate merges
6. Polish → Edge cases, robustness, validation

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- The skill file `.claude/skills/worklog.md` is the central artifact — US1, US3, US4 all modify it at different sections
- MCP tools (Notion, Jira) require no bash scripts — handled directly in skill instructions
