---
description: Create Jira tickets in LIG or GENAI. Triggers on "create jira ticket", "new jira", "log bug", or shorthand "LIG/GENAI description".
---

## User Input

```text
$ARGUMENTS
```

## Workflow

1. **Parse input** - Extract project (LIG or GENAI) and description from `$ARGUMENTS`
   - Shorthand: `LIG fix login` → project=LIG, summary="Fix login"
   - Explicit: `create ticket in GENAI for caching feature`

2. **Generate title** - Create concise summary (capitalize, imperative form)

3. **Resolve Tempo account** - Use default mapping or `--account-id` if specified:
   - **LIG** → 228 (`[P] APRÓ Lighthouse`) — use directly, no prompt
   - **GENAI** → **Prompt user** to choose:
     1. 155 (`[P] Gögn&gervigreind Hraðall`)
     2. 154 (`[O] AI hraðall - rekstur`)
   - Override with `--account-id NNN` if different billing account needed

4. **Confirm** - Show preview:
   ```
   Create ticket?
   Project: LIG | Summary: Fix login page | Type: Task | Account: [P] APRÓ Lighthouse | Assignee: Jón Levy
   ```

5. **Create ticket** (include `--account-id`):
   ```bash
   bash scripts/create-jira-ticket.sh --project "LIG" --summary "Fix login page" --type "Task" --account-id 228
   ```

6. **Assign** (accountId `6089755e29110000719bd00b`):
   ```bash
   source .env && curl -s -X PUT -u "${JIRA_USER_EMAIL}:${JIRA_TOKEN}" \
     -H "Content-Type: application/json" \
     -d '{"accountId": "6089755e29110000719bd00b"}' \
     "${JIRA_BASE_URL}/rest/api/3/issue/XXX-NN/assignee"
   ```

7. **Report** - Show ticket key and URL

## Examples

| Input | Result |
|-------|--------|
| `LIG fix sidebar bug` | LIG-XX: Fix sidebar bug |
| `GENAI add vector search` | GENAI-XX: Add vector search |

## Optional

- `--type Bug` - Issue type (default: Task)
- `--customer "Name"` - Customer field (GENAI only, customfield_12513)
- `--account-id 123` - Tempo account (customfield_11530)
