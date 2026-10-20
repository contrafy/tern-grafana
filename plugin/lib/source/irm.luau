--!strict
-- Grafana IRM request builders and parsers: discovery (the IRM app's plugin
-- settings), the OnCall public API (schedules, who is on call, alert groups
-- and their actions) and the Incident JSON/HTTP RPC API (incidents, their
-- activity, statuses, severities and writes).
--
-- Both APIs authenticate with the context's Grafana service-account token:
-- - OnCall lives on its own host (`jsonData.onCallApiUrl`), so OnCall
--   requests go through a route derived from the Grafana one (same
--   credential, `X-Grafana-URL` naming the stack, see `oncallRoute`).
-- - The Incident API is reached through Grafana's plugin resource proxy,
--   `/api/plugins/grafana-irm-app/resources/api/v1/<Service>.<Method>`, as
--   its reference documents for service-account tokens.
--
-- A 403 names the permission or role the service account lacks.

local Classify = require("../transport/classify")
local Env = require("../env")
local Http = require("../transport/http")
local Json = require("../panels/json")
local Range = require("../time/range")
local Route = require("../config/route")
local Tbl = require("../tbl")
local TransportTypes = require("../transport/types")

type Env = Env.Env
type Route = Route.Route
type Request = TransportTypes.Request
type Response = TransportTypes.Response
type QueryError = TransportTypes.QueryError

export type Discovery = {
	-- The OnCall API base (no trailing slash); nil when OnCall is not set up.
	oncall_url: string?,
	-- Why OnCall is unavailable, when it is.
	oncall_problem: string?,
	version: string?,
}

export type Schedule = { id: string, name: string, team_id: string?, on_call_now: { string } }

-- `email` is lower-cased, for matching `irm.user`.
export type OnCallUser = { id: string, name: string, email: string? }
export type Shift = { start_ms: number?, end_ms: number?, users: { string } }
export type OnCall = { users: { OnCallUser }, shifts: { Shift } }

-- "firing", "acknowledged", "silenced" or "resolved".
export type GroupState = string

export type SubAlert = {
	status: string?,
	labels: { [string]: string },
	annotations: { [string]: string },
	starts_ms: number?,
	value: string?,
}

export type LastAlert = { created_ms: number?, status: string?, message: string?, alerts: { SubAlert } }

export type AlertGroup = {
	id: string,
	number: number?,
	title: string,
	state: GroupState,
	integration_id: string?,
	alerts_count: number,
	created_ms: number?,
	acknowledged_ms: number?,
	resolved_ms: number?,
	silenced_ms: number?,
	url: string?,
	labels: { { key: string, value: string } },
	last: LastAlert?,
}

export type Alert = { id: string, created_ms: number?, title: string?, status: string? }

export type Incident = {
	id: string,
	title: string,
	-- A status slug ("active", "resolved", or an org's own status).
	status: string,
	severity: string,
	drill: boolean,
	created_ms: number?,
	start_ms: number?,
	closed_ms: number?,
	summary: string?,
	created_by: string?,
	url: string?,
	roles: { { role: string, name: string } },
}

export type Activity = { id: string, kind: string, body: string, user: string?, time_ms: number? }

export type Status = { slug: string, name: string, category: "active" | "resolved" }

-- Which call failed, so a 403 can say what is missing.
export type Op =
	"discovery"
	| "schedules"
	| "alert_groups"
	| "alert_group_write"
	| "users"
	| "integrations"
	| "incident_read"
	| "incident_write"

local M = {}

M.PLUGIN_ID = "grafana-irm-app"
M.SETTINGS_PATH = "/api/plugins/grafana-irm-app/settings"
M.RPC_PATH = "/api/plugins/grafana-irm-app/resources/api/v1/"
-- OnCall caps a page at 100.
M.MAX_PAGE = 100
-- The Incident API caps a query at 100.
M.MAX_INCIDENTS = 100
-- OnCall's `delay` for a silence: at most a day here (OnCall also accepts -1,
-- forever, which this plugin never sends).
M.MAX_SILENCE_S = 24 * 3600
-- Open incidents: not drills, not resolved (custom resolved statuses are
-- filtered again by category once the statuses are known).
M.OPEN_QUERY = "isdrill:false -status:resolved"

