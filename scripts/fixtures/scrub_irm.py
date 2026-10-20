#!/usr/bin/env python3
"""Scrubs private IRM captures into committable fixtures.

Reads raw read-only captures from a real IRM stack in .sandbox/user/irm-raw/
(gitignored, private) and writes scrubbed copies to
tests/fixtures/irm/<irm version>/. Every string is replaced unless its key is
on the allow list of enum-like fields (state, status, kinds, times); names,
emails, titles, messages, ids, slugs and URLs become consistent pseudonyms:
the same original value maps to the same replacement in every file, so the
relations between files (a schedule's on_call_now ids and the users list, an
alert group and its alerts) survive. Phone numbers and Slack identities are
dropped. Lists are trimmed to keep fixtures small.

Usage: python3 scripts/fixtures/scrub_irm.py [raw_dir] [out_dir]
"""

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, ".sandbox/user/irm-raw")

# Values of these keys are enums, booleans-as-strings or server metadata, not user data.
KEEP = {
    "state", "status", "type", "activityKind", "relevance", "incidentType", "category", "kind",
    "orderDirection", "orderField", "phone_number_status", "role", "icon", "provider",
    "webhookMethod", "numFiring", "numResolved", "version", "severity", "severityLabel",
    # Server error wording (OnCall `detail`, the Incident API's problem details).
    "detail", "hint", "code",
}
# Per file, keys whose values are org configuration rather than user data.
KEEP_IN = {"incident_statuses.json": {"slug", "name", "description"}}
# Times stay real: they carry no names, and specs depend on their order.
TIME_KEYS = re.compile(r"(_at|_start|_end|Time|Start|End|startsAt|endsAt|created|modified)$")
ISO = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}")
# Generic label names may stay; any other label name is a pseudonym too.
GENERIC_LABELS = {
    "alertname", "severity", "grafana_folder", "team", "service", "instance", "job", "env",
    "namespace", "cluster", "__alert_rule_uid__", "summary", "description", "runbook_url",
}
LABEL_MAPS = {"labels", "annotations", "commonLabels", "commonAnnotations", "groupLabels", "values"}
DROP = {"phone_number", "slack", "slack_app", "telegram", "photoURL", "avatarUrl", "msteams",
        "mobile_app", "mobile_app_critical", "templates", "authLabels", "secureJsonFields"}
TRIM = {"results": 25, "incidentPreviews": 10, "activityItems": 12, "alerts": 2, "users": 6}

seen = {}
counters = {}
keep_extra = set()


def pseudo(kind, value):
    key = (kind, value)
    if key in seen:
        return seen[key]
    n = counters.get(kind, 0) + 1
    counters[kind] = n
    if kind == "url":
        out = "https://example.invalid/irm/%d" % n
    elif kind == "email":
        out = "user%d@example.com" % n
    elif kind == "id":
        # Keep the id's shape (OnCall ids are an upper-case letter and 12 base36 chars).
        if re.fullmatch(r"\d+", value):
            out = str(1000 + n)
        elif re.fullmatch(r"[0-9a-f-]{36}", value):
            out = "00000000-0000-4000-8000-%012d" % n
        else:
            head = value[:1] if value[:1].isalpha() else "X"
            body = ("%0" + str(max(len(value) - 1, 4)) + "d") % n
            out = head + body
    else:
        out = "%s %d" % (kind, n)
    seen[key] = out
    return out


def is_id_key(key):
    return key in {"id", "pk", "uid", "slug", "fingerprint", "groupKey", "ruleUID", "receiver",
                   "orgId", "stackId", "stackSlug", "clusterSlug", "grafana_id", "user_pk",
                   "acknowledged_by", "resolved_by", "silenced_by", "nextValue", "trace_id"} or \
        key.endswith("_id") or key.endswith("ID") or key.endswith("_ids") or key.endswith("IDs") or \
        key in {"on_call_now", "shifts", "users", "teams", "dependent_alert_group_ids"}


def scrub_string(key, value):
    if value == "":
        return value
    if key in KEEP or key in keep_extra:
        return value
    if TIME_KEYS.search(key or "") and ISO.match(value):
        return value
    if ISO.fullmatch(value + ":00") or re.fullmatch(r"\d{4}-\d{2}-\d{2}T[\d:.+Z-]+", value):
        return value
    if re.match(r"^https?://", value):
        return pseudo("url", value)
    if "@" in value and re.fullmatch(r"[^@\s]+@[^@\s]+", value):
        return pseudo("email", value)
    if is_id_key(key or ""):
        return pseudo("id", value)
    return pseudo(key or "text", value)


