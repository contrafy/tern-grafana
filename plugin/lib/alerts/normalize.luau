--!strict
-- Turns every alert API the plugin reads into one Alert model:
--   * Alertmanager v2 `/api/v2/alerts` and `/api/v2/alerts/groups`, served by
--     Alertmanager itself, by Grafana's built-in Alertmanager
--     (`/api/alertmanager/grafana/...`) or by Grafana's proxy to an external
--     one (`/api/alertmanager/<uid>/...`);
--   * Prometheus `/api/v1/alerts` and `/api/v1/rules`, and Grafana's
--     Prometheus-compatible view of its own rules
--     (`/api/prometheus/grafana/api/v1/{alerts,rules}`).
-- An Alertmanager never sees pending alerts, so Grafana-managed alerting is
-- read from both sides and merged (`merge`).

local Env = require("../env")
local Range = require("../time/range")

type Env = Env.Env

export type State = "firing" | "pending" | "silenced" | "inhibited" | "resolved"
export type Source = "alertmanager" | "grafana" | "prometheus"
export type Severity = "critical" | "error" | "warning" | "info" | "none"

export type Alert = {
	-- Alertmanager's label fingerprint (computed the same way for Prometheus
	-- alerts, so one alert keeps its identity across sources).
	fingerprint: string,
	labels: { [string]: string },
	annotations: { [string]: string },
	state: State,
	starts_at_ms: number,
	ends_at_ms: number?,
	generator_url: string?,
	source: Source,
	severity: Severity,
	-- annotations.summary, else the first line of the description, else alertname.
	summary: string,
	description: string?,
	runbook_url: string?,
	-- Grafana's `__dashboardUid__` / `__panelId__` annotations.
	dashboard_uid: string?,
	panel_id: number?,
	-- A `dashboard_url` annotation (Prometheus rules often carry one).
	dashboard_url: string?,
	-- Grafana's `__alert_rule_uid__` label.
	rule_uid: string?,
	value: string?,
	silenced_by: { string },
	inhibited_by: { string },
	receivers: { string },
	context: string,
}

export type Rule = {
	name: string,
	group: string,
	file: string,
	type: "alerting" | "recording",
	-- Alerting rules: "firing" | "pending" | "inactive"; nil for recording rules.
	state: string?,
	health: string,
	last_error: string?,
	last_evaluation_ms: number?,
	evaluation_s: number?,
	query: string,
	duration_s: number?,
	labels: { [string]: string },
	annotations: { [string]: string },
	-- Grafana-managed rules only.
	uid: string?,
	-- Grafana: the rule is paused (not evaluated).
	paused: boolean,
	-- Grafana 12: the datasources the rule queries.
	datasource_uids: { string },
	-- The group's evaluation interval.
	interval_s: number?,
	alerts: { Alert },
	source: Source,
	context: string,
}

export type Parsed<T> = { ok: true, items: { T } } | { ok: false, error: string }

local M = {}
local SEVERITY_RANK: { [Severity]: number } = {
	critical = 5,
	error = 4,
	warning = 3,
	info = 2,
	none = 1,
}
M.SEVERITY_RANK = table.freeze(SEVERITY_RANK)

local SEVERITY_ALIASES: { [string]: Severity } = {
	critical = "critical",
	crit = "critical",
	fatal = "critical",
	page = "critical",
	error = "error",
	err = "error",
	warning = "warning",
	warn = "warning",
	info = "info",
	informational = "info",
	notice = "info",
}

-- Annotations Grafana adds for its own use; the inbox shows them as fields.
local INTERNAL_ANNOTATIONS = {
	__dashboardUid__ = true,
	__panelId__ = true,
	__orgId__ = true,
	__values__ = true,
	__value_string__ = true,
}

function M.severity(labels: { [string]: string }): Severity
	local raw = labels.severity or labels.level or labels.priority
	if raw == nil then
		return "none"
	end
	return SEVERITY_ALIASES[string.lower(raw)] or "none"
end

-- Labels and annotations hidden from the detail view: Grafana's and
-- Prometheus' reserved `__x__` names.
function M.isInternal(name: string): boolean
	return INTERNAL_ANNOTATIONS[name] == true or (string.sub(name, 1, 2) == "__" and string.sub(name, -2) == "__")
