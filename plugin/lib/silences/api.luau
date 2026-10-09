--!strict
-- Where a context's silences live and the requests that read, create and
-- expire them. The Alertmanager v2 API is the same on a direct Alertmanager,
-- Grafana's built-in Alertmanager (`/api/alertmanager/grafana/api/v2`) and
-- Grafana's proxy to an Alertmanager datasource (`/api/alertmanager/<uid>/
-- api/v2`). Prometheus has no silences.

local Env = require("../env")
local Http = require("../transport/http")
local Matchers = require("./matchers")
local Duration = require("./duration")
local Range = require("../time/range")
local Sources = require("../alerts/sources")
local Normalize = require("../alerts/normalize")
local Scheme = require("../links/scheme")
local TransportTypes = require("../transport/types")

type Plan = Sources.Plan
type Request = TransportTypes.Request
type Matcher = Matchers.Matcher
type Env = Env.Env

export type Target = {
	-- "alertmanager" | "grafana" | "grafana_external"
	kind: string,
	-- The API root on the route's endpoint, e.g. "/api/v2".
	base: string,
	-- How the target is named to the user.
	label: string,
}

export type SilenceState = "active" | "pending" | "expired"

export type Silence = {
	id: string,
	state: SilenceState,
	matchers: { Matcher },
	starts_ms: number,
	ends_ms: number,
	updated_ms: number?,
	created_by: string,
	comment: string,
}

-- What the user confirmed: everything the create request is built from.
export type Draft = {
	matchers: { Matcher },
	duration_s: number,
	comment: string,
	created_by: string,
}

local M = {}

M.JSON_HEADERS = table.freeze({ ["Content-Type"] = "application/json" })

-- nil and why when the context's alerts come from a server without silences.
function M.target(plan: Plan): (Target?, string?)
	if plan.kind == "alertmanager" then
		local e = plan.route.endpoint
		return { kind = "alertmanager", base = "/api/v2", label = "Alertmanager " .. e.url }, nil
	elseif plan.kind == "grafana" then
		return {
			kind = "grafana",
			base = "/api/alertmanager/grafana/api/v2",
			label = "Grafana Alertmanager " .. plan.route.endpoint.url,
		},
			nil
	elseif plan.kind == "grafana_external" then
		local uid = plan.route.datasource_uid :: string
		return {
			kind = "grafana_external",
			base = "/api/alertmanager/" .. Http.escape(uid) .. "/api/v2",
			label = string.format("Alertmanager datasource %s via %s", uid, plan.route.endpoint.url),
		},
			nil
	end
	return nil,
		string.format(
			"context %q reads alerts from Prometheus, which has no silences: configure its alertmanager (or grafana) endpoint",
			plan.context
		)
end

-- A tern-grafana:// link to the silence form for `alert`, prefilled with
-- equality matchers on its labels.
function M.linkFor(alert: Normalize.Alert): string
	return Scheme.encode({
		action = "silence",
		params = { context = alert.context, matchers = Matchers.formatList(Matchers.fromLabels(alert)) },
		vars = {},
	})
end

function M.listRequest(t: Target): Request
	return { method = "GET", path = t.base .. "/silences" }
end

-- The JSON body of a new silence starting now.
function M.createBody(d: Draft, now_ms: number): { [string]: any }
	local matchers: { Matchers.ApiMatcher } = {}
	for _, m in d.matchers do
		table.insert(matchers, Matchers.toApi(m))
	end
	return {
		matchers = matchers,
		startsAt = Duration.iso(now_ms),
		endsAt = Duration.iso(now_ms + d.duration_s * 1000),
		createdBy = d.created_by,
		comment = d.comment,
	}
end

function M.createRequest(t: Target, body: { [string]: any }, encode: (any) -> string): Request
	return { method = "POST", path = t.base .. "/silences", headers = M.JSON_HEADERS :: any, body = encode(body) }
end

-- Expiring is DELETE on the silence (both Alertmanager and Grafana).
function M.expireRequest(t: Target, id: string): Request
	return { method = "DELETE", path = t.base .. "/silence/" .. Http.escape(id) }
end

local function str(env: Env, v: any): string?
	v = Env.value(env, v)
	return if type(v) == "string" then v else nil
end

local function time(env: Env, v: any): number?
	local s = str(env, v)
	if s == nil or s == "" then
		return nil
	end
	return (Range.parse(s, false, { now_ms = env.now_ms }))
end

local function silence(env: Env, raw: any): Silence?
	if type(raw) ~= "table" then
		return nil
	end
	local id = str(env, raw.id)
	local starts, ends = time(env, raw.startsAt), time(env, raw.endsAt)
	if id == nil or starts == nil or ends == nil then
		return nil
	end
	local status = Env.value(env, raw.status)
	local state = if type(status) == "table" then str(env, status.state) else nil
	if state ~= "active" and state ~= "pending" and state ~= "expired" then
		-- Older servers omit status: derive it from the times.
		state = if ends <= env.now_ms then "expired" elseif starts > env.now_ms then "pending" else "active"
	end
	local matchers: { Matcher } = {}
	if type(raw.matchers) == "table" then
		for _, m in raw.matchers do
			local parsed = Matchers.fromApi(m)
			if parsed then
				table.insert(matchers, parsed)
			end
		end
	end
	return {
		id = id :: string,
		state = state :: SilenceState,
		matchers = matchers,
		starts_ms = starts :: number,
		ends_ms = ends :: number,
		updated_ms = time(env, raw.updatedAt),
		created_by = str(env, raw.createdBy) or "",
		comment = str(env, raw.comment) or "",
	}
end

local RANK: { [SilenceState]: number } = { active = 3, pending = 2, expired = 1 }

-- Active first (ending soonest first), then pending (starting soonest),
-- then expired (most recent first).
function M.before(a: Silence, b: Silence): boolean
	if a.state ~= b.state then
		return RANK[a.state] > RANK[b.state]
	end
	if a.state == "active" and a.ends_ms ~= b.ends_ms then
		return a.ends_ms < b.ends_ms
	elseif a.state == "pending" and a.starts_ms ~= b.starts_ms then
		return a.starts_ms < b.starts_ms
	elseif a.state == "expired" and a.ends_ms ~= b.ends_ms then
		return a.ends_ms > b.ends_ms
	end
	return a.id < b.id
end

-- GET .../silences (a JSON array), sorted.
function M.parseList(env: Env, body: string): ({ Silence }?, string?)
	local ok, doc = pcall(env.decode, body)
	if not ok then
		return nil, "response is not JSON"
	end
	if type(doc) ~= "table" or (next(doc) ~= nil and doc[1] == nil) then
		return nil, "expected a JSON array of silences"
	end
	local out: { Silence } = {}
	for _, raw in doc do
		local s = silence(env, raw)
		if s then
			table.insert(out, s)
		end
	end
	table.sort(out, M.before)
	return out, nil
end

-- POST .../silences answers `{"silenceID": "..."}`.
function M.parseCreated(env: Env, body: string): string?
	local ok, doc = pcall(env.decode, body)
	if not ok or type(doc) ~= "table" then
		return nil
	end
	return str(env, doc.silenceID)
end

return M
