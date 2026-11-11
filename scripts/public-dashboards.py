#!/usr/bin/env python3
"""Widely used public Grafana dashboards for the dev stack; see docs/dev-stack.md.

  scripts/public-dashboards.py fetch              download the pinned revisions into dev/grafana/public/
                                                  (gitignored: their licenses are their authors', never commit them)
                                                  and rewrite their datasources to the dev stack's
  scripts/public-dashboards.py import [GRAFANA..] import them into the folder "Public" (uid public) of the given
                                                  Grafanas (default: grafana12 grafana11 grafana13)
  scripts/public-dashboards.py remove [GRAFANA..] delete that folder and its dashboards again

Imported dashboards live in the Grafana database, so recreating a container drops them; rerun import.
Tokens are read from .sandbox/stack/<grafana>.token (scripts/stack.sh up) and never printed.
"""

import json
import pathlib
import sys
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "dev" / "grafana" / "public"
STATE = ROOT / ".sandbox" / "stack"
FOLDER_UID = "public"
FOLDER_TITLE = "Public"
GRAFANAS = {"grafana12": "http://127.0.0.1:3000", "grafana11": "http://127.0.0.1:3011", "grafana13": "http://127.0.0.1:3013"}

MIXINS = "https://raw.githubusercontent.com/monitoring-mixins/website/ab989b1ed06e25d243d4825913abe028a913ee4e/assets"
TEMPO = "https://raw.githubusercontent.com/grafana/tempo/v2.8.0/operations/tempo-mixin-compiled/dashboards"
DEVENV = "https://raw.githubusercontent.com/grafana/grafana/v12.3.0/devenv/dev-dashboards"


def gcom(gid, rev):
	return f"https://grafana.com/api/dashboards/{gid}/revisions/{rev}/download"


# (file stem, source URL). grafana.com entries are pinned by revision, GitHub ones by commit or tag.
SOURCES = [
	("gcom-1860-node-exporter-full", gcom(1860, 46)),
	("gcom-11074-node-exporter-en", gcom(11074, 9)),
	("gcom-3662-prometheus-2-overview", gcom(3662, 2)),
	("gcom-14282-cadvisor-exporter", gcom(14282, 1)),
	("gcom-193-docker-monitoring", gcom(193, 1)),
	("gcom-315-kubernetes-cluster", gcom(315, 3)),
	("gcom-13332-kube-state-metrics-v2", gcom(13332, 12)),
	("gcom-15761-k8s-api-server", gcom(15761, 21)),
	("gcom-13639-logs-app", gcom(13639, 2)),
	("gcom-12611-logging-via-loki", gcom(12611, 2)),
	("gcom-17781-loki-metrics", gcom(17781, 1)),
	("gcom-7587-blackbox-exporter", gcom(7587, 3)),
	("gcom-9578-alertmanager", gcom(9578, 4)),
	("gcom-3590-grafana-internals", gcom(3590, 3)),
	("gcom-763-redis-exporter", gcom(763, 6)),
	("gcom-9628-postgresql", gcom(9628, 8)),
	("gcom-7362-mysql-overview", gcom(7362, 5)),
	("gcom-23242-otel-tempo", gcom(23242, 1)),
	("mixin-k8s-resources-cluster", f"{MIXINS}/kubernetes/dashboards/k8s-resources-cluster.json"),
	("mixin-k8s-resources-namespace", f"{MIXINS}/kubernetes/dashboards/k8s-resources-namespace.json"),
	("mixin-k8s-resources-pod", f"{MIXINS}/kubernetes/dashboards/k8s-resources-pod.json"),
	("mixin-k8s-apiserver", f"{MIXINS}/kubernetes/dashboards/apiserver.json"),
	("mixin-node-exporter-nodes", f"{MIXINS}/node-exporter/dashboards/nodes.json"),
	("mixin-prometheus", f"{MIXINS}/prometheus/dashboards/prometheus.json"),
	("mixin-alertmanager-overview", f"{MIXINS}/alertmanager/dashboards/alertmanager-overview.json"),
	("mixin-grafana-overview", f"{MIXINS}/grafana/dashboards/grafana-overview.json"),
	("mixin-loki-logs", f"{MIXINS}/loki/dashboards/loki-logs.json"),
	("mixin-loki-reads", f"{MIXINS}/loki/dashboards/loki-reads.json"),
	("mixin-tempo-reads", f"{TEMPO}/tempo-reads.json"),
	("mixin-tempo-writes", f"{TEMPO}/tempo-writes.json"),
	("devenv-all-panels", f"{DEVENV}/all-panels.json"),
	("devenv-timeseries-formats", f"{DEVENV}/panel-timeseries/timeseries-formats.json"),
	("devenv-panel-stat-tests", f"{DEVENV}/panel-stat/panel-stat-tests.json"),
	("devenv-gauge-tests", f"{DEVENV}/panel-gauge/gauge_tests.json"),
	("devenv-bar-gauge-demo", f"{DEVENV}/panel-bargauge/bar_gauge_demo.json"),
	("devenv-table-kitchen-sink", f"{DEVENV}/panel-table/table_kitchen_sink.json"),
]

# Datasource plugin id -> dev stack datasource uid (dev/grafana/provisioning/datasources/datasources.yml).
DS_UIDS = {
	"prometheus": "prom3",
	"loki": "loki",
	"tempo": "tempo",
	"alertmanager": "alertmanager",
	"testdata": "testdata",
	"grafana-testdata-datasource": "testdata",
	"postgres": "postgres",
	"grafana-postgresql-datasource": "postgres",
}
DS_TYPES = {"prom3": "prometheus", "loki": "loki", "tempo": "tempo", "alertmanager": "alertmanager",
	"testdata": "grafana-testdata-datasource", "postgres": "grafana-postgresql-datasource"}