-- The permission (or role) each operation needs, from IRM's roles reference.
M.NEEDS = table.freeze({
	discovery = "the service account cannot read the IRM app's settings (plugins.plugins:read, Viewer or higher)",
	schedules = "the service account needs grafana-irm-app.schedules:read (IRM Reader role or the Viewer basic role)",
	alert_groups = "the service account needs grafana-irm-app.alert-groups:read (IRM Reader role or the Viewer basic role)",
	alert_group_write = "the service account needs grafana-irm-app.alert-groups:write: give it the IRM OnCaller "
		.. "or Alert Groups Editor role (or the Editor basic role)",
	users = "the service account needs grafana-irm-app.user-settings:read to show names",
	integrations = "the service account needs grafana-irm-app.integrations:read to show integration names",
	incident_read = "the service account needs access to the IRM app (plugins.app:access on grafana-irm-app)",
	incident_write = "incident actions need the Editor basic role on the service account",
})

-- The RBAC action that allows alert-group actions.
M.ALERT_GROUP_WRITE = "grafana-irm-app.alert-groups:write"

local function str(env: Env, v: any): string?
	local s = Json.str(env, v)
	return if s and s ~= "" then s else nil
end

-- RFC 3339 to epoch ms; "" and Go's zero time are no time.
function M.time(env: Env, v: any): number?
	local s = str(env, v)
	if s == nil or not string.match(s, "^%d%d%d%d%-") or string.sub(s, 1, 4) == "0001" then
		return nil
	end
	local ms = Range.parse(s, false, { now_ms = 0 })
	return ms
end

local function idOf(env: Env, v: any): string?
	if type(v) == "number" then
		return tostring(v)
	end
	return str(env, v)
end

-- The server's own words in an error body: OnCall's `detail`, the Incident
-- API's RFC 7807 `detail` and `hint`, or what Classify finds.
local function serverDetail(env: Env, body: string): string?
	local ok, doc = pcall(env.decode, body)
	if not ok or type(doc) ~= "table" then
		return nil
	end
	local detail = str(env, doc.detail) or str(env, doc.error) or str(env, doc.message)
	local hint = str(env, doc.hint)
	if detail and hint then
		return detail .. " (" .. hint .. ")"
	end
	return detail
end

-- The transport or HTTP error of an IRM response, nil on success. A 403
-- says which permission is missing; a 2xx Incident API answer with a
-- non-empty `error` is an error too.
function M.failure(response: Response, env: Env, op: Op): QueryError?
	local qe = Classify.classify(response, env.decode)
	if qe == nil then
		if op == "incident_read" or op == "incident_write" then
			local ok, doc = pcall(env.decode, response.body)
			local err = if ok and type(doc) == "table" then str(env, doc.error) else nil
			if err then
				return { kind = "query", status = response.status, message = err }
			end
		end
		return nil
	end
	if response.failure or response.status == 0 then
		return qe
	end
	local detail = serverDetail(env, response.body)
	local status = response.status
	if status == 403 then
		local need = (M.NEEDS :: any)[op] :: string
		return {
			kind = "auth",
			status = status,
			message = string.format("permission denied (HTTP 403)%s; %s", if detail then ": " .. detail else "", need),
			hint = need,
		}
	end
	if status == 401 then
		return qe
	end
	if detail then
		return { kind = qe.kind, status = status, message = string.format("HTTP %d: %s", status, detail) }
	end
	return qe
end

-- Discovery -----------------------------------------------------------------

function M.settingsRequest(): Request
	return { method = "GET", path = M.SETTINGS_PATH }
end

local function httpBase(url: string, grafana_url: string): (string?, string?)
	local scheme = string.match(url, "^(%a+)://[^/?#@%s]+")
	if scheme == nil then
		return nil, "the IRM app reports an OnCall API URL that is not a URL"
	end
	scheme = string.lower(scheme)
	-- The service-account token travels to this host: plain http only when
	-- Grafana itself is plain http (a lab).
	if scheme ~= "https" and not (scheme == "http" and string.match(string.lower(grafana_url), "^http://")) then
		return nil, "the IRM app reports an OnCall API URL that is not https; refusing to send the token there"
	end
	return (string.gsub(url, "/+$", "")), nil
end

