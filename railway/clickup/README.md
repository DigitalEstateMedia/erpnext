# ClickUp → ERPNext migration

Moves one ClickUp list into ERPNext as a Project with Tasks. Idempotent: keyed on
`custom_clickup_task_id`, so re-running updates in place instead of duplicating.

```bash
python3 migrate_api.py data.json --plan   # print the mapping, write nothing
python3 migrate_api.py data.json          # apply
```

Admin password is read from `railway/.env.local` (gitignored) or `ERPNEXT_ADMIN_PASSWORD`.
Requests go through `curl` because this machine's Python SSL store is not configured —
the same constraint `platform/plane/railway/provision.py` documents.

## Input shape

`data.json` is assembled from the ClickUp API:

```json
{"list_id": "...", "list_name": "...", "list_url": "...",
 "tasks": [{"id": "869...", "name": "...", "status": "complete", "priority": "high",
            "assignees": ["someone@example.com"], "desc": "markdown",
            "cf": {"Category": "Code", "Business": "Claude", "Effort": "Half Day",
                   "Work Type": "Automation", "Growth Goal": "Operational Efficiency",
                   "Status": "Done"}}]}
```

Two things about the ClickUp side that cost time to discover:

- `filter_tasks` returns **neither descriptions nor custom-field values**. Full fidelity
  needs one `get_task` per task, so a full migration is hundreds of calls.
- Dropdown custom fields return `value` as an **orderindex integer**, not the option UUID
  (`Business: 11` → "Claude"). Decode against `type_config.options`. Option names can also
  carry trailing spaces (`"Done "`), so strip before matching.

## What the mapping loses

- **Status.** ERPNext `Task.status` is a fixed Select (`Open, Working, Pending Review,
  Overdue, Template, Completed, Cancelled`). ClickUp's per-list workflows collapse into it.
  The original is preserved separately in `custom_clickup_status`.
- **Assignees are not a Task field.** Frappe assigns through the ToDo/`_assign` mechanism,
  so each assignment is a second write.
- Comments, attachments, checklists, and subtask nesting are **not** migrated.

## Verified

Pilot on "ERPNext Self-Host Build" (11 tasks): 11 created, 0 failed, 0 field mismatches
on read-back across subject, status, priority, all six custom fields, assignees and
descriptions. Re-run produced 0 duplicates and 11 updates.