def scrub(value, key=None):
    if isinstance(value, dict):
        out = {}
        for k, v in value.items():
            if k in DROP:
                continue
            nk = k
            if key in LABEL_MAPS and k not in GENERIC_LABELS:
                nk = pseudo("label", k)
            if k == "fieldValues" and isinstance(v, dict):
                # Free-form per activity kind: keep only the field names.
                out[nk] = {fk: scrub(fv, fk) for fk, fv in v.items() if not isinstance(fv, (dict, list))}
                continue
            if key in LABEL_MAPS and isinstance(v, str):
                # A label value's pseudonym never names its (possibly private) label.
                out[nk] = pseudo("url", v) if re.match(r"^https?://", v) else pseudo("value", v)
                continue
            out[nk] = scrub(v, k)
        return out
    if isinstance(value, bool):
        return value
    if isinstance(value, int) and key is not None and is_id_key(key):
        return int(pseudo("id", str(value)))
    if isinstance(value, list):
        limit = TRIM.get(key)
        items = value[:limit] if limit else value
        return [scrub(v, key) for v in items]
    if isinstance(value, str):
        return scrub_string(key, value)
    return value


def load(name):
    path = os.path.join(RAW, name)
    with open(path, encoding="utf-8") as f:
        text = f.read()
    try:
        return json.loads(text)
    except ValueError:
        return text


def main():
    settings = load("settings.json")
    version = settings.get("info", {}).get("version", "unknown")
    out_dir = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "tests/fixtures/irm", version)
    os.makedirs(out_dir, exist_ok=True)

    trimmed_settings = {
        "id": settings.get("id"),
        "enabled": settings.get("enabled"),
        "info": {"version": version},
        "jsonData": settings.get("jsonData", {}),
    }
    # The OnCall API's own host is regional, not private, but it names the stack's cluster.
    files = {
        "settings.json": trimmed_settings,
        "oncall_schedules.json": load("oncall_schedules.json"),
        "oncall_current_oncall.json": load("oncall_current_oncall.json"),
        "oncall_next_oncall.json": load("oncall_next_oncall.json"),
        "oncall_users.json": load("oncall_users.json"),
        "oncall_integrations.json": load("oncall_integrations.json"),
        "oncall_alert_groups_new.json": load("oncall_ag_new.json"),
        "oncall_alert_groups_acknowledged.json": load("oncall_ag_ack.json"),
        "oncall_alert_groups_new_count.json": load("oncall_ag_new_1.json"),
        "oncall_alert_groups_acknowledged_count.json": load("oncall_ag_acknowledged_1.json"),
        "oncall_alert_groups_silenced_count.json": load("oncall_ag_silenced_1.json"),
        "oncall_alert_group.json": load("oncall_ag_detail.json"),
        "oncall_alerts.json": load("oncall_alerts.json"),
        "oncall_forbidden.json": load("w_integration_create.json"),
        "oncall_sa_current_user.json": load("oncall_user_current.json"),
        "incident_previews_open.json": load("incident_open_q.json"),
        "incident_get.json": load("incident_get.json"),
        "incident_activity.json": load("incident_activity.json"),
        "incident_statuses.json": load("statuses.json"),
        "incident_not_found.json": load("w_sev_missing.json"),
        "grafana_user.json": load("api_user.json"),
    }
    perms = load("perms.json")
    files["grafana_permissions.json"] = {
        k: ["*"] for k in sorted(perms) if k.startswith("grafana-irm-app.") or k.startswith("plugins.")
    }
    global keep_extra
    for name, doc in files.items():
        keep_extra = KEEP_IN.get(name, set())
        scrubbed = scrub(doc)
        if name == "settings.json":
            scrubbed["id"] = "grafana-irm-app"  # the public plugin id, which the parser checks
        with open(os.path.join(out_dir, name), "w", encoding="utf-8") as f:
            json.dump(scrubbed, f, indent=1, sort_keys=True)
            f.write("\n")
    # Not JSON: GetOrgSeverities is not routed on this IRM version.
    with open(os.path.join(out_dir, "incident_severities_404.txt"), "w", encoding="utf-8") as f:
        f.write(load("severities.json") if isinstance(load("severities.json"), str) else "404 page not found\n")
    print("wrote %d fixtures to %s" % (len(files) + 1, os.path.relpath(out_dir, ROOT)))


if __name__ == "__main__":
    main()