end

-- FNV-1a 64-bit over 16-bit limbs (Luau numbers are doubles).
local OFFSET = { 0x2325, 0x8422, 0x9ce4, 0xcbf2 } -- 14695981039346656037
local PRIME = { 0x01b3, 0x0000, 0x0100, 0x0000 } -- 1099511628211

local function mulPrime(h: { number })
	local r = { 0, 0, 0, 0 }
	for i = 1, 4 do
		local carry = 0
		for j = 1, 5 - i do
			local cur = r[i + j - 1] + h[i] * PRIME[j] + carry
			r[i + j - 1] = cur % 65536
			carry = cur // 65536
		end
	end
	for i = 1, 4 do
		h[i] = r[i]
	end
end

local function addByte(h: { number }, b: number)
	h[1] = bit32.bxor(h[1], b)
	mulPrime(h)
end

local function addString(h: { number }, s: string)
	for i = 1, #s do
		addByte(h, string.byte(s, i))
	end
end

-- Alertmanager's `model.LabelSet.Fingerprint()`, as %016x.
function M.fingerprint(labels: { [string]: string }): string
	local names: { string } = {}
	for name in labels do
		table.insert(names, name)
	end
	if #names == 0 then
		-- model.emptyLabelSignature: the FNV offset basis itself.
		return "cbf29ce484222325"
	end
	table.sort(names)
	local h = table.clone(OFFSET)
	for _, name in names do
		addString(h, name)
		addByte(h, 255)
		addString(h, labels[name])
		addByte(h, 255)
	end
	return string.format("%04x%04x%04x%04x", h[4], h[3], h[2], h[1])
end

local function str(env: Env, v: any): string?
	v = Env.value(env, v)
	if type(v) == "string" then
		return v
	elseif type(v) == "number" then
		return tostring(v)
	end
	return nil
end

local function strMap(env: Env, v: any): { [string]: string }
	local out: { [string]: string } = {}
	if type(v) == "table" then
		for k, val in v do
			local s = str(env, val)
			if type(k) == "string" and s then
				out[k] = s
			end
		end
	end
	return out
end

local function strList(env: Env, v: any, field: string?): { string }
	local out: { string } = {}
	if type(v) == "table" then
		for _, item in v do
			local s = if field and type(item) == "table" then str(env, item[field]) else str(env, item)
			if s then
				table.insert(out, s)
			end
		end
	end
	return out
end

local function time(env: Env, v: any): number?
	local s = str(env, v)
	if s == nil or s == "" or string.sub(s, 1, 4) == "0001" then
		return nil
	end
	return (Range.parse(s, false, { now_ms = env.now_ms }))
end

local function num(env: Env, v: any): number?
	v = Env.value(env, v)
	return if type(v) == "number" then v else nil
end

local function firstLine(s: string): string
	return string.match(s, "^[^\n]*") or s
end

-- Fields every source derives the same way from labels and annotations.
local function enrich(alert: Alert)
	local a = alert.annotations
	local l = alert.labels
	alert.severity = M.severity(l)
	alert.description = a.description
	alert.summary = if a.summary and a.summary ~= ""
		then a.summary
		elseif a.description and a.description ~= "" then firstLine(a.description)
		else l.alertname or "(unnamed alert)"
	alert.runbook_url = if a.runbook_url and a.runbook_url ~= "" then a.runbook_url else nil
	alert.dashboard_uid = if a.__dashboardUid__ and a.__dashboardUid__ ~= "" then a.__dashboardUid__ else nil
	alert.panel_id = if a.__panelId__ then tonumber(a.__panelId__) else nil
	alert.dashboard_url = if a.dashboard_url and a.dashboard_url ~= "" then a.dashboard_url else nil
	alert.rule_uid = l.__alert_rule_uid__
end

local function blank(context: string, source: Source): Alert
	return {
		fingerprint = "",
		labels = {},
		annotations = {},
		state = "firing",
		starts_at_ms = 0,
		source = source,
		severity = "none",
		summary = "",
		silenced_by = {},
		inhibited_by = {},
		receivers = {},
		context = context,
	}
