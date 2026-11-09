#!/usr/bin/env python3
"""Fake Grafana IRM for screenshots and manual checks (dev only, not shipped).

Serves the scrubbed captures in tests/fixtures/irm/0.128.0 on the paths the
plugin calls, as if it were a Grafana with the IRM app:

  GET  /api/plugins/grafana-irm-app/settings        onCallApiUrl -> <this server>/oncall/
  GET  /api/access-control/user/permissions
  GET  /oncall/api/v1/{schedules,users,integrations,alert_groups,alerts}/...
  POST /api/plugins/grafana-irm-app/resources/api/v1/<Service>.<Method>

Every other request is proxied unchanged (headers included) to UPSTREAM, a
real Grafana, so one context `grafana` endpoint can point here. Timestamps in
the fixtures are shifted so their capture day (2026-10-19) becomes today.
Writes are refused with 403: the fixtures are read-only.

  python3 scripts/fake-irm/server.py [PORT] [UPSTREAM]
  (defaults 13900, http://127.0.0.1:3000)
"""

import datetime as dt
import json
import pathlib
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FIXTURES = pathlib.Path(__file__).resolve().parents[2] / "tests" / "fixtures" / "irm" / "0.128.0"
CAPTURE_DAY = dt.date(2026, 10, 19)
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 13900
UPSTREAM = (sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1:3000").rstrip("/")
SELF = f"http://127.0.0.1:{PORT}"
ISO = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})")

RPC = {
    "IncidentsService.QueryIncidentPreviews": "incident_previews_open.json",
    "IncidentsService.GetIncident": "incident_get.json",
    "ActivityService.QueryActivity": "incident_activity.json",
    "StatusService.QueryOrgStatuses": "incident_statuses.json",
}
GROUPS = {
    "new": "oncall_alert_groups_new.json",
    "acknowledged": "oncall_alert_groups_acknowledged.json",
    "silenced": "oncall_alert_groups_silenced_count.json",
}
EMPTY_PAGE = {"count": 0, "next": None, "previous": None, "results": [], "page_size": 0}


def shifted(text: str) -> str:
    delta = dt.date.today() - CAPTURE_DAY

    def move(m: re.Match) -> str:
        s = m.group(0)
        t = dt.datetime.fromisoformat(s.replace("Z", "+00:00")) + delta
        out = t.isoformat()
        return out.replace("+00:00", "Z") if s.endswith("Z") else out

    return ISO.sub(move, text)


def fixture(name: str) -> bytes:
    return shifted((FIXTURES / name).read_text()).encode()


# The capture holds current/next_oncall of one schedule; the others get the
# same shift with their own name and the users of their `on_call_now`, so
# each schedule shows its own people (none when nobody is on call).
def oncall(schedule_id: str, which: str) -> bytes:
    doc = json.loads(fixture(f"oncall_{which}_oncall.json"))
    schedule = next(
        (s for s in json.loads(fixture("oncall_schedules.json"))["results"] if s["id"] == schedule_id), None
    )
    if schedule is None:
        return fixture("oncall_forbidden.json")
    ids = schedule.get("on_call_now") or []
    if not ids:
        return json.dumps({"count": 0, "shifts": [], "users": []}).encode()
    users = {u["id"]: u for u in json.loads(fixture("oncall_users.json"))["results"]}
    shift = dict(doc["shifts"][0], schedule_id=schedule_id, schedule_name=schedule["name"], users=ids)
    picked = [users[i] for i in ids if i in users]
    return json.dumps({"count": len(picked), "shifts": [shift], "users": picked}).encode()
    return shifted((FIXTURES / name).read_text()).encode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("fake-irm %s %s\n" % (self.command, self.path.split("?")[0]))

    def send(self, code: int, body: bytes, ctype: str = "application/json") -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def local(self) -> tuple[int, bytes, str] | None:
        url = urllib.parse.urlsplit(self.path)
        path, query = url.path, urllib.parse.parse_qs(url.query)
        if path == "/api/plugins/grafana-irm-app/settings":
            doc = json.loads(fixture("settings.json"))
            doc["jsonData"]["onCallApiUrl"] = SELF + "/oncall/"
            doc["jsonData"]["incidentApiUrl"] = SELF + "/incident/"
            return 200, json.dumps(doc).encode(), "application/json"
        if path == "/api/access-control/user/permissions":
            return 200, fixture("grafana_permissions.json"), "application/json"
        if path.startswith("/api/plugins/grafana-irm-app/resources/api/v1/"):
            method = path.rsplit("/", 1)[1]
            if method == "SeveritiesService.GetOrgSeverities":
                return 404, (FIXTURES / "incident_severities_404.txt").read_bytes(), "text/plain"
            if method in RPC:
                return 200, fixture(RPC[method]), "application/json"
            return 403, b'{"error":"fake-irm is read-only"}', "application/json"
        if not path.startswith("/oncall/"):
            return None
        rest = path[len("/oncall/") :]
        if self.command != "GET":
            return 403, fixture("oncall_forbidden.json"), "application/json"
        if rest == "api/v1/schedules/":
            return 200, fixture("oncall_schedules.json"), "application/json"
        if m := re.fullmatch(r"api/v1/schedules/([^/]+)/(current|next)_oncall/", rest):
            return 200, oncall(m.group(1), m.group(2)), "application/json"
        if rest == "api/v1/users/":
            return 200, fixture("oncall_users.json"), "application/json"
        if rest == "api/v1/integrations/":
            return 200, fixture("oncall_integrations.json"), "application/json"
        if rest == "api/v1/alert_groups/":
            name = GROUPS.get(query.get("state", [""])[0])
            return 200, (fixture(name) if name else json.dumps(EMPTY_PAGE).encode()), "application/json"
        if re.fullmatch(r"api/v1/alert_groups/[^/]+/", rest):
            return 200, fixture("oncall_alert_group.json"), "application/json"
        if rest == "api/v1/alerts/":
            return 200, fixture("oncall_alerts.json"), "application/json"
        return 404, b'{"detail":"Not found."}', "application/json"

    def proxy(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        headers = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "connection", "accept-encoding")}
        req = urllib.request.Request(UPSTREAM + self.path, data=body, method=self.command, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                code, data, ctype = r.status, r.read(), r.headers.get("Content-Type", "application/octet-stream")
        except urllib.error.HTTPError as e:
            code, data, ctype = e.code, e.read(), e.headers.get("Content-Type", "text/plain")
        self.send(code, data, ctype)

    def handle_one(self) -> None:
        answer = self.local()
        if answer is None:
            self.proxy()
            return
        if self.command == "POST":
            self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.send(*answer)

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = handle_one


if __name__ == "__main__":
    ThreadingHTTPServer.request_queue_size = 64
    print(f"fake-irm on {SELF}, proxying the rest to {UPSTREAM}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