-- What the IRM app offers on this Grafana; a context without it fails with
-- a message that says so.
function M.parseDiscovery(response: Response, env: Env, grafana_url: string): (Discovery?, QueryError?)
	if response.status == 404 then
		return nil,
			{
				kind = "unsupported",
				status = 404,
				message = "Grafana IRM (grafana-irm-app) is not installed on this Grafana",
			}
	end
	local qe = M.failure(response, env, "discovery")
	if qe then
		return nil, qe
	end
	local ok, doc = pcall(env.decode, response.body)
	if not ok or type(doc) ~= "table" then
		return nil, { kind = "parse", message = "IRM settings: the response is not a JSON object" }
	end
	if doc.enabled == false then
		return nil, { kind = "unsupported", message = "Grafana IRM is installed but not enabled on this Grafana" }
	end
	local data = Json.obj(env, doc.jsonData)
	local discovery: Discovery = {
		oncall_url = nil,
		oncall_problem = nil,
		version = str(env, Json.path(env, doc, "info", "version")),
	}
	local raw = str(env, data.onCallApiUrl)
	if raw == nil then
		discovery.oncall_problem = "OnCall is not set up in Grafana IRM (no OnCall API URL)"
	else
		local base, why = httpBase(raw :: string, grafana_url)
		discovery.oncall_url = base
		discovery.oncall_problem = why
	end
	return discovery, nil
end

-- The route OnCall requests take: the Grafana route's credential and TLS
-- options, OnCall's own host, and `X-Grafana-URL` naming the stack. The
-- endpoint name stays "grafana" so the credential cache is shared.
function M.oncallRoute(grafana: Route, oncall_url: string): Route
	local ep = grafana.endpoint
	local headers = Tbl.copy(ep.headers)
	headers["X-Grafana-URL"] = ep.url
	return {
		context = grafana.context,
		signal = grafana.signal,
		via = "grafana",
		endpoint_name = grafana.endpoint_name,
		endpoint = {
			url = oncall_url,
			auth = ep.auth,
			headers = headers,
			path_prefix = "",
			tls = ep.tls,
			timeout_ms = ep.timeout_ms,
		},
	}
end

function M.permissionsRequest(): Request
	return { method = "GET", path = "/api/access-control/user/permissions" }
end

-- The caller's RBAC actions; nil when Grafana does not answer (older or OSS
-- Grafana without the endpoint), which means "unknown", not "none".
function M.parsePermissions(response: Response, env: Env): { [string]: boolean }?
	if Classify.classify(response, env.decode) then
		return nil
	end
	local ok, doc = pcall(env.decode, response.body)
	if not ok or type(doc) ~= "table" then
		return nil
	end
	local out: { [string]: boolean } = {}
	for action in doc do
		if type(action) == "string" then
			out[action] = true
		end
	end
	return out
end

function M.userRequest(): Request
	return { method = "GET", path = "/api/user" }
end

-- The service account's login, for the attribution notice.
function M.parseLogin(response: Response, env: Env): string?
	if Classify.classify(response, env.decode) then
		return nil
	end
	local ok, doc = pcall(env.decode, response.body)
	if not ok or type(doc) ~= "table" then
		return nil
	end
	return str(env, doc.login)
end

-- OnCall ----------------------------------------------------------------------

local function get(path: string, query: { { string } }?): Request
	return { method = "GET", path = path, query = query }
end

function M.schedulesRequest(): Request
	return get("api/v1/schedules/", { { "perpage", tostring(M.MAX_PAGE) } })
end

function M.onCallRequest(schedule_id: string, which: "current" | "next"): Request
	return get("api/v1/schedules/" .. Http.escape(schedule_id) .. "/" .. which .. "_oncall/")
end

function M.usersRequest(): Request
	return get("api/v1/users/", { { "perpage", tostring(M.MAX_PAGE) } })
end

function M.integrationsRequest(): Request
	return get("api/v1/integrations/", { { "perpage", tostring(M.MAX_PAGE) } })
end

-- Alert groups in one state; OnCall's filter calls firing groups `new`.
function M.groupsRequest(state: GroupState, perpage: number): Request
	local filter = if state == "firing" then "new" else state
	return get("api/v1/alert_groups/", {
		{ "state", filter },
		{ "perpage", tostring(math.clamp(perpage, 1, M.MAX_PAGE)) },
	})
end

function M.groupRequest(id: string): Request
	return get("api/v1/alert_groups/" .. Http.escape(id) .. "/")
end

