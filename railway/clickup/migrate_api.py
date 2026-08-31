#!/usr/bin/env python3
"""Migrate one ClickUp list into ERPNext as a Project + Tasks, over the REST API.

Idempotent: keyed on custom_clickup_task_id / custom_clickup_list_id, so re-running
updates in place rather than duplicating.

    python3 migrate_api.py data.json [--plan]

--plan prints the mapping it would apply and writes nothing.
"""
import json
import sys

from erp import connect

DATA = json.load(open([a for a in sys.argv[1:] if not a.startswith("-")][0]))
PLAN = "--plan" in sys.argv

# ClickUp status is per-list and free-form; ERPNext Task.status is a fixed Select.
# This collapse is the lossy edge of the mapping.
STATUS = {"to do": "Open", "complete": "Completed", "in progress": "Working",
          "review": "Pending Review", "blocked": "Pending Review",
          "closed": "Completed", "cancelled": "Cancelled"}
# ERPNext has no "Normal" priority; its middle value is "Medium".
PRIORITY = {"urgent": "Urgent", "high": "High", "normal": "Medium", "low": "Low"}

SELECTS = {
    "custom_category": ["", "Setup", "Code", "Design", "Content", "Deploy", "QA", "Account/Admin"],
    "custom_work_type": ["", "Automation", "SOW/Proposal", "Template/Report", "Strategy/Planning",
                         "Cold Email", "Documentation", "Operational", "Lead Generation"],
    "custom_effort": ["", "Quick Win", "Half Day", "Full Day", "Multi-Day"],
    "custom_growth_goal": ["", "Revenue Growth", "Client Acquisition",
                           "Operational Efficiency", "Multi-Goal"],
    "custom_clickup_status": ["", "Done", "Working on it", "On Hold", "For approval",
                              "Cancelled", "Waiting for informations"],
}


def custom_fields_spec():
    spec = [
        dict(dt="Task", fieldname="custom_clickup_task_id", fieldtype="Data",
             label="ClickUp Task ID", insert_after="department", read_only=1),
        dict(dt="Task", fieldname="custom_clickup_url", fieldtype="Data",
             label="ClickUp URL", insert_after="custom_clickup_task_id", read_only=1),
        dict(dt="Task", fieldname="custom_business", fieldtype="Data",
             label="Business", insert_after="custom_clickup_url"),
    ]
    prev = "custom_business"
    for fn, opts in SELECTS.items():
        spec.append(dict(dt="Task", fieldname=fn, fieldtype="Select",
                         label=fn.replace("custom_", "").replace("_", " ").title(),
                         options="\n".join(opts), insert_after=prev))
        prev = fn
    spec += [
        dict(dt="Project", fieldname="custom_clickup_list_id", fieldtype="Data",
             label="ClickUp List ID", insert_after="project_name", read_only=1),
        dict(dt="Project", fieldname="custom_clickup_url", fieldtype="Data",
             label="ClickUp URL", insert_after="custom_clickup_list_id", read_only=1),
    ]
    return spec


def ensure_custom_fields(e):
    made = 0
    for f in custom_fields_spec():
        found = e.list("Custom Field", [["dt", "=", f["dt"]], ["fieldname", "=", f["fieldname"]]])
        if found:
            continue
        r = e.post("/api/resource/Custom%20Field", f)
        if "data" not in r:
            print("   ! custom field %s.%s -> %s" % (f["dt"], f["fieldname"], json.dumps(r)[:220]))
        else:
            made += 1
    return made


def upsert_project(e):
    found = e.list("Project", [["custom_clickup_list_id", "=", DATA["list_id"]]])
    payload = {
        "project_name": DATA["list_name"],
        "custom_clickup_list_id": DATA["list_id"],
        "custom_clickup_url": DATA["list_url"],
        "status": "Open",
        "company": "DigitalEstateMedia",
    }
    if found:
        name = found[0]["name"]
        e.put("/api/resource/Project/%s" % name, payload)
        return name, False
    r = e.post("/api/resource/Project", payload)
    if "data" not in r:
        raise SystemExit("project create failed: %s" % json.dumps(r)[:400])
    return r["data"]["name"], True


def task_payload(project, t):
    cf = t.get("cf") or {}
    prio = (t.get("priority") or "").lower()
    return {
        "subject": t["name"][:140],
        "project": project,
        "description": t.get("desc") or "",
        "status": STATUS.get((t.get("status") or "").lower(), "Open"),
        "priority": PRIORITY.get(prio, "Medium"),
        "custom_clickup_task_id": t["id"],
        "custom_clickup_url": "https://app.clickup.com/t/%s" % t["id"],
        "custom_business": cf.get("Business") or "",
        "custom_category": cf.get("Category") or "",
        "custom_work_type": cf.get("Work Type") or "",
        "custom_effort": cf.get("Effort") or "",
        "custom_growth_goal": cf.get("Growth Goal") or "",
        # ClickUp dropdown option names carry trailing spaces ("Done ") — strip them.
        "custom_clickup_status": (cf.get("Status") or "").strip(),
    }


def upsert_task(e, project, t):
    payload = task_payload(project, t)
    found = e.list("Task", [["custom_clickup_task_id", "=", t["id"]]])
    if found:
        name = found[0]["name"]
        r = e.put("/api/resource/Task/%s" % name, payload)
        return name, False, r
    r = e.post("/api/resource/Task", payload)
    return (r.get("data", {}).get("name"), True, r)


def assign(e, task_name, emails, subject):
    for email in emails or []:
        r = e.post("/api/method/frappe.desk.form.assign_to.add",
                   {"doctype": "Task", "name": task_name,
                    "assign_to": json.dumps([email]), "description": subject[:100]})
        if "message" not in r:
            print("     ! assign %s -> %s" % (email, json.dumps(r)[:180]))


def main():
    if PLAN:
        print("PLAN — %s (%d tasks)\n" % (DATA["list_name"], len(DATA["tasks"])))
        for t in DATA["tasks"]:
            p = task_payload("<project>", t)
            print("  %-58s %-9s %-6s %-14s %s" % (
                t["name"][:58], p["status"], p["priority"],
                p["custom_category"], p["custom_clickup_status"] or "-"))
        return

    e = connect()
    print("custom fields ...")
    print("  created %d" % ensure_custom_fields(e))

    project, new = upsert_project(e)
    print("project: %s (%s)" % (project, "created" if new else "updated"))

    created = updated = failed = 0
    for t in DATA["tasks"]:
        name, is_new, raw = upsert_task(e, project, t)
        if not name:
            failed += 1
            print("  FAILED  %-52s %s" % (t["name"][:52], json.dumps(raw)[:200]))
            continue
        created += is_new
        updated += (not is_new)
        assign(e, name, t.get("assignees"), t["name"])
        print("  %-10s %-7s %s" % (name, "create" if is_new else "update", t["name"][:56]))

    print("\ncreated=%d updated=%d failed=%d" % (created, updated, failed))


if __name__ == "__main__":
    main()