DS_NAMES = {"prom3": "Prometheus 3", "loki": "Loki", "tempo": "Tempo", "alertmanager": "Alertmanager",
	"testdata": "TestData", "postgres": "PostgreSQL"}


def die(msg):
	print(f"public-dashboards: {msg}", file=sys.stderr)
	sys.exit(1)


def get(url):
	req = urllib.request.Request(url, headers={"User-Agent": "tern-grafana-dev"})
	with urllib.request.urlopen(req, timeout=60) as r:
		return json.load(r)


def rewrite(dash, stem):
	inputs = {}
	for i in dash.pop("__inputs", None) or []:
		if i.get("type") == "datasource":
			uid = DS_UIDS.get(i.get("pluginId"))
			if uid:
				inputs[i["name"]] = uid
		elif i.get("type") == "constant":
			# Import prompts for these; a constant naming a datasource type ("Prometheus") gets its dev uid.
			value = i.get("value", "")
			inputs[i["name"]] = DS_UIDS.get(value.lower(), value)
	dash.pop("__requires", None)
	dash.pop("__elements", None)

	def ref(s):
		if isinstance(s, str) and s.startswith("$"):
			return inputs.get(s.strip("${}"))
		return None

	def walk(node):
		if isinstance(node, dict):
			for k, v in list(node.items()):
				uid = ref(v)
				if uid is not None:
					node[k] = {"type": DS_TYPES[uid], "uid": uid} if k == "datasource" and uid in DS_TYPES else uid
				elif (
					k == "datasource"
					and isinstance(v, dict)
					and v.get("type") in DS_UIDS
					and not str(v.get("uid", "")).startswith(("$", "-"))
				):
					# Exported without "share externally": the author's own datasource uid.
					v["uid"] = DS_UIDS[v["type"]]
				else:
					walk(v)
		elif isinstance(node, list):
			for v in node:
				walk(v)

	walk(dash)
	for v in (dash.get("templating") or {}).get("list") or []:
		if v.get("type") == "datasource":
			uid = DS_UIDS.get(v.get("query"))
			if uid:
				v["current"] = {"selected": True, "text": DS_NAMES[uid], "value": uid}
	dash["id"] = None
	dash["uid"] = ("pub-" + stem)[:40]
	return dash


def fetch():
	OUT.mkdir(parents=True, exist_ok=True)
	failed = []
	for stem, url in SOURCES:
		try:
			dash = rewrite(get(url), stem)
		except (urllib.error.URLError, json.JSONDecodeError, TimeoutError) as e:
			failed.append(f"{stem}: {e}")
			continue
		(OUT / f"{stem}.json").write_text(json.dumps(dash, indent=2) + "\n")
		print(f"fetched {stem}: {dash.get('title')}")
	if failed:
		die("failed: " + "; ".join(failed))


def api(grafana, method, path, body=None):
	tok = STATE / f"{grafana}.token"
	if not tok.exists():
		die(f"no token for {grafana}; run scripts/stack.sh up")
	data = json.dumps(body).encode() if body is not None else None
	req = urllib.request.Request(GRAFANAS[grafana] + path, data=data, method=method)
	req.add_header("Authorization", "Bearer " + tok.read_text().strip())
	req.add_header("Content-Type", "application/json")
	try:
		with urllib.request.urlopen(req, timeout=30) as r:
			return r.status, json.load(r)
	except urllib.error.HTTPError as e:
		return e.code, None
	except (urllib.error.URLError, ConnectionError, TimeoutError):
		return 0, None


def targets(args):
	for g in args:
		if g not in GRAFANAS:
			die(f"unknown grafana {g}; one of {' '.join(GRAFANAS)}")
	return args or list(GRAFANAS)


def import_(args):
	files = sorted(OUT.glob("*.json"))
	if not files:
		die("nothing fetched; run fetch first")
	for g in targets(args):
		status, _ = api(g, "GET", f"/api/folders/{FOLDER_UID}")
		if status not in (200, 404):
			reason = "not reachable" if status == 0 else f"HTTP {status} (stale token? scripts/stack.sh up)"
			print(f"{g}: {reason}, skipped", file=sys.stderr)
			continue
		if status == 404:
			status, _ = api(g, "POST", "/api/folders", {"uid": FOLDER_UID, "title": FOLDER_TITLE})
			if status != 200:
				die(f"{g}: creating folder failed ({status})")
		ok = 0
		for f in files:
			body = {"dashboard": json.loads(f.read_text()), "folderUid": FOLDER_UID, "overwrite": True}
			status, _ = api(g, "POST", "/api/dashboards/db", body)
			if status == 200:
				ok += 1
			else:
				print(f"{g}: {f.stem} rejected ({status})", file=sys.stderr)
		print(f"{g}: imported {ok}/{len(files)} into folder {FOLDER_TITLE}")


def remove(args):
	for g in targets(args):
		status, _ = api(g, "DELETE", f"/api/folders/{FOLDER_UID}?forceDeleteRules=false")
		print(f"{g}: remove folder {FOLDER_TITLE}: {status}")


def main():
	cmd, args = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else ("", [])
	if cmd == "fetch":
		fetch()
	elif cmd == "import":
		import_(args)
	elif cmd == "remove":
		remove(args)
	else:
		print(__doc__, file=sys.stderr)
		sys.exit(2)


if __name__ == "__main__":
	main()