function M.alertsRequest(group_id: string, perpage: number): Request
	return get("api/v1/alerts/", {
		{ "alert_group_id", group_id },
		{ "perpage", tostring(math.clamp(perpage, 1, M.MAX_PAGE)) },
	})
end

-- "acknowledge", "unacknowledge", "resolve", "unresolve" or "silence".
export type GroupAction = string

-- The one request an alert-group action sends. `delay_s` is the silence
-- duration, required for `silence`.
function M.groupActionRequest(id: string, action: GroupAction, delay_s: number?, encode: (any) -> string): Request
	local request: Request = {
		method = "POST",
		path = "api/v1/alert_groups/" .. Http.escape(id) .. "/" .. action,
	}
	if action == "silence" then
		assert(delay_s and delay_s > 0 and delay_s <= M.MAX_SILENCE_S, "silence needs a duration")
		request.headers = { ["Content-Type"] = "application/json" }
		request.body = encode({ delay = math.floor(delay_s :: number) })
	end
	return request
end

local function page(env: Env, response: Response, op: Op, what: string): ({ any }?, number?, QueryError?)
	local qe = M.failure(response, env, op)
	if qe then
		return nil, nil, qe
	end
	local ok, doc = pcall(env.decode, response.body)
	if not ok or type(doc) ~= "table" then
		return nil, nil, { kind = "parse", message = what .. ": the response is not a JSON object" }
	end
	local count = Json.num(env, doc.count)
	return Json.list(env, doc.results), count, nil
end

function M.parseSchedules(response: Response, env: Env): ({ Schedule }?, QueryError?)
	local list, _, qe = page(env, response, "schedules", "OnCall schedules")
	if list == nil then
		return nil, qe
	end
	local out: { Schedule } = {}
	for _, raw in list do
		local id = idOf(env, Json.obj(env, raw).id)
		if id then
			local now: { string } = {}
			for _, u in Json.list(env, raw.on_call_now) do
				local uid = idOf(env, u)
				if uid then
					table.insert(now, uid)
				end
			end
			table.insert(out, {
				id = id,
				name = str(env, raw.name) or id,
				team_id = str(env, raw.team_id),
				on_call_now = now,
			})
		end
	end
	table.sort(out, function(a, b)
		return string.lower(a.name) < string.lower(b.name)
	end)
	return out, nil
end

-- current_oncall / next_oncall: the users (username and email) and the shifts.
function M.parseOnCall(response: Response, env: Env): (OnCall?, QueryError?)
	local qe = M.failure(response, env, "schedules")
	if qe then
		return nil, qe
	end
	local ok, doc = pcall(env.decode, response.body)
	if not ok or type(doc) ~= "table" then
		return nil, { kind = "parse", message = "OnCall on-call users: the response is not a JSON object" }
	end
	local users: { OnCallUser } = {}
	for _, raw in Json.list(env, doc.users) do
		local id = idOf(env, Json.obj(env, raw).id)
		if id then
			local email = str(env, raw.email)
			table.insert(users, {
				id = id,
				name = str(env, raw.username) or email or id,
				email = if email then string.lower(email :: string) else nil,
			})
		end
	end
	local shifts: { Shift } = {}
	for _, raw in Json.list(env, doc.shifts) do
		local ids: { string } = {}
		for _, u in Json.list(env, Json.obj(env, raw).users) do
			local uid = idOf(env, u)
			if uid then
				table.insert(ids, uid)
			end
		end
		table.insert(
			shifts,
			{ start_ms = M.time(env, raw.shift_start), end_ms = M.time(env, raw.shift_end), users = ids }
		)
	end
	return { users = users, shifts = shifts }, nil
end

-- OnCall user id -> username and (lower-cased) email.
function M.parseUsers(response: Response, env: Env): ({ [string]: OnCallUser }?, QueryError?)
	local list, _, qe = page(env, response, "users", "OnCall users")
	if list == nil then
		return nil, qe
	end
	local out: { [string]: OnCallUser } = {}
	for _, raw in list do
		local id = idOf(env, Json.obj(env, raw).id)
		local email = str(env, raw.email)
		local name = str(env, raw.username) or email
		if id and name then
			out[id] = { id = id, name = name, email = if email then string.lower(email :: string) else nil }
		end
	end
	return out, nil
end

