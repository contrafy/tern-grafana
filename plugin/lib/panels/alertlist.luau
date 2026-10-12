--!strict
-- The alert list panel, unified alerting (public/app/plugins/panel/alertlist
-- at v12.4.0: UnifiedAlertList.tsx, unified-alerting/UngroupedView.tsx and
-- GroupedView.tsx, AlertInstances.tsx, util.ts filterAlerts, types.ts,
-- module.tsx defaults; app/features/alerting/unified/utils/rules.ts
-- getFirstActiveAt / alertStateToReadable / alertStateToState, utils/misc.ts
-- sortAlerts, app/features/alerting/state/alertDef.ts alertStateSortScore;
-- which rules sources: utils/datasource.ts getAllRulesSourceNames /
-- getRulesDataSources / isDataSourceManagingAlerts, api/prometheus.ts
-- prometheusUrlBuilder, state/actions.ts fetchAllPromAndRulerRulesAction).
--
-- Rules sources follow options.datasource as UnifiedAlertList does:
-- "grafana" (or "-- Grafana --") reads Grafana-managed rules from
-- `/api/prometheus/grafana/api/v1/rules` with the instance limit
-- (INSTANCES_DISPLAY_LIMIT = 15); a data source name reads that data
-- source's rules through `/api/prometheus/<uid>/api/v1/rules`; unset reads
-- Grafana-managed rules plus every Prometheus-flavored or Loki data source
-- that manages alerts (at most MAX_EXTERNAL of them, the rest named as not
-- read). All rules are combined, sorted (sortRules) and filtered
-- (filterRules/filterAlerts: state, alert name, instance labels, folder,
-- rules linked to this dashboard) as in the browser; a data source that
-- fails is left out, as Grafana leaves out a rejected source. viewMode stat
-- is the matching rule count; list in groupMode default lists rules
-- (maxItems), custom groups the instances by the groupBy labels. "View
-- alert rule" opens the native alerts block's rules view on that rule.
--
-- Instance rows have no expand toggle: showInstances decides, as it does on
-- load in Grafana.

local Assets = require("../render/assets")
local Common = require("./common")
local Env = require("../env")
local Frame = require("../frame/types")
local Http = require("../transport/http")
local Json = require("./json")
local Matchers = require("../silences/matchers")
local Response = require("../source/response")
local Scheme = require("../links/scheme")
local Stat = require("./stat")
local TransportTypes = require("../transport/types")
local ui = require("../ui")

type Env = Env.Env
type Node = ui.Node

local M = {}

M.types = { "alertlist" }

-- AlertInstances / RuleDetails INSTANCES_DISPLAY_LIMIT.
M.INSTANCES_LIMIT = 15

-- Request tags: Grafana-managed rules "rules:<sources not read>:<dashboard
-- uid>", a data source's rules "ds:<uid>".
local TAG_GRAFANA = "rules:"
local TAG_DS = "ds:"

-- Data sources read when the panel reads every rules source.
M.MAX_EXTERNAL = 8

-- SUPPORTED_EXTERNAL_RULE_SOURCE_TYPES (Grafana 12; Grafana 11: loki, prometheus).
local EXTERNAL_TYPES: { [string]: boolean } = {
	loki = true,
	prometheus = true,
	["grafana-amazonprometheus-datasource"] = true,
	["grafana-azureprometheus-datasource"] = true,
}

export type Instance = {
	-- As Grafana sends it ("Alerting", "Normal (NoData)", "firing" ...).
	state: string,
	labels: { [string]: string },
	active_ms: number?,
}

export type Rule = {
	name: string,
	uid: string?,
	-- firing | pending | inactive | recovering (Prometheus rule states).
	state: string,
	folder_uid: string?,
	annotations: { [string]: string },
	instances: { Instance },
	-- Grafana's instance totals by state (Grafana-managed rules only).
	totals: { [string]: number }?,
	-- "grafana" or the data source uid.
	source: string,
}

export type Answer = { rules: { Rule } } | { error: string }

export type StateFilter = {
	firing: boolean,
	pending: boolean,
	recovering: boolean,
	noData: boolean,
	normal: boolean,
	error: boolean,
	inactive: boolean,
}

