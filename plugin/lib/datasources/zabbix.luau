--!strict
-- Zabbix (alexanderzobnin-zabbix-datasource 6.10.2, a backend plugin whose
-- browser half does part of the work; ported from src/datasource:
-- datasource.ts query, migrations.ts migrate, utils.ts replaceTemplateVars /
-- zabbixTemplateFormat / getRangeScopedVars / convertZabbixUnit,
-- dataProcessor.ts alias functions, responseHandler.ts convertZabbixUnits /
-- isConvertibleToWide / convertToWide).
--
-- query(): every target is migrated to schema 13 and interpolated
-- (interpolateVariablesInQueries: the filters, tags, problem tags and SLA
-- filter with the plugin's regex format, itemids comma-joined, function
-- params; a filter a variable changed that is no regex becomes `/^...$/`;
-- `$__range` is the largest whole unit, `$__range_series` "range_series").
-- Metrics and item id targets go to /api/ds/query; on their frames the
-- browser applies the Alias functions (setAlias, replaceAlias,
-- setAliasByRegex, with the frame's `__zbx_*` scoped variables),
-- convertZabbixUnits (field custom.units -> a Grafana unit, `%` with min 0
-- max 100) and, when every frame's first two times agree, convertToWide.
-- Triggers and problems targets are Zabbix API chains (zabbix_api.luau)
-- whose frames come after the backend's; trigger count frames are made wide
-- the same way (they share one time, so the plugin's alignFrames never adds
-- points). A failing API call fails the whole query, as the rejected
-- promise does in the browser.
--
-- Not reproduced (ladder reasons): IT services, text and user macro
-- queries, counting triggers by items, problems with item values at problem
-- time, metrics through a direct database connection, annotation queries.
--
-- The job: one round for apiinfo.version (every API call waits for it) and
-- /api/ds/query together, then the chains' calls round by round.

local Env = require("../env")
local Format = require("../units/format")
local Frame = require("../frame/types")
local GrafanaSource = require("../source/grafana")
local Interpolate = require("../dashboard/interpolate")
local Regex = require("../regex")
local Response = require("../source/response")
local Step = require("../time/step")
local TransportTypes = require("../transport/types")
local Types = require("./types")
local ZabbixApi = require("./zabbix_api")

type Env = Env.Env
type Frame = Frame.Frame

local M = {}

M.TYPE = "alexanderzobnin-zabbix-datasource"

local MODE_METRICS, MODE_ITSERVICE, MODE_TEXT, MODE_ITEMID, MODE_TRIGGERS, MODE_PROBLEMS, MODE_MACROS =
	"0", "1", "2", "3", "4", "5", "6"

M.SCHEMA = 13

local function str(env: Env, v: any): string?
	v = Env.value(env, v)
	return if type(v) == "string" then v else nil
end

local function obj(env: Env, v: any): { [any]: any }?
	v = Env.value(env, v)
	return if type(v) == "table" then v else nil
end

-- A deep copy of decoded JSON; decoded arrays stay arrays.
local function copy(env: Env, v: any): any
	if type(v) ~= "table" or v == env.null then
		return v
	end
	local out: { [any]: any } = {}
	for k, x in v do
		out[k] = copy(env, x)
	end
	if getmetatable(v :: any) ~= nil and env.array then
		return env.array(out)
	end
	return out
end

local function arr(env: Env, t: { any }): { any }
	return if env.array then env.array(t) else t
end

local function isArray(v: any): boolean
	return type(v) == "table" and (getmetatable(v :: any) ~= nil or #v > 0)
end

-- migrations.ts --------------------------------------------------------------------

local function convertToRegex(s: string?): string
	return if s and s ~= "" then "/" .. s .. "/" else "/.*/"
end

local function child(t: { [string]: any }, k: string): { [string]: any }
	local v = t[k]
	if type(v) ~= "table" then
		v = {}
		t[k] = v
	end
	return v
end

-- isGrafana2target.
local function grafana2(env: Env, t: { [string]: any }): boolean
	local mode = Env.value(env, t.mode)
	if not (mode == nil or mode == 0 or mode == 2) then
		return false
	end
	local host = obj(env, t.host)
	local item = obj(env, t.item)
	local legacy = Env.value(env, t.hostFilter)
		or Env.value(env, t.itemFilter)
		or Env.value(env, t.downsampleFunction)
		or (if host then Env.value(env, host.host) else nil)
	return legacy ~= nil
		and legacy ~= ""
		and (item == nil or Env.value(env, item.filter) == nil)
		and (host == nil or Env.value(env, host.filter) == nil)
end

local function truthy(v: any): boolean
	return v ~= nil and v ~= false and v ~= 0 and v ~= ""
end

-- migrate(): a copy of the target in the current schema.
function M.migrate(raw: { [string]: any }, env: Env): { [string]: any }
	local t = copy(env, raw) :: { [string]: any }
	if not truthy(str(env, t.resultFormat)) then
		t.resultFormat = "time_series"
	end
	if isArray(Env.value(env, t.group)) then
		t.group = { filter = "" }
	end
	if grafana2(env, t) then
		local function name(k: string, field: string): any
			local o = obj(env, t[k])
			return if o then Env.value(env, o[field]) else nil
		end
		child(t, "group").filter = if name("group", "name") == "*" then "/.*/" else name("group", "name")
		child(t, "host").filter = if name("host", "name") == "*"
			then convertToRegex(str(env, t.hostFilter))
			else name("host", "name")
		child(t, "application").filter = if name("application", "name") == "*" then "" else name("application", "name")
		child(t, "item").filter = if name("item", "name") == "All"
			then convertToRegex(str(env, t.itemFilter))
			else name("item", "name")
		child(t, "macro").filter = if name("macro", "macro") == "*"
			then convertToRegex(str(env, t.macroFilter))
			else name("macro", "macro")
		return t
	end
	for _, f in (obj(env, t.functions) or {}) :: { any } do
		local def = if type(f) == "table" then obj(env, f.def) else nil
		if def and def.name == "percentil" then
			def.name = "percentile"
		end
	end
	if Env.value(env, t.queryType) == nil then
		local mode = Env.value(env, t.mode)
		if mode == "Metrics" then
			t.queryType = MODE_METRICS
		elseif mode ~= nil then
			t.queryType = mode
			t.mode = nil
		end
	end
	local qt = t.queryType
	if type(qt) == "number" then
		t.queryType = if qt == math.floor(qt) then string.format("%d", qt) else tostring(qt)
	end
	local options = obj(env, t.options)
	if options and options.sortProblems == "priority" then
		options.sortProblems = "severity"
	end
	if obj(env, t.itemTag) == nil then
		local app = obj(env, t.application)
		local appFilter = if app then str(env, app.filter) else nil
		t.itemTag = { filter = if appFilter and appFilter ~= "" then "Application: " .. appFilter else "" }
	end
	local triggers = obj(env, t.triggers)
	if triggers then
		local min = Env.value(env, triggers.minSeverity)
		if truthy(min) then
			child(t, "options").minSeverity = min
			triggers.minSeverity = nil
		end
		local count = Env.value(env, triggers.count)
		if truthy(count) then
			child(t, "options").count = count
			triggers.count = nil
		end
	end
	local schema = Env.value(env, t.schema)
	local function before(n: number): boolean
		return not (type(schema) == "number" and schema >= n)
	end
	if before(11) then
		if t.queryType == "6" then
			t.queryType = MODE_TRIGGERS
			t.countTriggersBy = "items"
		elseif t.queryType == "7" then
			t.queryType = MODE_TRIGGERS
			t.countTriggersBy = "problems"
		elseif t.queryType == "8" then
			t.queryType = MODE_MACROS
		end
	end
	options = obj(env, t.options)
	if before(12) and options then
		local min = Env.value(env, options.minSeverity)
		if type(min) == "number" and min ~= 0 then
			local sev: { any } = {}
			for v = 0, 5 do
				if v >= min then
					table.insert(sev, v)
				end
			end
			options.severities = arr(env, sev)
		end
	end
	if before(13) and t.queryType == MODE_PROBLEMS then
		local tags = obj(env, t.tags)
		local filter = if tags then str(env, tags.filter) else nil
		local existing = obj(env, t.problemTags)
		if filter and filter ~= "" and (existing == nil or #existing == 0) then
			local out: { any } = {}
			for _, tag in ZabbixApi.parseTags(filter) do
				if tag.tag and tag.tag ~= "" then
					table.insert(out, { tag = tag.tag, value = tag.value or "", operator = "1" })
				end
			end
			t.problemTags = arr(env, out)
			local nextTags = copy(env, tags) :: { [string]: any }
			nextTags.filter = ""
			t.tags = nextTags
		end
	end
	t.schema = M.SCHEMA
	return t
end

-- Blockers ----------------------------------------------------------------------------

local function dbConnection(env: Env, ds: Types.Datasource): boolean
	local jd = ds.json_data
	if jd == nil then
		return false
	end
	if Env.value(env, jd.dbConnectionEnable) == true then
		return true
	end
	local legacy = obj(env, jd.dbConnection)
	return legacy ~= nil and Env.value(env, legacy.enable) == true
end

function M.blocker(target: Types.Target, ctx: Types.BlockerContext, env: Env): string?
	if Env.value(env, target.hide) == true then
		return nil
	end
	if Env.value(env, target.fromAnnotations) == true then
		return "Zabbix annotation queries run in Grafana's browser"
	end
	local t = M.migrate(target, env)
	local qt = Env.value(env, t.queryType)
	if (qt == MODE_METRICS or qt == MODE_ITEMID) and dbConnection(env, ctx.ds) then
		return "Zabbix reads history through a direct database connection (dbConnectionEnable) in the browser"
	elseif qt == MODE_ITSERVICE then
		return "Zabbix IT services queries are not reproduced"
	elseif qt == MODE_TEXT then
		return "Zabbix text queries are not reproduced"
	elseif qt == MODE_MACROS then
		return "Zabbix user macro queries are not reproduced"
	elseif qt == MODE_TRIGGERS and Env.value(env, t.countTriggersBy) == "items" then
		return "Zabbix trigger counts by items are not reproduced"
	elseif qt == MODE_PROBLEMS then
		local o = obj(env, t.options)
		if o and Env.value(env, o.fetchHistoricalItemValue) == true then
			return "Zabbix problems with item values at problem time (fetchHistoricalItemValue) are not reproduced"
		end
	end
	return nil
end

-- Interpolation (utils.ts) ------------------------------------------------------------

-- zabbixTemplateFormat: a regex-escaped value, several as `(a|b)`.
function M.format(values: { string }, _var: Interpolate.Var, list: boolean): string
	if not list then
		return Regex.escape(values[1] or "")
	end
	local out = table.create(#values)
	for i, v in values do
		out[i] = Regex.escape(v)
	end
	return "(" .. table.concat(out, "|") .. ")"
end

-- zabbixItemIdsTemplateFormat.
function M.formatItemIds(values: { string }, _var: Interpolate.Var, list: boolean): string
	return if list then table.concat(values, ",") else values[1] or ""
end

-- replaceTemplateVars.
function M.replaceVars(text: string?, scope: Interpolate.Scope, format: Interpolate.Formatter?): string
	if text == nil or text == "" then
		return ""
	end
	local replaced = Interpolate.replace(text, scope, { format = format or M.format })
	if replaced ~= text and not ZabbixApi.isRegex(replaced) then
		replaced = "/^" .. replaced .. "$/"
	end
	return replaced
end

-- getRangeScopedVars over the request's variables.
function M.scope(base: Interpolate.Scope, from_ms: number, to_ms: number): Interpolate.Scope
	local range = to_ms - from_ms
	return Interpolate.merge(base, {
		__range_ms = Interpolate.value(string.format("%d", range)),
		__range_s = Interpolate.value(string.format("%d", math.floor(range / 1000 + 0.5))),
		__range = Interpolate.value(Step.formatInterval(range)),
		__range_series = Interpolate.value("range_series"),
	})
end

local function filterOf(env: Env, t: { [string]: any }, k: string): string?
	local o = obj(env, t[k])
	return if o then str(env, o.filter) else nil
end

-- interpolateVariablesInQueries for one migrated target.
function M.interpolate(t: { [string]: any }, scope: Interpolate.Scope, env: Env): { [string]: any }
	local q: { [string]: any } = {}
	for k, v in t do
		if v ~= env.null then
			q[k] = v
		end
	end
	local function filtered(k: string)
		local o = copy(env, obj(env, t[k]) or {}) :: { [string]: any }
		o.filter = M.replaceVars(filterOf(env, t, k), scope)
		q[k] = o
	end
	local oldItService = Env.value(env, t.itservice) ~= nil and (str(env, t.itServiceFilter) or "") == ""
	q.itServiceFilter = if oldItService then "/.*/" else M.replaceVars(str(env, t.itServiceFilter), scope)
	q.slaFilter = M.replaceVars(str(env, t.slaFilter), scope)
	q.itemids = M.replaceVars(str(env, t.itemids), scope, M.formatItemIds)
	q.textFilter = M.replaceVars(str(env, t.textFilter), scope)
	local fns = obj(env, t.functions)
	if fns then
		local out: { any } = {}
		for i, f in fns :: { any } do
			local fc = copy(env, f)
			local params = if type(fc) == "table" then obj(env, fc.params) else nil
			if params then
				local ps: { any } = {}
				for j, p in params :: { any } do
					if type(p) == "number" then
						ps[j] = tonumber(Interpolate.replace(tostring(p), scope)) or 0 / 0
					elseif type(p) == "string" then
						ps[j] = Interpolate.replace(p, scope)
					else
						ps[j] = p
					end
				end
				fc.params = arr(env, ps)
			end
			out[i] = fc
		end
		q.functions = arr(env, out)
	end
	filtered("tags")
	local pt = obj(env, t.problemTags)
	if pt then
		local out: { any } = {}
		for i, f in pt :: { any } do
			local fc = copy(env, f)
			if type(fc) == "table" then
				fc.tag = M.replaceVars(str(env, fc.tag), scope)
				fc.value = M.replaceVars(str(env, fc.value), scope)
			end
			out[i] = fc
		end
		q.problemTags = arr(env, out)
	end
	for _, k in { "group", "host", "application", "proxy", "trigger", "itemTag", "item" } do
		filtered(k)
	end
	return q
end

-- Post-processing of backend frames --------------------------------------------------

local function valueText(env: Env, v: any): string
	v = Env.value(env, v)
	if type(v) == "number" and v == math.floor(v) and math.abs(v) < 2 ^ 53 then
		return string.format("%d", v)
	end
	return if v == nil then "" else tostring(v)
end

-- The field's `__zbx_*` scoped variables over the request's variables, nil
-- without any.
local function fieldScope(env: Env, field: Frame.Field, base: Interpolate.Scope): Interpolate.Scope?
	local custom = if field.config then field.config.custom else nil
	local vars = if custom then obj(env, custom.scopedVars) else nil
	if vars == nil then
		return nil
	end
	local extra: Interpolate.Scope = {}
	for name, sv in vars do
		if type(name) == "string" and type(sv) == "table" then
			extra[name] = { values = { valueText(env, sv.value) }, texts = { valueText(env, sv.text) } }
		end
	end
	return Interpolate.merge(base, extra)
end

local function config(field: Frame.Field): Frame.FieldConfig
	local c = field.config
	if c == nil then
		c = {}
		field.config = c
	end
	return c :: Frame.FieldConfig
end

local function valueField(frame: Frame): Frame.Field?
	for _, f in frame.fields do
		if f.name ~= "Time" then
			return f
		end
	end
	return nil
end

-- String.prototype.replace with a `/regex/flags` or a literal (first match).
local function jsReplace(s: string, pattern: string, repl: string): string
	local re: Regex.Regex?
	if ZabbixApi.isRegex(pattern) then
		local ok, built = pcall(ZabbixApi.buildRegex, pattern)
		re = if ok then built else nil
	else
		re = Regex.compile(Regex.escape(pattern))
	end
	if re == nil then
		return s
	end
	local out = Regex.replace(re :: Regex.Regex, s, repl)
	return out
end

-- extractText: the first match of `pattern` in `s`, nil without one.
local function extractText(s: string, pattern: string): string?
	local re = Regex.compile(pattern)
	if re == nil then
		return nil
	end
	local m = Regex.exec(re :: Regex.Regex, s)
	return if m then string.sub(s, m.start, m.finish) else nil
end

local function setAlias(env: Env, frame: Frame, alias: string, base: Interpolate.Scope)
	if #frame.fields <= 2 then
		local vf = valueField(frame)
		local sc = if vf then fieldScope(env, vf, base) else nil
		if sc then
			alias = Interpolate.replace(alias, sc)
		end
		if vf then
			config(vf).displayName = alias
		end
		frame.name = alias
		return
	end
	for _, f in frame.fields do
		if f.type ~= "time" then
			local sc = fieldScope(env, f, base)
			if sc then
				alias = Interpolate.replace(alias, sc)
			end
			config(f).displayName = alias
		end
	end
end

local function replaceAlias(env: Env, frame: Frame, pattern: string, newAlias: string, base: Interpolate.Scope)
	if #frame.fields <= 2 then
		local alias = jsReplace(frame.name or "", pattern, newAlias)
		local vf = valueField(frame)
		local sc = if vf then fieldScope(env, vf, base) else nil
		if sc then
			alias = Interpolate.replace(alias, sc)
		end
		if vf then
			config(vf).displayName = alias
		end
		frame.name = alias
		return
	end
	for _, f in frame.fields do
		if f.type ~= "time" then
			local current = if f.config then f.config.displayName else nil
			local alias = if current then jsReplace(current, pattern, newAlias) else nil
			local sc = fieldScope(env, f, base)
			if sc and alias and alias ~= "" then
				alias = Interpolate.replace(alias, sc)
			end
			if alias and alias ~= "" then
				f.name = alias
			end
		end
	end
end

local function setAliasByRegex(frame: Frame, pattern: string)
	if #frame.fields <= 2 then
		local vf = valueField(frame)
		if vf then
			local shown = extractText(if vf.config then vf.config.displayName or "" else "", pattern)
			if shown == nil then
				return
			end
			config(vf).displayName = shown
		end
		local named = extractText(frame.name or "", pattern)
		if named then
			frame.name = named
		end
		return
	end
	for _, f in frame.fields do
		if f.type ~= "time" then
			local shown = extractText(if f.config then f.config.displayName or "" else "", pattern)
			if shown then
				config(f).displayName = shown
			end
		end
	end
end

-- applyFrontendFunctions: the target's Alias functions that have params, in
-- order (bindFunctionDefs).
function M.applyAliases(env: Env, frames: { Frame }, targets: { [string]: { [string]: any } }, base: Interpolate.Scope)
	for _, frame in frames do
		local t = if frame.refId then targets[frame.refId :: string] else nil
		local fns = if t then obj(env, t.functions) else nil
		for _, f in (fns or {}) :: { any } do
			local def = if type(f) == "table" then obj(env, f.def) else nil
			local name = if def then str(env, def.name) else nil
			local params = (if type(f) == "table" then obj(env, f.params) else nil) or {}
			local p1, p2 = str(env, params[1]), str(env, params[2])
			if name == "setAlias" and p1 then
				setAlias(env, frame, p1, base)
			elseif name == "setAliasByRegex" and p1 then
				setAliasByRegex(frame, p1)
			elseif name == "replaceAlias" and p1 and p2 then
				replaceAlias(env, frame, p1, p2, base)
			end
		end
	end
end

-- utils.getUnitsMap.
local UNITS: { [string]: string } = {
	["%"] = "percent",
	b = "decbits",
	bps = "bps",
	B = "bytes",
	Bps = "binBps",
	uptime = "dtdhms",
	qps = "qps",
	iops = "iops",
	Hz = "hertz",
	V = "volt",
	C = "celsius",
	RPM = "rotrpm",
	dBm = "dBm",
}

-- convertZabbixUnits: Zabbix units through the map, else a Grafana unit id
-- of the same name.
function M.convertUnits(env: Env, frames: { Frame })
	for _, frame in frames do
		for _, f in frame.fields do
			local custom = if f.config then f.config.custom else nil
			local zu = if custom then str(env, custom.units) else nil
			if zu and zu ~= "" then
				local unit = UNITS[zu] or (if Format.known(zu) then zu else nil)
				if unit then
					local c = config(f)
					c.unit = unit
					if unit == "percent" then
						c.min = 0
						c.max = 100
					end
				end
			end
		end
	end
end

-- isConvertibleToWide: at least two frames whose first two times equal the
-- first frame's.
function M.convertibleToWide(frames: { Frame }): boolean
	if #frames < 2 then
		return false
	end
	local first = Frame.timeField(frames[1])
	if first == nil then
		return false
	end
	for i = 2, #frames do
		local tf = Frame.timeField(frames[i])
		if tf == nil then
			return false
		end
		for j = 1, 2 do
			if tf.values[j] ~= first.values[j] then
				return false
			end
		end
	end
	return true
end

-- convertToWide: the longest frame's times and every frame's value field
-- named after its frame, as one frame "wide". A value column of another
-- length is cut or NULL-padded to the times (uPlot reads it that way).
function M.toWide(frames: { Frame }): { Frame }
	local longest, maxLen = 1, 0
	for i, f in frames do
		local tf = Frame.timeField(f)
		local n = if tf then #tf.values else 0
		if n > maxLen then
			longest, maxLen = i, n
		end
	end
	local time = Frame.timeField(frames[longest])
	if time == nil then
		return {}
	end
	local tf = time :: Frame.Field
	local fields: { Frame.Field } = { tf }
	for _, f in frames do
		local vf: Frame.Field? = nil
		for _, field in f.fields do
			if field.name == "Value" then
				vf = field
				break
			end
		end
		if vf == nil then
			continue
		end
		local v = vf :: Frame.Field
		v.name = f.name or ""
		local n = #tf.values
		if #v.values ~= n then
			local values = table.create(n)
			for i = 1, n do
				local x = v.values[i]
				values[i] = if x == nil then Frame.NULL else x
			end
			v.values = values
		end
		table.insert(fields, v)
	end
	return { { refId = frames[longest].refId, name = "wide", fields = fields } }
end

local function isProblems(frame: Frame): boolean
	local f = frame.fields[1]
	local custom = if f and f.config then f.config.custom else nil
	return f ~= nil and f.type == "other" and custom ~= nil and custom.type == "problems"
end

-- frontendQuery's post-processing: time series frames go wide when they can.
function M.frontendFrames(frames: { Frame }): { Frame }
	local first = frames[1]
	if first == nil or isProblems(first) or first.name == "macros" or Frame.timeField(first) == nil then
		return frames
	end
	if M.convertibleToWide(frames) then
		return M.toWide(frames)
	end
	return frames
end

-- The job ---------------------------------------------------------------------------

type Job = {
	ds: { type: string, uid: string },
	scope: Interpolate.Scope,
	from_ms: number,
	to_ms: number,
	-- Backend targets as sent, by refId, and their refIds in order.
	queries: { { [string]: any } },
	by_ref: { [string]: { [string]: any } },
	backend_refs: { string },
	-- Frontend targets in order and their frames once done.
	frontend: { ZabbixApi.Target },
	done: { [number]: { Frame } },
	version: string?,
	answers: { [string]: ZabbixApi.Answer },
	-- Tag -> what it answers: "dsq", "version" or a call key.
	tags: { [string]: string },
	sent: number,
	dsq: Types.PanelData?,
	error: string?,
}

local function chainTarget(
	env: Env,
	q: { [string]: any },
	refId: string,
	ds: { type: string, uid: string }
): ZabbixApi.Target
	return {
		ref_id = refId,
		mode = str(env, q.queryType) or "",
		group = filterOf(env, q, "group"),
		host = filterOf(env, q, "host"),
		application = filterOf(env, q, "application"),
		proxy = filterOf(env, q, "proxy"),
		trigger = filterOf(env, q, "trigger"),
		tags = filterOf(env, q, "tags"),
		problem_tags = obj(env, q.problemTags),
		evaltype = Env.value(env, q.evaltype),
		show_problems = str(env, q.showProblems) or "",
		count_by = str(env, q.countTriggersBy) or "",
		options = obj(env, q.options) or {},
		datasource = ds,
	}
end

function M.start(targets: { Types.Target }, ctx: Types.DsContext, env: Env): Types.Job
	local ds = { type = ctx.ds.type, uid = ctx.ds.uid }
	local scope = M.scope(ctx.scope, ctx.from_ms, ctx.to_ms)
	local job: Job = {
		ds = ds,
		scope = scope,
		from_ms = ctx.from_ms,
		to_ms = ctx.to_ms,
		queries = {},
		by_ref = {},
		backend_refs = {},
		frontend = {},
		done = {},
		answers = {},
		tags = {},
		sent = 0,
	}
	for i, raw in targets do
		if Env.value(env, raw.hide) == true then
			continue
		end
		local q = M.interpolate(M.migrate(raw, env), scope, env)
		local refId = str(env, q.refId) or string.char(64 + math.min(i, 26))
		q.refId = refId
		q.datasource = { type = ds.type, uid = ds.uid }
		local qt = Env.value(env, q.queryType)
		if qt == MODE_METRICS or qt == MODE_ITEMID then
			q.intervalMs = ctx.interval_ms
			q.maxDataPoints = ctx.max_points
			table.insert(job.queries, q)
			table.insert(job.backend_refs, refId)
			job.by_ref[refId] = q
		elseif qt == MODE_TRIGGERS or qt == MODE_PROBLEMS then
			table.insert(job.frontend, chainTarget(env, q, refId, ds))
		end
	end
	return job :: any
end

-- The `result` of a zabbix-api answer, or the error the browser shows (the
-- plugin's `message`).
function M.apiResult(response: TransportTypes.Response, env: Env): ZabbixApi.Answer
	local doc, err = Response.json(response, env, "Zabbix API")
	if err then
		local message = if type(doc) == "table" then str(env, doc.message) else nil
		return { error = message or err.message }
	end
	if type(doc) ~= "table" then
		return { error = "Zabbix API: the response is not a JSON object" }
	end
	return { value = Env.value(env, doc.result) }
end

-- The backend part: frames of every backend target in target order, an
-- error line per failed target.
local function backendData(job: Job, response: TransportTypes.Response, env: Env): Types.PanelData
	local data: Types.PanelData = { frames = {}, errors = {}, warnings = {} }
	local r = GrafanaSource.parseDsQuery(response, env)
	if not r.ok then
		for _, refId in job.backend_refs do
			table.insert(data.errors, refId .. ": " .. (r :: any).error.message)
		end
		return data
	end
	local results: { [string]: Frame.QueryResult } = (r :: any).results
	for _, refId in job.backend_refs do
		local res = results[refId]
		if res == nil then
			continue
		elseif res.ok then
			for _, f in (res :: any).frames :: { Frame } do
				f.refId = f.refId or refId
				table.insert(data.frames, f)
			end
			for _, w in (res :: any).warnings :: { string } do
				table.insert(data.warnings, w)
			end
		else
			table.insert(data.errors, refId .. ": " .. (res :: any).error.message)
		end
	end
	M.applyAliases(env, data.frames, job.by_ref, job.scope)
	M.convertUnits(env, data.frames)
	if M.convertibleToWide(data.frames) then
		data.frames = M.toWide(data.frames)
	end
	return data
end

local function apiRequest(job: Job, method: string, params: { [string]: any }, env: Env): TransportTypes.Request
	return {
		method = "POST",
		path = ZabbixApi.path(job.ds.uid),
		headers = { ["Content-Type"] = "application/json" },
		body = env.encode({ method = method, params = params }),
	}
end

local function nextTag(job: Job, what: string): string
	job.sent += 1
	local tag = "z" .. job.sent
	job.tags[tag] = what
	return tag
end

local function finish(job: Job): Types.Outcome
	local data: Types.PanelData = job.dsq or { frames = {}, errors = {}, warnings = {} }
	local front: { Frame } = {}
	for i = 1, #job.frontend do
		local frames: { Frame } = job.done[i] or {}
		for _, f in frames do
			table.insert(front, f)
		end
	end
	for _, f in M.frontendFrames(front) do
		table.insert(data.frames, f)
	end
	return { data = data }
end

function M.step(jobArg: Types.Job, answers: Types.Answers, env: Env): (Types.Job, { Types.DsRequest }, Types.Outcome?)
	local job = jobArg :: Job
	for tag, response in answers do
		local what = job.tags[tag]
		if what == "dsq" then
			job.dsq = backendData(job, response, env)
		elseif what == "version" then
			local a = M.apiResult(response, env)
			if a.error then
				job.error = a.error
			else
				local v = a.value
				job.version = if type(v) == "string" and v ~= "" then v else ZabbixApi.DEFAULT_VERSION
			end
		elseif what then
			job.answers[what] = M.apiResult(response, env)
		end
	end
	job.tags = {}
	if job.error then
		return jobArg, {}, { error = job.error }
	end
	local requests: { Types.DsRequest } = {}
	if #job.queries > 0 and job.sent == 0 then
		local body = {
			queries = job.queries,
			from = string.format("%d", job.from_ms),
			to = string.format("%d", job.to_ms),
		}
		table.insert(requests, {
			tag = nextTag(job, "dsq"),
			request = {
				method = "POST",
				path = GrafanaSource.DS_QUERY_PATH,
				headers = { ["Content-Type"] = "application/json" },
				body = env.encode(body),
			},
		})
	end
	if #job.frontend > 0 then
		if job.version == nil then
			table.insert(
				requests,
				{ tag = nextTag(job, "version"), request = apiRequest(job, "apiinfo.version", {}, env) }
			)
		else
			local c = ZabbixApi.calls(job.version :: string, job.answers, env)
			local from_s = math.ceil(job.from_ms / 1000)
			local to_s = math.ceil(job.to_ms / 1000)
			for i, t in job.frontend do
				if job.done[i] then
					continue
				end
				local status, result = ZabbixApi.run(function(): any
					local frame = if t.mode == MODE_PROBLEMS
						then ZabbixApi.problems(c, t, from_s, to_s)
						else ZabbixApi.triggers(c, t, from_s, to_s)
					return if frame then { frame } else {}
				end)
				if status == "error" then
					return jobArg, {}, { error = result :: string }
				elseif status == "done" then
					job.done[i] = result :: { Frame }
				end
			end
			for _, call in c.wanted do
				table.insert(
					requests,
					{ tag = nextTag(job, call.key), request = apiRequest(job, call.method, call.params, env) }
				)
			end
		end
	end
	if #requests > 0 then
		return jobArg, requests, nil
	end
	return jobArg, {}, finish(job)
end

local module: Types.DsModule = {
	types = { M.TYPE },
	blocker = M.blocker,
	start = M.start,
	step = M.step,
}

return module