-- Integration id -> name.
function M.parseIntegrations(response: Response, env: Env): ({ [string]: string }?, QueryError?)
	local list, _, qe = page(env, response, "integrations", "OnCall integrations")
	if list == nil then
		return nil, qe
	end
	local out: { [string]: string } = {}
	for _, raw in list do
		local id = idOf(env, Json.obj(env, raw).id)
		local name = str(env, raw.name)
		if id and name then
			out[id] = name
		end
	end
	return out, nil
end

local STATES: { [string]: GroupState } = {
	new = "firing",
	firing = "firing",
	acknowledged = "acknowledged",
	silenced = "silenced",
	resolved = "resolved",
}

local function stringMap(env: Env, v: any): { [string]: string }
	local out: { [string]: string } = {}
	for k, x in Json.obj(env, v) do
		if type(k) == "string" then
			if type(x) == "string" then
				out[k] = x
			elseif type(x) == "number" or type(x) == "boolean" then
				out[k] = tostring(x)
			end
		end
	end
	return out
end

local function labelName(env: Env, v: any): string?
	if type(v) == "table" then
		return str(env, v.name) or str(env, v.id)
	end
	return str(env, v)
end

-- How many sub-alerts of a Grafana Alerting payload a detail view keeps.
M.MAX_SUB_ALERTS = 20

local function lastAlert(env: Env, raw: any): LastAlert?
	local t = Json.tbl(env, raw)
	if t == nil then
		return nil
	end
	local payload = Json.obj(env, t.payload)
	local alerts: { SubAlert } = {}
	for _, a in Json.list(env, payload.alerts) do
		if #alerts >= M.MAX_SUB_ALERTS then
			break
		end
		local at = Json.obj(env, a)
		table.insert(alerts, {
			status = str(env, at.status),
			labels = stringMap(env, at.labels),
			annotations = stringMap(env, at.annotations),
			starts_ms = M.time(env, at.startsAt),
			value = str(env, at.valueString),
		})
	end
	return {
		created_ms = M.time(env, t.created_at),
		status = str(env, payload.status) or str(env, payload.state),
		message = str(env, payload.message),
		alerts = alerts,
	}
end

local function group(env: Env, raw: any): AlertGroup?
	local t = Json.tbl(env, raw)
	if t == nil then
		return nil
	end
	local id = idOf(env, t.id)
	local state = STATES[str(env, t.state) or ""]
	if id == nil or state == nil then
		return nil
	end
	local labels: { { key: string, value: string } } = {}
	for _, l in Json.list(env, t.labels) do
		local lt = Json.obj(env, l)
		local k, v = labelName(env, lt.key), labelName(env, lt.value)
		if k and v then
			table.insert(labels, { key = k, value = v })
		end
	end
	return {
		id = id,
		number = Json.num(env, t.alert_group_number),
		title = str(env, t.title) or ("alert group " .. id),
		state = state,
		integration_id = idOf(env, t.integration_id),
		alerts_count = Json.num(env, t.alerts_count) or 0,
		created_ms = M.time(env, t.created_at),
		acknowledged_ms = M.time(env, t.acknowledged_at),
		resolved_ms = M.time(env, t.resolved_at),
		silenced_ms = M.time(env, t.silenced_at),
		url = str(env, Json.path(env, t, "permalinks", "web")),
		labels = labels,
		last = lastAlert(env, t.last_alert),
	}
end

-- One page of alert groups and OnCall's total count for the filter.
function M.parseGroups(response: Response, env: Env): ({ AlertGroup }?, number?, QueryError?)
	local list, count, qe = page(env, response, "alert_groups", "OnCall alert groups")
	if list == nil then
		return nil, nil, qe
	end
	local out: { AlertGroup } = {}
	for _, raw in list do
		local g = group(env, raw)
		if g then
			table.insert(out, g)
		end
	end
	return out, count or #out, nil
end

function M.parseGroup(response: Response, env: Env): (AlertGroup?, QueryError?)
	local qe = M.failure(response, env, "alert_groups")
	if qe then
		return nil, qe
	end
	local ok, doc = pcall(env.decode, response.body)
	local g = if ok then group(env, doc) else nil
	if g == nil then
		return nil, { kind = "parse", message = "OnCall alert group: the response is not an alert group" }
	end
	return g, nil
end