export type Options = {
	viewMode: string,
	groupMode: string,
	groupBy: { string },
	maxItems: number,
	sortOrder: number,
	dashboardAlerts: boolean,
	alertName: string,
	alertInstanceLabelFilter: string,
	showInstances: boolean,
	showInactiveAlerts: boolean,
	folder_uid: string?,
	datasource: string?,
	-- Whether stateFilter was present and had any key (lodash isEmpty).
	has_state_filter: boolean,
	stateFilter: StateFilter,
}

-- SortOrder (types.ts).
local ALPHA_ASC, ALPHA_DESC, IMPORTANCE, TIME_ASC, TIME_DESC = 1, 2, 3, 4, 5

-- module.tsx defaults.
function M.options(panel: any, env: Env): Options
	local o = Json.obj(env, Json.path(env, panel, "options"))
	local sf = Json.tbl(env, o.stateFilter)
	local function flag(name: string, default: boolean): boolean
		local v = if sf then Json.bool(env, sf[name]) else nil
		if v == nil then
			return default
		end
		return v
	end
	local groupBy: { string } = {}
	for _, g in Json.list(env, o.groupBy) do
		local s = Json.str(env, g)
		if s then
			table.insert(groupBy, s)
		end
	end
	local stateFilter: StateFilter = {
		firing = flag("firing", true),
		pending = flag("pending", true),
		recovering = flag("recovering", true),
		noData = flag("noData", false),
		normal = flag("normal", false),
		error = flag("error", true),
		inactive = flag("inactive", false),
	}
	-- UnifiedAlertList: the legacy `inactive` flag turns `normal` on.
	if stateFilter.inactive then
		stateFilter.normal = true
	end
	local hasStateFilter = sf == nil or next(sf) ~= nil
	local folder = Json.tbl(env, o.folder)
	local folderUid = if folder then Json.str(env, folder.uid) else nil
	return {
		viewMode = Json.str(env, o.viewMode) or "list",
		groupMode = Json.str(env, o.groupMode) or "default",
		groupBy = groupBy,
		maxItems = Json.num(env, o.maxItems) or 20,
		sortOrder = Json.num(env, o.sortOrder) or ALPHA_ASC,
		dashboardAlerts = Json.bool(env, o.dashboardAlerts) == true,
		alertName = Json.str(env, o.alertName) or "",
		alertInstanceLabelFilter = Json.str(env, o.alertInstanceLabelFilter) or "",
		showInstances = Json.bool(env, o.showInstances) == true,
		showInactiveAlerts = Json.bool(env, o.showInactiveAlerts) == true,
		folder_uid = if folderUid and folderUid ~= "" then folderUid else nil,
		datasource = Json.str(env, o.datasource),
		has_state_filter = hasStateFilter,
		stateFilter = stateFilter,
	}
end

function M.supports(_: any, _env: Env): (boolean, string?)
	return true, nil
end

function M.queries(_: any): boolean
	return false
end

local GRAFANA_DATASOURCE_NAME = "-- Grafana --"

export type Source = { uid: string, type: string, name: string, is_default: boolean, manage_alerts: boolean? }