end

-- One Alertmanager v2 `gettableAlert`.
local function amAlert(env: Env, raw: any, context: string, source: Source): Alert?
	if type(raw) ~= "table" then
		return nil
	end
	local alert = blank(context, source)
	alert.labels = strMap(env, raw.labels)
	alert.annotations = strMap(env, raw.annotations)
	alert.fingerprint = str(env, raw.fingerprint) or M.fingerprint(alert.labels)
	alert.starts_at_ms = time(env, raw.startsAt) or 0
	alert.ends_at_ms = time(env, raw.endsAt)
	alert.generator_url = str(env, raw.generatorURL)
	alert.receivers = strList(env, raw.receivers, "name")
	local status = Env.value(env, raw.status)
	local amState = if type(status) == "table" then str(env, status.state) else nil
	if type(status) == "table" then
		alert.silenced_by = strList(env, status.silencedBy)
		alert.inhibited_by = strList(env, status.inhibitedBy)
	end
	if amState == "suppressed" then
		-- A silence wins over an inhibition, as in Alertmanager's own UI.
		alert.state = if #alert.silenced_by > 0
			then "silenced"
			elseif #alert.inhibited_by > 0 then "inhibited"
			else "silenced"
	else
		-- "active" and "unprocessed" both still notify.
		alert.state = "firing"
	end
	-- Resolved alerts carry an endsAt no later than their last update; an
	-- active one is pushed into the future by the resolve timeout.
	local updated = time(env, raw.updatedAt)
	if alert.ends_at_ms and updated and (alert.ends_at_ms :: number) <= updated then
		alert.state = "resolved"
	end
	enrich(alert)
	return alert
end

-- Prometheus alert states, and Grafana's own in its Prometheus-compatible
-- API ("Alerting", "Pending", "Normal", "NoData", "Error", "Recovering",
-- "Alerting (NoData)" ...). Inactive ones are not alerts.
local function promState(s: string?): State?
	if s == nil then
		return nil
	end
	local lower = string.lower(s)
	if lower == "firing" or string.sub(lower, 1, 8) == "alerting" or lower == "recovering" then
		return "firing"
	elseif lower == "pending" then
		return "pending"
	elseif lower == "nodata" or lower == "error" then
		-- Grafana's default no-data/error handling notifies.
		return "firing"
	end
	return nil
end

local function promAlert(env: Env, raw: any, context: string, source: Source): Alert?
	if type(raw) ~= "table" then
		return nil
	end
	local state = promState(str(env, raw.state))
	if state == nil then
		return nil
	end
	local alert = blank(context, source)
	alert.labels = strMap(env, raw.labels)
	alert.annotations = strMap(env, raw.annotations)
	alert.fingerprint = M.fingerprint(alert.labels)
	alert.state = state :: State
	alert.starts_at_ms = time(env, raw.activeAt) or 0
	local value = str(env, raw.value)
	alert.value = if value and value ~= "" then value else nil
	enrich(alert)
	return alert
end

local function decode(env: Env, body: string): (any, string?)
	local ok, doc = pcall(env.decode, body)
	if not ok then
		return nil, "response is not JSON"
	end
	return doc, nil
end

local function promData(env: Env, body: string): (any, string?)
	local doc, err = decode(env, body)
	if err then
		return nil, err
	end
	if type(doc) ~= "table" then
		return nil, "unexpected response"
	end
	if doc.status ~= "success" then
		return nil, str(env, doc.error) or "request failed"
	end
	local data = Env.value(env, doc.data)
	if type(data) ~= "table" then
		return nil, "response has no data"
	end
	return data, nil
end

-- Alertmanager v2 `/api/v2/alerts` (any of the three servers).
function M.parseAlertmanager(env: Env, body: string, context: string, source: Source): Parsed<Alert>
	local doc, err = decode(env, body)
	if err then
		return { ok = false, error = err :: string }
	end
	if type(doc) ~= "table" then
		return { ok = false, error = "expected a JSON array of alerts" }
	end
	local items: { Alert } = {}
	for _, raw in doc do
		local a = amAlert(env, raw, context, source)
		if a then
			table.insert(items, a)
		end
	end
	return { ok = true, items = items }