function M.parseAlerts(response: Response, env: Env): ({ Alert }?, number?, QueryError?)
	local list, count, qe = page(env, response, "alert_groups", "OnCall alerts")
	if list == nil then
		return nil, nil, qe
	end
	local out: { Alert } = {}
	for _, raw in list do
		local t = Json.obj(env, raw)
		local id = idOf(env, t.id)
		if id then
			local payload = Json.obj(env, t.payload)
			table.insert(out, {
				id = id,
				created_ms = M.time(env, t.created_at),
				title = str(env, payload.title) or str(env, payload.ruleName),
				status = str(env, payload.status) or str(env, payload.state),
			})
		end
	end
	return out, count or #out, nil
end

-- Incident API ----------------------------------------------------------------

local function rpc(method: string, body: string): Request
	return {
		method = "POST",
		path = M.RPC_PATH .. method,
		headers = { ["Content-Type"] = "application/json; charset=utf-8" },
		body = body,
	}
end

function M.openIncidentsRequest(limit: number, encode: (any) -> string): Request
	return rpc(
		"IncidentsService.QueryIncidentPreviews",
		encode({
			query = {
				limit = math.clamp(limit, 1, M.MAX_INCIDENTS),
				orderDirection = "DESC",
				orderField = "createdTime",
				queryString = M.OPEN_QUERY,
			},
		})
	)
end

function M.incidentRequest(id: string, encode: (any) -> string): Request
	return rpc("IncidentsService.GetIncident", encode({ incidentID = id }))
end

function M.activityRequest(id: string, limit: number, encode: (any) -> string): Request
	return rpc(
		"ActivityService.QueryActivity",
		encode({ query = { incidentID = id, limit = math.clamp(limit, 1, 100), orderDirection = "DESC" } })
	)
end

function M.statusesRequest(encode: (any) -> string): Request
	return rpc("StatusService.QueryOrgStatuses", encode({ incidentType = "internal" }))
end

function M.severitiesRequest(): Request
	return rpc("SeveritiesService.GetOrgSeverities", "{}")
end

export type Declare = { title: string, severity: string }

function M.createIncidentRequest(d: Declare, encode: (any) -> string): Request
	return rpc(
		"IncidentsService.CreateIncident",
		encode({
			title = d.title,
			severity = d.severity,
			status = "active",
			isDrill = false,
			roomPrefix = "incident",
		})
	)
end

function M.updateStatusRequest(id: string, status: string, encode: (any) -> string): Request
	return rpc("IncidentsService.UpdateStatus", encode({ incidentID = id, status = status }))
end

function M.updateSeverityRequest(id: string, severity: string, encode: (any) -> string): Request
	return rpc("IncidentsService.UpdateSeverity", encode({ incidentID = id, severity = severity }))
end

function M.addNoteRequest(id: string, body: string, encode: (any) -> string): Request
	return rpc("ActivityService.AddActivity", encode({ incidentID = id, activityKind = "userNote", body = body }))
end

local function decodeRpc(response: Response, env: Env, op: Op, what: string): (any, QueryError?)
	local qe = M.failure(response, env, op)
	if qe then
		return nil, qe
	end
	local ok, doc = pcall(env.decode, response.body)
	if not ok or type(doc) ~= "table" then
		return nil, { kind = "parse", message = what .. ": the response is not a JSON object" }
	end
	return doc, nil
end

local function incident(env: Env, raw: any): Incident?
	local t = Json.tbl(env, raw)
	if t == nil then
		return nil
	end
	local id = idOf(env, t.incidentID)
	if id == nil then
		return nil
	end
	local roles: { { role: string, name: string } } = {}
	local membership = Json.obj(env, t.incidentMembership)
	for _, a in Json.list(env, membership.assignments) do
		local at = Json.obj(env, a)
		local role = str(env, Json.path(env, at, "role", "name")) or str(env, at.roleID)
		local name = str(env, Json.path(env, at, "user", "name"))
		if role and name then
			table.insert(roles, { role = role, name = name })
		end
	end
	return {
		id = id,
		title = str(env, t.title) or ("incident " .. id),
		status = str(env, t.status) or "active",
		severity = str(env, t.severityLabel) or str(env, t.severity) or "",
		drill = t.isDrill == true,
		created_ms = M.time(env, t.createdTime),
		start_ms = M.time(env, t.incidentStart),
		closed_ms = M.time(env, t.closedTime),
		summary = str(env, t.summary),
		created_by = str(env, Json.path(env, t, "createdByUser", "name")),
		url = str(env, t.overviewURL),
		roles = roles,
	}
