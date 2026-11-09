--!strict
-- Grafana Incident (grafana-incident-datasource, the IRM app's datasource;
-- ported from its 0.133.0 frontend bundle, class extending
-- DataSourceWithBackend). Its targets go to /api/ds/query; the frontend only
-- interpolates `queryString` and answers query variables.
--
-- query(): interpolateVariablesInQueries replaces `queryString` through
-- templateSrv with the plugin's interpolateVariable, sets `datasource` to the
-- instance, and when the result is empty sends `originalQueryString` instead
-- (absent: no queryString at all). No other field is interpolated.
--
-- interpolateVariable drops "" and "$__all" from the values (empty: ""),
-- then writes filters by the variable's query type (`labels` ->
-- `label:'v'`, `severities` -> `severity:'v'`, `statuses` -> `status:v`),
-- else by the variable's name (the same three plus `roles` -> `role:v`),
-- else the text "unsupported query name"; filters are joined by spaces.
-- Which one applies depends on what Grafana hands the formatter:
-- - Grafana 12 and later (scenes dashboards): scenes' sceneInterpolator
--   passes only {name, type, multi, includeAll}, never the query, so only
--   the name counts. A variable named `severity` (not `severities`) gives
--   "unsupported query name" and the backend answers "Invalid query string":
--   Tern sends the same and shows Grafana's error.
-- - Grafana 11 (legacy dashboards): the variable model with its query, so
--   the query type wins, then the name.
-- With "All" selected and a custom all value (`$__all` on Incident
-- dashboards) the value goes in raw and the formatter never runs
-- (Interpolate keeps all values raw, as scenes' CustomAllValue does).
--
-- metricFindQuery: for query types severities, labels, statuses and roles,
-- POST /api/ds/query {queries: [{datasource, queryType, refId:
-- "metricFindQuery-<type>"}]} (no range); options from the first frame's
-- rows: value = the `value` field, else `label`, else ""; text = `text`,
-- else the value (scenes metricNamesToVariableValues). Other query types
-- have no options.

local Env = require("../env")
local Frame = require("../frame/types")
local GrafanaSource = require("../source/grafana")
local Interpolate = require("../dashboard/interpolate")
local Types = require("./types")

type Env = Env.Env

local M = {}

M.TYPE = "grafana-incident-datasource"

-- The first Grafana major version whose dashboards interpolate through scenes.
M.SCENES_MAJOR = 12

M.UNSUPPORTED = "unsupported query name"

local BY_QUERY_TYPE: { [string]: string } = {
	labels = "label:'%s'",
	severities = "severity:'%s'",
	statuses = "status:%s",
}

local BY_NAME: { [string]: string } = {
	labels = "label:'%s'",
	severities = "severity:'%s'",
	statuses = "status:%s",
	roles = "role:%s",
}

local VARIABLE_TYPES = table.freeze({ severities = true, labels = true, statuses = true, roles = true })

local function str(env: Env, v: any): string?
	v = Env.value(env, v)
	return if type(v) == "string" then v else nil
end

function M.format(values: { string }, var: Interpolate.Var, _list: boolean, ctx: Types.DsContext): string
	local kept: { string } = {}
	for _, v in values do
		if v ~= "" and v ~= "$__all" then
			table.insert(kept, v)
		end
	end
	if #kept == 0 then
		return ""
	end
	local pattern: string? = nil
	local legacy = ctx.grafana_major ~= nil and (ctx.grafana_major :: number) < M.SCENES_MAJOR
	local query = var.query
	if legacy and type(query) == "table" and type(query.queryType) == "string" then
		pattern = BY_QUERY_TYPE[query.queryType]
	end
	pattern = pattern or BY_NAME[var.name or ""]
	if pattern == nil then
		return M.UNSUPPORTED
	end
	local p = pattern :: string
	local out = table.create(#kept)
	for i, v in kept do
		out[i] = (string.gsub(p, "%%s", function()
			return v
		end))
	end
	return table.concat(out, " ")
end

function M.shape(target: Types.Target, ctx: Types.DsContext, env: Env): { [string]: any }
	local q: { [string]: any } = {}
	for k, v in target do
		if v ~= env.null then
			q[k] = v
		end
	end
	local raw = str(env, target.queryString)
	local formatted = if raw
		then Interpolate.replace(raw, ctx.scope, {
			format = function(values: { string }, var: Interpolate.Var, list: boolean): string
				return M.format(values, var, list, ctx)
			end,
		})
		else ""
	q.queryString = if formatted == "" then Env.value(env, target.originalQueryString) else formatted
	return q
end

type VarJob = { query_type: string?, ds: { type: string, uid: string }, sent: boolean }

function M.variable(query: any, ctx: Types.DsContext, env: Env): Types.Job
	local qt = if type(query) == "table" then str(env, query.queryType) else nil
	local job: VarJob = { query_type = qt, ds = { type = ctx.ds.type, uid = ctx.ds.uid }, sent = false }
	return job :: any
end

local function text(v: any): string?
	if Frame.isNull(v) then
		return nil
	elseif type(v) == "number" then
		return if v == math.floor(v) and math.abs(v) < 2 ^ 53 then string.format("%d", v) else tostring(v)
	end
	return tostring(v)
end

-- Options from the first frame of a metricFindQuery answer.
function M.options(frames: { Frame.Frame }): { Types.Option }
	local out: { Types.Option } = {}
	local frame = frames[1]
	if frame == nil then
		return out
	end
	local byName: { [string]: Frame.Field } = {}
	local rows = 0
	for _, f in frame.fields do
		if byName[f.name] == nil then
			byName[f.name] = f
		end
		rows = math.max(rows, #f.values)
	end
	local valueF, labelF, textF = byName.value, byName.label, byName.text
	for i = 1, rows do
		local value = (if valueF then text(valueF.values[i]) else nil)
			or (if labelF then text(labelF.values[i]) or "" else "")
		local t = (if textF then text(textF.values[i]) else nil) or value
		table.insert(out, { text = t, value = value })
	end
	return out
end

local function step(job: Types.Job, answers: Types.Answers, env: Env): (Types.Job, { Types.DsRequest }, Types.Outcome?)
	local j = job :: VarJob
	local qt = j.query_type
	if qt == nil or not VARIABLE_TYPES[qt] then
		return job, {}, { options = {} }
	end
	local refId = "metricFindQuery-" .. qt
	if not j.sent then
		j.sent = true
		local body = { queries = { { datasource = j.ds, queryType = qt, refId = refId } } }
		return job,
			{
				{
					tag = "vars",
					request = {
						method = "POST",
						path = GrafanaSource.DS_QUERY_PATH,
						headers = { ["Content-Type"] = "application/json" },
						body = env.encode(body),
					},
				},
			},
			nil
	end
	local r = GrafanaSource.parseDsQuery(answers.vars, env)
	if not r.ok then
		return job, {}, { error = (r :: any).error.message }
	end
	local res = (r :: any).results[refId] :: Frame.QueryResult?
	if res == nil then
		return job, {}, { options = {} }
	end
	if not res.ok then
		return job, {}, { error = (res :: any).error.message }
	end
	return job, {}, { options = M.options((res :: any).frames) }
end

M.step = step

local module: Types.DsModule = {
	types = { M.TYPE },
	shape = M.shape,
	step = step,
	variable = M.variable,
	format = M.format,
}

return module