end

-- Alertmanager v2 `/api/v2/alerts/groups`: the alerts of every group, each
-- once (an alert routed to several receivers appears in several groups).
function M.parseAlertmanagerGroups(env: Env, body: string, context: string, source: Source): Parsed<Alert>
	local doc, err = decode(env, body)
	if err then
		return { ok = false, error = err :: string }
	end
	if type(doc) ~= "table" then
		return { ok = false, error = "expected a JSON array of alert groups" }
	end
	local items: { Alert } = {}
	local seen: { [string]: boolean } = {}
	for _, group in doc do
		if type(group) == "table" and type(group.alerts) == "table" then
			for _, raw in group.alerts do
				local a = amAlert(env, raw, context, source)
				if a and not seen[a.fingerprint] then
					seen[a.fingerprint] = true
					table.insert(items, a)
				end
			end
		end
	end
	return { ok = true, items = items }
end

-- Prometheus `/api/v1/alerts` and Grafana's `/api/prometheus/grafana/api/v1/alerts`.
function M.parsePrometheusAlerts(env: Env, body: string, context: string, source: Source): Parsed<Alert>
	local data, err = promData(env, body)
	if err then
		return { ok = false, error = err :: string }
	end
	local items: { Alert } = {}
	if type(data.alerts) == "table" then
		for _, raw in data.alerts do
			local a = promAlert(env, raw, context, source)
			if a then
				table.insert(items, a)
			end
		end
	end
	return { ok = true, items = items }
end

-- Prometheus `/api/v1/rules` and Grafana's `/api/prometheus/grafana/api/v1/rules`.
function M.parseRules(env: Env, body: string, context: string, source: Source): Parsed<Rule>
	local data, err = promData(env, body)
	if err then
		return { ok = false, error = err :: string }
	end
	local items: { Rule } = {}
	if type(data.groups) ~= "table" then
		return { ok = true, items = items }
	end
	for _, g in data.groups do
		if type(g) == "table" and type(g.rules) == "table" then
			local groupName = str(env, g.name) or ""
			local file = str(env, g.file) or ""
			local interval = num(env, g.interval)
			for _, r in g.rules do
				if type(r) == "table" then
					local kind: "alerting" | "recording" = if str(env, r.type) == "recording"
						then "recording"
						else "alerting"
					local lastError = str(env, r.lastError)
					local rule: Rule = {
						name = str(env, r.name) or "",
						group = groupName,
						file = file,
						type = kind,
						state = if kind == "alerting" then str(env, r.state) else nil,
						health = str(env, r.health) or "unknown",
						last_error = if lastError and lastError ~= "" then lastError else nil,
						last_evaluation_ms = time(env, r.lastEvaluation),
						evaluation_s = num(env, r.evaluationTime),
						query = str(env, r.query) or "",
						duration_s = num(env, r.duration),
						labels = strMap(env, r.labels),
						annotations = strMap(env, r.annotations),
						uid = str(env, r.uid),
						paused = Env.value(env, r.isPaused) == true,
						datasource_uids = strList(env, Env.value(env, r.queriedDatasourceUIDs)),
						interval_s = interval,
						alerts = {},
						source = source,
						context = context,
					}
					if type(r.alerts) == "table" then
						for _, raw in r.alerts do
							local a = promAlert(env, raw, context, source)
							if a then
								table.insert(rule.alerts, a)
							end
						end
					end
					table.insert(items, rule)
				end
			end
		end
	end
	return { ok = true, items = items }
end

-- Grafana-managed alerting: the Alertmanager's view (firing, silenced,
-- inhibited) plus the pending alerts only the rule evaluator knows about.
-- Firing alerts from the rule side are dropped: the Alertmanager copy
-- carries silences and inhibitions.
function M.merge(alertmanager: { Alert }, rules: { Alert }): { Alert }
	local out = table.clone(alertmanager)
	local seen: { [string]: boolean } = {}
	for _, a in alertmanager do
		seen[a.fingerprint] = true
	end
	for _, a in rules do
		if a.state == "pending" and not seen[a.fingerprint] then
			seen[a.fingerprint] = true
			table.insert(out, a)
		end
	end
	return out
end

return M