end

-- Open incidents (newest first) and whether more exist than were returned.
function M.parseIncidents(response: Response, env: Env): ({ Incident }?, boolean, QueryError?)
	local doc, qe = decodeRpc(response, env, "incident_read", "IRM incidents")
	if doc == nil then
		return nil, false, qe
	end
	local out: { Incident } = {}
	for _, raw in Json.list(env, doc.incidentPreviews) do
		local x = incident(env, raw)
		if x then
			table.insert(out, x)
		end
	end
	return out, Json.path(env, doc, "cursor", "hasMore") == true, nil
end

-- GetIncident, and the incident a write returns.
function M.parseIncident(response: Response, env: Env, op: Op?): (Incident?, QueryError?)
	local doc, qe = decodeRpc(response, env, op or "incident_read", "IRM incident")
	if doc == nil then
		return nil, qe
	end
	local x = incident(env, doc.incident)
	if x == nil then
		return nil, { kind = "parse", message = "IRM incident: the response has no incident" }
	end
	return x, nil
end

-- Timeline items, newest first as queried.
function M.parseActivity(response: Response, env: Env): ({ Activity }?, QueryError?)
	local doc, qe = decodeRpc(response, env, "incident_read", "IRM incident activity")
	if doc == nil then
		return nil, qe
	end
	local out: { Activity } = {}
	for _, raw in Json.list(env, doc.activityItems) do
		local t = Json.obj(env, raw)
		local id = idOf(env, t.activityItemID)
		if id then
			table.insert(out, {
				id = id,
				kind = str(env, t.activityKind) or "activity",
				body = str(env, t.body) or "",
				user = str(env, Json.path(env, t, "user", "name")),
				time_ms = M.time(env, t.eventTime) or M.time(env, t.createdTime),
			})
		end
	end
	return out, nil
end

-- The org's statuses in their display order, archived ones dropped.
function M.parseStatuses(response: Response, env: Env): ({ Status }?, QueryError?)
	local doc, qe = decodeRpc(response, env, "incident_read", "IRM statuses")
	if doc == nil then
		return nil, qe
	end
	local rows: { { s: Status, pos: number } } = {}
	local seen: { [string]: boolean } = {}
	for _, cfg in Json.list(env, doc.configurations) do
		for _, raw in Json.list(env, Json.obj(env, cfg).statuses) do
			local t = Json.obj(env, raw)
			local slug = str(env, t.slug)
			local category = str(env, t.category) or str(env, t.kind)
			if slug and not seen[slug] and str(env, t.archivedTime) == nil then
				seen[slug] = true
				table.insert(rows, {
					s = {
						slug = slug,
						name = str(env, t.name) or slug,
						category = if category == "resolved" or category == "terminal" then "resolved" else "active",
					},
					pos = Json.num(env, t.position) or 0,
				})
			end
		end
	end
	table.sort(rows, function(a, b)
		return a.pos < b.pos
	end)
	local out: { Status } = {}
	for _, r in rows do
		table.insert(out, r.s)
	end
	return out, nil
end

-- Severity labels by level, archived ones dropped; nil when this IRM
-- version does not route GetOrgSeverities.
function M.parseSeverities(response: Response, env: Env): { string }?
	if M.failure(response, env, "incident_read") then
		return nil
	end
	local ok, doc = pcall(env.decode, response.body)
	if not ok or type(doc) ~= "table" then
		return nil
	end
	local rows: { { label: string, level: number } } = {}
	for _, raw in Json.list(env, doc.severities) do
		local t = Json.obj(env, raw)
		local label = str(env, t.displayLabel)
		if label and str(env, t.archivedAt) == nil then
			table.insert(rows, { label = label, level = Json.num(env, t.level) or 0 })
		end
	end
	if #rows == 0 then
		return nil
	end
	table.sort(rows, function(a, b)
		return a.level < b.level
	end)
	local out: { string } = {}
	for _, r in rows do
		table.insert(out, r.label)
	end
	return out
end

-- AddActivity: the new item's id (nil when none came back), or the error.
function M.parseNoteAdded(response: Response, env: Env): (string?, QueryError?)
	local doc, qe = decodeRpc(response, env, "incident_write", "IRM note")
	if doc == nil then
		return nil, qe
	end
	return idOf(env, Json.path(env, doc, "activityItem", "activityItemID")), nil
end

return M
