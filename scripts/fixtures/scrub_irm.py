#!/usr/bin/env python3
"""Scrubs private IRM captures into committable fixtures.

Reads raw read-only captures from a real IRM stack in .sandbox/user/irm-raw/
(gitignored, private) and writes scrubbed copies to
tests/fixtures/irm/<irm version>/, then checks the result against the raw
capture and fails when any raw value survived that is not on the allow list.

- Strings are replaced unless their key is on the allow list of enum-like
  fields (state, status, kinds) or they are timestamps; names, emails, titles,
  messages, slugs, label names and values and URLs (with every id inside them)
  become consistent pseudonyms: the same original maps to the same
  replacement in every file, so relations between files survive.
- Ids are renumbered: every numeric id or counter that identifies an object
  (alert group numbers, incident ids, org, stack, role and Grafana user ids,
  numeric strings under id-like keys) maps to 1001, 1002, ... in the order of
  the original values, so relative order and cross-references survive. Other
  ids keep their shape (a letter and digits, or a UUID).
- Metric values in alert payloads are renumbered like ids.
- Phone numbers and chat identities are dropped; lists are trimmed.

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
    "webhookMethod", "severity", "severityLabel", "version",
    # Server error wording (OnCall `detail`, the Incident API's problem details).
    "detail", "hint", "code",
}
# Per file, keys whose values are org configuration rather than user data.
KEEP_IN = {"incident_statuses.json": {"slug", "name", "description"}}
# Numbers that are counts, sizes, durations or HTTP codes, not identities.
COUNT_KEYS = {
    "count", "alerts_count", "page_size", "total_pages", "current_page_number", "durationSeconds",
    "position", "limit", "version", "numFiring", "numResolved", "truncatedAlerts", "level",
    "totalAssignments", "totalParticipants", "status", "webhookStatusCode",
}
# Times stay real: they carry no names, and specs depend on their order.
TIME_KEYS = re.compile(r"(_at|_start|_end|Time|Start|End|startsAt|endsAt|created|modified|timestamp|At)$")
ISO = re.compile(r"^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}[\d:.+Z-]*)?$")
# Generic label names may stay; any other label name is a pseudonym too.
GENERIC_LABELS = {
    "alertname", "severity", "grafana_folder", "team", "service", "instance", "job", "env",
    "namespace", "cluster", "__alert_rule_uid__", "summary", "description", "runbook_url",
}
LABEL_MAPS = {"labels", "annotations", "commonLabels", "commonAnnotations", "groupLabels", "values"}
DROP = {"phone_number", "slack", "slack_app", "telegram", "photoURL", "avatarUrl", "msteams",
        "mobile_app", "mobile_app_critical", "templates", "authLabels", "secureJsonFields"}
TRIM = {"results": 25, "incidentPreviews": 10, "activityItems": 12, "alerts": 2, "users": 6}
# Numbers that identify an object even though the key does not say "id".
NUMBER_KEYS = {"alert_group_number", "orgId", "stackId", "grafana_id", "roleID"}

seen = {}
counters = {}
keep_extra = set()
# Original numeric id -> renumbered id (built by collect_numbers before scrubbing).
numbers = {}


def is_id_key(key):
    key = key or ""
    return key in {"id", "pk", "uid", "slug", "fingerprint", "groupKey", "ruleUID", "receiver",
                   "stackSlug", "clusterSlug", "user_pk", "acknowledged_by", "resolved_by",
                   "silenced_by", "nextValue", "trace_id"} or key in NUMBER_KEYS or \
        key.endswith("_id") or key.endswith("ID") or key.endswith("_ids") or key.endswith("IDs") or \
        key in {"on_call_now", "shifts", "users", "teams", "dependent_alert_group_ids"}


def numeric(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str) and re.fullmatch(r"\d{1,18}", value):
        return int(value)
    return None


def collect_numbers(value, key, found):
    if isinstance(value, dict):
        for k, v in value.items():
            if key in LABEL_MAPS and isinstance(v, (int, float)) and not isinstance(v, bool):
                found.add(("metric", v))
            collect_numbers(v, k, found)
    elif isinstance(value, list):
        for v in value:
            collect_numbers(v, key, found)
    elif is_id_key(key):
        n = numeric(value)
        if n is not None:
            found.add(("id", n))


def build_numbers(docs):
    found = set()
    for doc in docs:
        collect_numbers(doc, None, found)
    for kind in ("id", "metric"):
        for i, n in enumerate(sorted(v for k, v in found if k == kind)):
            numbers[(kind, n)] = 1001 + i


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
        if re.fullmatch(r"[0-9a-f-]{36}", value):
            out = "00000000-0000-4000-8000-%012d" % n
        else:
            head = value[:1] if value[:1].isalpha() else "X"
            body = ("%0" + str(max(len(value) - 1, 4)) + "d") % n
            out = head + body
    else:
        out = "%s %d" % (kind, n)
    seen[key] = out
    return out


def is_time(key, value):
    return isinstance(value, str) and ISO.match(value) is not None


def scrub_string(key, value):
    if value == "":
        return value
    if key in KEEP or key in keep_extra:
        return value
    if is_time(key, value):
        return value
    if re.match(r"^https?://", value):
        return pseudo("url", value)
    if "@" in value and re.fullmatch(r"[^@\s]+@[^@\s]+", value):
        return pseudo("email", value)
    if is_id_key(key):
        n = numeric(value)
        if n is not None:
            return str(numbers[("id", n)])
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
            if key in LABEL_MAPS and isinstance(v, (int, float)) and not isinstance(v, bool):
                out[nk] = numbers[("metric", v)]
                continue
            out[nk] = scrub(v, k)
        return out
    if isinstance(value, bool):
        return value
    if isinstance(value, int) and is_id_key(key):
        return numbers[("id", value)]
    if isinstance(value, list):
        limit = TRIM.get(key)
        items = value[:limit] if limit else value
        return [scrub(v, key) for v in items]
    if isinstance(value, str):
        return scrub_string(key, value)
    return value


def scalars(value, key=None, out=None, path=""):
    """Every (path, key, scalar) in a document."""
    if out is None:
        out = []
    if isinstance(value, dict):
        for k, v in value.items():
            scalars(v, k, out, path + "." + str(k))
    elif isinstance(value, list):
        for i, v in enumerate(value):
            scalars(v, key, out, "%s[%d]" % (path, i))
    elif not isinstance(value, bool) and value is not None:
        out.append((path, key, value))
    return out


# Public names that may appear as they are: the IRM app's plugin id.
PUBLIC = {"grafana-irm-app"}


def allowed(name, key, value):
    """Whether a raw value may appear unchanged in fixture `name`."""
    if isinstance(value, str):
        return value in PUBLIC or key in KEEP or key in KEEP_IN.get(name, set()) or is_time(key, value)
    if isinstance(value, (int, float)):
        if abs(value) < 100 or key in COUNT_KEYS:
            return True
        # Epoch timestamps (seconds or milliseconds) are times, not identities.
        return key is not None and TIME_KEYS.search(key) is not None
    return False


def leaks(raw_docs, out_dir, names):
    """Raw strings (3+ chars) and numbers (100+) found unchanged in the scrubbed output."""
    raw_values = set()
    for doc in raw_docs:
        for _, _, v in scalars(doc):
            if (isinstance(v, str) and len(v) >= 3) or (isinstance(v, (int, float)) and abs(v) >= 100):
                raw_values.add(v)
    found = []
    for name in names:
        with open(os.path.join(out_dir, name), encoding="utf-8") as f:
            doc = json.load(f)
        for path, key, v in scalars(doc):
            if v in raw_values and not allowed(name, key, v):
                found.append("%s %s = %r" % (name, path, v))
    return found


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
    # Grafana's RBAC action names are public; the scopes are not kept.
    files["grafana_permissions.json"] = {
        k: ["*"] for k in sorted(perms) if k.startswith("grafana-irm-app.") or k.startswith("plugins.")
    }
    build_numbers(files.values())
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
    severities = load("severities.json")
    with open(os.path.join(out_dir, "incident_severities_404.txt"), "w", encoding="utf-8") as f:
        f.write(severities if isinstance(severities, str) else "404 page not found\n")
    print("wrote %d fixtures to %s" % (len(files) + 1, os.path.relpath(out_dir, ROOT)))

    raw_docs = [doc for doc in files.values() if not isinstance(doc, str)]
    found = leaks(raw_docs, out_dir, list(files))
    if found:
        print("raw values left in the scrubbed fixtures:", file=sys.stderr)
        for line in found:
            print("  " + line, file=sys.stderr)
        sys.exit(1)
    print("leak scan: no raw string (3+ chars) or number (100+) left outside the allow list")


if __name__ == "__main__":
    main()