-- The rules sources the panel reads: whether Grafana-managed rules are read,
-- the data sources to read and the ones left out by MAX_EXTERNAL; nil while
-- the data sources are not known.
function M.sources(o: Options, datasources: { Source }?): (boolean?, { Source }, number)
	local ds = o.datasource
	if ds == "grafana" or ds == GRAFANA_DATASOURCE_NAME then
		return true, {}, 0
	end
	if datasources == nil then
		return nil, {}, 0
	end
	local list = datasources :: { Source }
	if ds ~= nil and ds ~= "" then
		for _, d in list do
			if d.name == ds then
				return false, { d }, 0
			end
		end
		-- getDatasourceAPIUid: an unknown name is used as given (Grafana
		-- answers that the data source does not exist).
		return false, { { uid = ds :: string, type = "prometheus", name = ds :: string, is_default = false } }, 0
	end
	-- getRulesDataSources: supported types managing alerts, by name.
	local external: { Source } = {}
	for _, d in list do
		if EXTERNAL_TYPES[d.type] and d.manage_alerts ~= false then
			table.insert(external, d)
		end
	end
	table.sort(external, function(a: Source, b: Source): boolean
		return string.lower(a.name) < string.lower(b.name)
	end)
	local skipped = math.max(#external - M.MAX_EXTERNAL, 0)
	for _ = 1, skipped do
		table.remove(external)
	end
	return true, external, skipped
end

-- The Grafana tag carries the dashboard uid ("Alerts linked to this
-- dashboard" compares rule annotations with it) and how many data sources
-- were left out.
function M.requests(panel: any, ctx: Common.RequestContext, env: Env): { Common.PanelRequest }
	local grafana, external, skipped = M.sources(M.options(panel, env), ctx.datasources)
	if grafana == nil then
		return {}
	end
	local out: { Common.PanelRequest } = {}
	if grafana then
		table.insert(out, {
			tag = string.format("%s%d:%s", TAG_GRAFANA, skipped :: number, ctx.dashboard_uid or ""),
			signal = "alerts",
			request = {
				method = "GET",
				path = "/api/prometheus/grafana/api/v1/rules",
				query = { { "limit_alerts", tostring(M.INSTANCES_LIMIT) } },
			},
		})
	end
	-- prometheusUrlBuilder: no instance limit for data source rules.
	for _, d in external :: { Source } do
		table.insert(out, {
			tag = TAG_DS .. d.uid,
			signal = "alerts",
			request = { method = "GET", path = "/api/prometheus/" .. Http.escape(d.uid) .. "/api/v1/rules" },
		})
	end
	return out
end

local function strMap(env: Env, v: any): { [string]: string }
	local out: { [string]: string } = {}
	local t = Json.tbl(env, v)
	if t then
		for k, x in t do
			if type(k) == "string" and type(x) == "string" then
				out[k] = x
			end
		end
	end
	return out
end

local function daysFromCivil(y: number, m: number, d: number): number
	y = if m <= 2 then y - 1 else y
	local era = y // 400
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

local function civilFromDays(z: number): (number, number, number)
	z += 719468
	local era = z // 146097
	local doe = z - era * 146097
	local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	local y = yoe + era * 400
	local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	local mp = (5 * doy + 2) // 153
	local d = doy - (153 * mp + 2) // 5 + 1
	local m = if mp < 10 then mp + 3 else mp - 9
	return if m <= 2 then y + 1 else y, m, d
end

-- RFC 3339 (Grafana's activeAt) to epoch ms; Go's zero time is no time.
function M.parseTime(s: string?): number?
	if s == nil then
		return nil
	end
	local y, mo, d, h, mi, sec, rest = string.match(s, "^(%d+)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$")
	if y == nil then
		return nil
	end
	local year = tonumber(y) :: number
	if year <= 1 then
		return nil
	end
	local frac = string.match(rest :: string, "^%.(%d+)") or ""
	local zone = string.sub(rest :: string, if frac ~= "" then #frac + 2 else 1)
	local offset = 0
	if zone ~= "Z" and zone ~= "z" and zone ~= "" then
		local sign, zh, zm = string.match(zone, "^([+-])(%d%d):?(%d%d)$")
		if sign == nil then
			return nil
		end
		offset = ((tonumber(zh) :: number) * 60 + (tonumber(zm) :: number)) * (if sign == "-" then -1 else 1)
	end
	local days = daysFromCivil(year, tonumber(mo) :: number, tonumber(d) :: number)
	local ms = ((days * 24 + (tonumber(h) :: number)) * 60 + (tonumber(mi) :: number) - offset) * 60000
		+ (tonumber(sec) :: number) * 1000
	if frac ~= "" then
		ms += math.floor((tonumber("0." .. frac) :: number) * 1000)
	end
	return ms
end

function M.parse(_: any, tag: string, response: TransportTypes.Response, env: Env): Answer
	local source = if string.sub(tag, 1, #TAG_DS) == TAG_DS then string.sub(tag, #TAG_DS + 1) else "grafana"
	local grafana = source == "grafana"
	local doc, err = Response.json(response, env, "alert rules")
	if err then
		return { error = err.message }
	end
	if Json.str(env, doc.status) ~= "success" then
		return { error = Json.str(env, doc.error) or "the alert rules request failed" }
	end
	local rules: { Rule } = {}
	for _, g in Json.list(env, Json.path(env, doc, "data", "groups")) do
		-- Data source rules have no folder (their namespace is the file).
		local folderUid = if grafana then Json.str(env, Json.path(env, g, "folderUid")) else nil
		for _, r in Json.list(env, Json.path(env, g, "rules")) do
			-- Only alerting rules are listed (getAlertingRule).
			if Json.str(env, Json.path(env, r, "type")) ~= "alerting" then
				continue
			end
			local instances: { Instance } = {}
			for _, a in Json.list(env, r.alerts) do
				local st = Json.str(env, Json.path(env, a, "state"))
				if st then
					table.insert(instances, {
						state = st,
						labels = strMap(env, a.labels),
						active_ms = M.parseTime(Json.str(env, a.activeAt)),
					})
				end
			end
			local totals: { [string]: number }? = nil
			local rawTotals = if grafana then Json.tbl(env, r.totals) else nil
			if rawTotals then
				local t: { [string]: number } = {}
				for k, v in rawTotals do
					if type(k) == "string" and type(v) == "number" then
						t[string.lower(k)] = v
					end
				end
				totals = t
			end
			table.insert(rules, {
				name = Json.str(env, r.name) or "",
				uid = Json.str(env, r.uid),
				-- normalizeRuleGroup: an alerting rule without a state is inactive.
				state = Json.str(env, r.state) or "inactive",
				folder_uid = folderUid,
				annotations = strMap(env, r.annotations),
				instances = instances,
				totals = totals,
				source = source,
			})
		end
	end
	return { rules = rules }
end

-- State model ---------------------------------------------------------------------------

-- mapStateWithReasonToBaseState: "Alerting (NoData)" -> "Alerting".
local function baseState(s: string): string
	return string.match(s, "^(.-) %(") or s
end

-- filterAlerts (util.ts) for one instance's state.
local function stateAllowed(f: StateFilter, s: string): boolean
	local b = baseState(s)
	return (f.firing and (b == "Alerting" or b == "firing"))
		or (f.pending and (b == "Pending" or b == "pending"))
		or (f.recovering and (b == "Recovering" or b == "recovering"))
		or (f.noData and b == "NoData")
		or (f.normal and b == "Normal")
		or (f.error and b == "Error")
		or (f.inactive and b == "inactive")
end

-- Grafana's instance totals keys, by the stateFilter flag that keeps them.
local TOTAL_FLAG: { [string]: string } = {
	alerting = "firing",
	firing = "firing",
	pending = "pending",
	recovering = "recovering",
	nodata = "noData",
	normal = "normal",
	error = "error",
}

-- parsePromQLStyleMatcherLooseSafe: an unparsable filter filters nothing.
local function labelFilter(text: string): Matchers.Compiled?
	if text == "" then
		return nil
	end
	local list = Matchers.parseList(text)
	if list == nil or #list == 0 then
		return nil
	end
	return (Matchers.compile(list))
end

local function filterInstances(o: Options, f: Matchers.Compiled?, list: { Instance }): { Instance }
	if not o.has_state_filter then
		return list
	end
	local out: { Instance } = {}
	for _, a in list do
		if stateAllowed(o.stateFilter, a.state) and (f == nil or Matchers.matches(f, a.labels)) then
			table.insert(out, a)
		end
	end
	return out
end

-- getFirstActiveAt: the earliest activeAt of the non-Normal instances.
function M.firstActiveAt(rule: Rule): number?
	local first: number? = nil
	for _, a in rule.instances do
		if baseState(a.state) ~= "Normal" and a.active_ms then
			if first == nil or (a.active_ms :: number) < (first :: number) then
				first = a.active_ms
			end
		end
	end
	return first
end

-- alertStateToReadable.
function M.readable(state: string): string
	if state == "inactive" then
		return "Normal"
	end
	return string.upper(string.sub(state, 1, 1)) .. string.lower(string.sub(state, 2))
end

-- alertStateToState -> span token.
function M.tone(state: string): string
	local b = string.lower(baseState(state))
	if b == "inactive" or b == "normal" then
		return "success"
	elseif b == "firing" or b == "alerting" or b == "error" then
		return "error"
	elseif b == "pending" or b == "recovering" then
		return "warning"
	elseif b == "nodata" then
		return "info"
	end
	return "muted"
end

local SORT_SCORE: { [string]: number } =
	{ alerting = 1, firing = 1, no_data = 2, pending = 3, ok = 4, paused = 5, inactive = 5 }

local function stableSort<T>(list: { T }, key: (T) -> any)
	local idx: { [T]: number } = {}
	for i, v in list do
		idx[v] = i
	end
	table.sort(list, function(a: T, b: T): boolean
		local ka, kb = key(a), key(b)
		if ka ~= kb then
			return ka < kb
		end
		return idx[a] < idx[b]
	end)
end

local function reverse<T>(list: { T })
	local n = #list
	for i = 1, n // 2 do
		list[i], list[n + 1 - i] = list[n + 1 - i], list[i]
	end
end

-- sortRules (UnifiedAlertList.tsx).
local function sortRules(order: number, rules: { Rule }, now: number): { Rule }
	local out = table.clone(rules)
	if order == IMPORTANCE then
		-- lodash sortBy puts an undefined score (recovering) last.
		stableSort(out, function(r: Rule): any
			return SORT_SCORE[r.state] or math.huge
		end)
	elseif order == TIME_ASC or order == TIME_DESC then
		stableSort(out, function(r: Rule): any
			return M.firstActiveAt(r) or now
		end)
		if order == TIME_DESC then
			reverse(out)
		end
	else
		stableSort(out, function(r: Rule): any
			return string.lower(r.name)
		end)
		if order == ALPHA_DESC then
			reverse(out)
		end
	end
	return out
end

export type Row = {
	rule: Rule,
	-- The rule's instances through the panel filters, in sortAlerts order.
	instances: { Instance },
	-- AlertInstances: the count shown and the instances hidden by filters.
	count: number,
	hidden: number,
}

local function instanceKey(a: Instance): string
	local names: { string } = {}
	for k in a.labels do
		table.insert(names, k)
	end
	table.sort(names)
	local parts: { string } = {}
	for _, k in names do
		table.insert(parts, k .. "=" .. a.labels[k])
	end
	return string.lower(table.concat(parts, ","))
end

-- sortAlerts (utils/misc.ts).
local function sortInstances(order: number, list: { Instance }, now: number): { Instance }
	local out = table.clone(list)
	local function tie(a: Instance, b: Instance): boolean
		return instanceKey(a) < instanceKey(b)
	end
	if order == IMPORTANCE then
		table.sort(out, function(a: Instance, b: Instance): boolean
			local sa = SORT_SCORE[string.lower(baseState(a.state))] or math.huge
			local sb = SORT_SCORE[string.lower(baseState(b.state))] or math.huge
			if sa ~= sb then
				return sa < sb
			end
			return tie(a, b)
		end)
	elseif order == TIME_ASC or order == TIME_DESC then
		table.sort(out, function(a: Instance, b: Instance): boolean
			local ta, tb = a.active_ms or now, b.active_ms or now
			if ta ~= tb then
				return ta < tb
			end
			return tie(a, b)
		end)
		if order == TIME_DESC then
			reverse(out)
		end
	else
		table.sort(out, tie)
		if order == ALPHA_DESC then
			reverse(out)
		end
	end
	return out
end

local function sum(t: { [string]: number }?, keep: ((string) -> boolean)?): number
	local n = 0
	if t then
		for k, v in t do
			if keep == nil or keep(k) then
				n += v
			end
		end
	end
	return n
end

-- The rules the panel lists (filterRules over sortRules), before maxItems.
function M.rows(
	o: Options,
	rules: { Rule },
	dashboardUid: string?,
	interpolate: (string) -> string,
	now: number
): { Row }
	local name = string.lower(interpolate(o.alertName))
	local labelText = interpolate(o.alertInstanceLabelFilter)
	local f = labelFilter(labelText)
	local out: { Row } = {}
	for _, r in sortRules(o.sortOrder, rules, now) do
		if o.dashboardAlerts and (dashboardUid == nil or r.annotations.__dashboardUid__ ~= dashboardUid) then
			continue
		end
		if name ~= "" and string.find(string.lower(r.name), name, 1, true) == nil then
			continue
		end
		local sf = o.stateFilter
		local stateOk = (sf.firing and r.state == "firing")
			or (sf.pending and r.state == "pending")
			or (sf.normal and r.state == "inactive")
			or (sf.recovering and r.state == "recovering")
		if not stateOk then
			continue
		end
		if o.folder_uid and r.folder_uid ~= o.folder_uid then
			continue
		end
		local kept = filterInstances(o, f, r.instances)
		if #kept == 0 and not (r.state == "inactive" and o.showInactiveAlerts and o.alertInstanceLabelFilter == "") then
			continue
		end
		local count = #kept
		local hidden = #r.instances - #kept
		if r.source == "grafana" then
			-- AlertInstances counts Grafana's server-side totals; the answer
			-- holds at most INSTANCES_LIMIT instances, so a cut list counts
			-- from the totals.
			local total = sum(r.totals)
			if r.totals and #r.instances < total and f == nil then
				count = sum(r.totals, function(k: string): boolean
					local flag = TOTAL_FLAG[k]
					return flag ~= nil and (o.stateFilter :: any)[flag] == true
				end)
			end
			hidden = if total > 0 and count > 0 then math.max(total - count, 0) else 0
		end
		table.insert(out, {
			rule = r,
			instances = sortInstances(o.sortOrder, kept, now),
			count = count,
			hidden = hidden,
		})
	end
	return out
end

-- date-fns intervalToDuration, as intervalToAbbreviatedDurationString
-- prints it ("6m 12s", "1d 2h 3m 4s"): calendar years and months, then days.
function M.duration(from_ms: number, to_ms: number): string
	if to_ms <= from_ms then
		return ""
	end
	local DAY = 86400000
	local fd, td = from_ms // DAY, to_ms // DAY
	local fr, tr = from_ms - fd * DAY, to_ms - td * DAY
	local fy, fm, fday = civilFromDays(fd)
	local ty, tm, tday = civilFromDays(td)
	local months = (ty - fy) * 12 + (tm - fm)
	if tday < fday or (tday == fday and tr < fr) then
		months -= 1
	end
	months = math.max(months, 0)
	-- Anchor: from + months (day clamped to the target month's length).
	local ay = fy + (fm - 1 + months) // 12
	local am = (fm - 1 + months) % 12 + 1
	local _, _, lastDay =
		civilFromDays(daysFromCivil(if am == 12 then ay + 1 else ay, if am == 12 then 1 else am + 1, 1) - 1)
	local anchor = daysFromCivil(ay, am, math.min(fday, lastDay)) * DAY + fr
	local rest = to_ms - anchor
	local parts: { string } = {}
	local years = months // 12
	months = months % 12
	local function add(v: number, unit: string)
		if v > 0 then
			table.insert(parts, tostring(v) .. unit)
		end
	end
	add(years, "y")
	add(months, "M")
	add(rest // DAY, "d")
	rest = rest % DAY
	add(rest // 3600000, "h")
	rest = rest % 3600000
	add(rest // 60000, "m")
	rest = rest % 60000
	add(rest // 1000, "s")
	return table.concat(parts, " ")
end

-- View ----------------------------------------------------------------------------------

-- The native alerts block's rules view on this rule (Grafana: "View alert rule").
function M.ruleLink(rule: Rule): string?
	if rule.name == "" then
		return nil
	end
	local filter = string.format('alertname="%s"', (string.gsub(rule.name, '(["\\])', "\\%1")))
	local ok, link =
		pcall(Scheme.encode, { action = "alerts", params = { view = "rules", filter = filter }, vars = {} })
	return if ok then link else nil
end

local function el(class: string, key: string, children: { Node }, props: { [string]: any }?): Node
	local p: { [string]: any } = { tag = "div", class = class, key = key }
	if props then
		for k, v in props do
			p[k] = v
		end
	end
	return { k = "el", p = p, c = children }
end

local function labelsNode(labels: { [string]: string }, key: string): Node
	local names: { string } = {}
	for k in labels do
		table.insert(names, k)
	end
	table.sort(names)
	local chips: { Node } = {}
	for i, k in names do
		table.insert(
			chips,
			el("tgl-label", "l" .. i, { ui.text({ ui.span(k .. "=" .. labels[k]) }) }, { tag = "span" })
		)
	end
	return el("tgl-labels", key, chips)
end

local function instancesNode(list: { Instance }, now: number, key: string): Node
	local rows: { Node } = {}
	for i, a in list do
		local spans = { ui.span(baseState(a.state), M.tone(a.state)) }
		if a.active_ms then
			local age = M.duration(a.active_ms :: number, now)
			if age ~= "" then
				table.insert(spans, ui.span("  " .. age, "muted"))
			end
		end
		table.insert(rows, el("tgl-instance", "i" .. i, { ui.text(spans, { key = "s" }), labelsNode(a.labels, "lb") }))
	end
	return el("tgl-instances", key, rows)
end

local function ruleNode(row: Row, o: Options, now: number, i: number): Node
	local r = row.rule
	local link = M.ruleLink(r)
	-- The name keeps whole words: one line, ellipsized, the full name as the
	-- tooltip; the rule link gets its own line below the status.
	local nameSpan: ui.Span = { t = r.name, s = "strong" }
	local head: { Node } = {
		el("tgl-name", "nw", { ui.text({ nameSpan }, { key = "n", truncate = "end" }) }, { title = r.name }),
	}
	local status = { ui.span(M.readable(r.state), M.tone(r.state)) }
	local first = M.firstActiveAt(r)
	if first and r.state ~= "inactive" then
		table.insert(status, ui.span(" for " .. M.duration(first, now), "muted"))
	end
	local count = string.format("%d %s", row.count, if row.count == 1 then "instance" else "instances")
	local countSpans = { ui.span(count, "muted") }
	if row.hidden > 0 then
		table.insert(countSpans, ui.span(string.format(", %d hidden by filters", row.hidden), "muted"))
	end
	local body: { Node } = {
		el("tgl-row-head", "h", head),
		ui.text(status, { key = "st" }),
		ui.text(countSpans, { key = "ct" }),
	}
	if link then
		table.insert(body, ui.text({ { t = "View alert rule", s = "accent", href = link } }, { key = "v" }))
	end
	if o.showInstances and #row.instances > 0 then
		table.insert(body, instancesNode(row.instances, now, "in"))
	end
	return el("tgl-item", "r" .. i, {
		el("tgl-icon", "ic", { ui.text({ ui.span("●", M.tone(r.state)) }) }),
		el("tgl-col", "b", body),
	})
end

local UNGROUPED = "\0"

-- GroupedView: instances keyed by their groupBy label values.
local function groupedNode(rows: { Row }, o: Options, now: number): { Node }
	local order: { string } = {}
	local groups: { [string]: { labels: { { string } }, list: { Instance } } } = {}
	for _, row in rows do
		-- alertHasEveryLabelForCombinedRules over the rule's instances.
		local every = true
		for _, k in o.groupBy do
			local any = false
			for _, a in row.rule.instances do
				if a.labels[k] and a.labels[k] ~= "" then
					any = true
					break
				end
			end
			if not any then
				every = false
				break
			end
		end
		for _, a in row.rule.instances do
			local key = UNGROUPED
			local pairs_: { { string } } = {}
			if every then
				local parts: { string } = {}
				for _, k in o.groupBy do
					local v = a.labels[k] or "undefined"
					table.insert(parts, k .. "\1" .. v)
					table.insert(pairs_, { k, v })
				end
				key = table.concat(parts, "\2")
			end
			local g = groups[key]
			if g == nil then
				g = { labels = pairs_, list = {} }
				groups[key] = g
				if key ~= UNGROUPED then
					table.insert(order, key)
				end
			end
			table.insert((g :: any).list, a)
		end
	end
	table.insert(order, UNGROUPED)
	local f = labelFilter(o.alertInstanceLabelFilter)
	local out: { Node } = {}
	for gi, key in order do
		local g = groups[key]
		if g == nil then
			continue
		end
		local kept = filterInstances(o, f, g.list)
		if #kept == 0 then
			continue
		end
		local head: Node
		if key == UNGROUPED then
			head = ui.text({ ui.span("No grouping", "strong") }, { key = "h" })
		else
			local labels: { [string]: string } = {}
			for _, p in g.labels do
				labels[p[1]] = p[2]
			end
			head = labelsNode(labels, "h")
		end
		table.insert(
			out,
			el(
				"tgl-item",
				"g" .. gi,
				{ el("tgl-col", "b", { head, instancesNode(sortInstances(o.sortOrder, kept, now), now, "in") }) }
			)
		)
	end
	return out
end

export type Combined = {
	rules: { Rule },
	dashboard_uid: string?,
	-- Data sources left out by MAX_EXTERNAL.
	skipped: number,
	-- Set when no source answered with rules.
	error: string?,
}

-- Every answer so far, combined like useCombinedRuleNamespaces: data
-- sources first (by uid here), Grafana-managed rules last; nil before any.
function M.combine(extra: { [string]: any }?): Combined?
	if extra == nil then
		return nil
	end
	local grafana: any = nil
	local skipped = 0
	local dashboardUid: string? = nil
	local ds: { { uid: string, answer: any } } = {}
	for tag, v in extra do
		if string.sub(tag, 1, #TAG_GRAFANA) == TAG_GRAFANA then
			local n, uid = string.match(string.sub(tag, #TAG_GRAFANA + 1), "^(%d+):(.*)$")
			grafana = v
			skipped = tonumber(n or "") or 0
			dashboardUid = if uid and uid ~= "" then uid else nil
		elseif string.sub(tag, 1, #TAG_DS) == TAG_DS then
			table.insert(ds, { uid = string.sub(tag, #TAG_DS + 1), answer = v })
		end
	end
	if grafana == nil and #ds == 0 then
		return nil
	end
	table.sort(ds, function(a, b): boolean
		return a.uid < b.uid
	end)
	local answers: { any } = {}
	for _, d in ds do
		table.insert(answers, d.answer)
	end
	if grafana ~= nil then
		table.insert(answers, grafana)
	end
	local rules: { Rule } = {}
	local err: string? = nil
	local ok = false
	for _, a in answers do
		if a.rules then
			ok = true
			for _, r in a.rules :: { Rule } do
				table.insert(rules, r)
			end
		elseif err == nil or a == grafana then
			err = tostring(a.error)
		end
	end
	return { rules = rules, dashboard_uid = dashboardUid, skipped = skipped, error = if ok then nil else err }
end

function M.view(panel: any, _: { Frame.Frame }, env: Env, opts: Common.Options): (Node, Assets.Assets?)
	local combined = M.combine(opts.extra)
	if combined == nil then
		return ui.muted("Loading...", { key = opts.key }), nil
	end
	local c = combined :: Combined
	if c.error then
		return ui.text({ ui.span(c.error :: string, "error") }, { key = opts.key }), nil
	end
	local o = M.options(panel, env)
	local interpolate = opts.interpolate or function(s: string): string
		return s
	end
	local now = env.now_ms
	local rows = M.rows(o, c.rules, c.dashboard_uid, interpolate, now)
	local children: { Node } = {}
	if c.skipped > 0 then
		table.insert(
			children,
			ui.muted(
				string.format(
					"%d more data %s manage alert rules; Tern reads at most %d",
					c.skipped,
					if c.skipped == 1 then "source" else "sources",
					M.MAX_EXTERNAL
				),
				{ key = "cap" }
			)
		)
	end
	if #rows == 0 then
		table.insert(children, ui.muted("No alerts matching filters", { key = "none" }))
	end
	if o.viewMode == "stat" then
		-- BigValue: colorMode none, graphMode none, one unnamed value.
		local statPanel = {
			type = "stat",
			options = { colorMode = "none", graphMode = "none", textMode = "value", justifyMode = "auto" },
		}
		local frame: Frame.Frame = { fields = { Frame.field("Value", "number", { #rows }) } }
		table.insert(children, Stat.view(statPanel, { frame }, env, { key = "stat" }))
	elseif o.groupMode == "custom" then
		for _, n in groupedNode(rows, o, now) do
			table.insert(children, n)
		end
	else
		for i = 1, math.min(#rows, math.max(o.maxItems, 0)) do
			table.insert(children, ruleNode(rows[i], o, now, i))
		end
	end
	return el("tgl-list", opts.key, children, { role = "tern-grafana.alertlist" }), nil
end

return M
