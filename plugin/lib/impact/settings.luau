--!strict
-- The `impact` section of the config file (docs/annotations.md). Off until
-- `enabled` is true; triggered by the same command patterns as annotations.
-- `signals` is either one list for every context or an object mapping a
-- context name (or "*" for the rest) to its list.

local AnnotationSettings = require("../annotations/settings")
local Step = require("../time/step")
local Types = require("../config/types")

type Config = Types.Config
type Problem = Types.Problem

export type Bad = "up" | "down" | "none"

export type SignalSpec = {
	name: string,
	-- PromQL with optional {{namespace}}, {{service}}, {{cwd_basename}}.
	expr: string,
	-- A Grafana unit id ("s", "percentunit", "reqps", ...).
	unit: string?,
	-- Which direction is a regression (tone of the delta).
	bad: Bad,
}

export type Settings = {
	enabled: boolean,
	on: AnnotationSettings.On,
	-- Length of the before and the after window.
	window_ms: number,
	context: string?,
	-- Context name or "*" -> signals.
	signals: { [string]: { SignalSpec } },
}

local M = {}

M.DEFAULT_WINDOW = "15m"
M.MIN_WINDOW_MS = 60 * 1000
M.MAX_WINDOW_MS = 6 * 3600 * 1000
M.MAX_SIGNALS = 12
M.PLACEHOLDERS = table.freeze({ "namespace", "service", "cwd_basename" })

local KNOWN = { "context", "enabled", "on", "signals", "window" }
local SIGNAL_KEYS = { "bad", "expr", "name", "unit" }

local function problem(problems: { Problem }, path: string, message: string)
	table.insert(problems, { path = if path == "" then "impact" else "impact." .. path, message = message })
end

local function isArray(v: any): boolean
	return type(v) == "table" and (next(v) == nil or v[1] ~= nil)
end

local function readSignal(raw: any, path: string, problems: { Problem }): SignalSpec?
	if type(raw) ~= "table" or isArray(raw) and next(raw) ~= nil then
		problem(problems, path, 'must be an object such as {"name": "errors", "expr": "..."}')
		return nil
	end
	local before = #problems
	for key in raw do
		if not table.find(SIGNAL_KEYS, key) then
			problem(problems, path .. "." .. tostring(key), "unknown key (known: bad, expr, name, unit)")
		end
	end
	if type(raw.name) ~= "string" or string.match(raw.name, "^%s*$") then
		problem(problems, path .. ".name", "is required: a short label")
	end
	if type(raw.expr) ~= "string" or string.match(raw.expr, "^%s*$") then
		problem(problems, path .. ".expr", "is required: a PromQL expression")
	else
		for name in string.gmatch(raw.expr, "{{%s*([^}]-)%s*}}") do
			if not table.find(M.PLACEHOLDERS, name) then
				problem(
					problems,
					path .. ".expr",
					string.format("unknown placeholder {{%s}} (known: namespace, service, cwd_basename)", name)
				)
			end
		end
	end
	if raw.unit ~= nil and type(raw.unit) ~= "string" then
		problem(problems, path .. ".unit", "must be a Grafana unit id such as s or percentunit")
	end
	if raw.bad ~= nil and raw.bad ~= "up" and raw.bad ~= "down" and raw.bad ~= "none" then
		problem(problems, path .. ".bad", 'must be "up", "down" or "none"')
	end
	if #problems ~= before then
		return nil
	end
	return {
		name = raw.name,
		expr = raw.expr,
		unit = if raw.unit ~= "" then raw.unit else nil,
		bad = raw.bad or "up",
	}
end

local function readList(raw: any, path: string, problems: { Problem }): { SignalSpec }?
	if not isArray(raw) then
		problem(problems, path, "must be a list of signals")
		return nil
	end
	if #raw > M.MAX_SIGNALS then
		problem(problems, path, string.format("at most %d signals", M.MAX_SIGNALS))
		return nil
	end
	local out: { SignalSpec } = {}
	for i, v in raw do
		local s = readSignal(v, string.format("%s[%d]", path, i), problems)
		if s then
			table.insert(out, s)
		end
	end
	return out
end

function M.read(config: Config?): (Settings, { Problem })
	local problems: { Problem } = {}
	local settings: Settings = {
		enabled = false,
		on = "success",
		window_ms = Step.parseDuration(M.DEFAULT_WINDOW) :: number,
		context = nil,
		signals = {},
	}
	local raw = if config then config.impact else nil
	if raw == nil then
		return settings, problems
	end
	if type(raw) ~= "table" or isArray(raw) and next(raw) ~= nil then
		problem(problems, "", "must be an object")
		return settings, problems
	end
	for key in raw do
		if not table.find(KNOWN, key) then
			problem(problems, tostring(key), "unknown key (known: " .. table.concat(KNOWN, ", ") .. ")")
		end
	end
	if raw.enabled ~= nil then
		if type(raw.enabled) == "boolean" then
			settings.enabled = raw.enabled
		else
			problem(problems, "enabled", "must be true or false")
		end
	end
	if raw.on ~= nil then
		settings.on = AnnotationSettings.readOn(raw.on, "impact", problems) or settings.on
	end
	if raw.window ~= nil then
		local ms = if type(raw.window) == "string" then Step.parseDuration(raw.window) else nil
		if ms == nil or ms < M.MIN_WINDOW_MS or ms > M.MAX_WINDOW_MS then
			problem(problems, "window", 'must be a duration from "1m" to "6h", such as "15m"')
		else
			settings.window_ms = ms
		end
	end
	if raw.context ~= nil then
		settings.context = AnnotationSettings.readContext(raw.context, config, "impact", problems)
	end
	local sig = raw.signals
	if sig ~= nil then
		if isArray(sig) then
			local list = readList(sig, "signals", problems)
			if list then
				settings.signals["*"] = list
			end
		elseif type(sig) == "table" then
			for ctx, list in sig do
				local name = tostring(ctx)
				if name ~= "*" and config and config.contexts[name] == nil then
					problem(problems, "signals." .. name, string.format("no context named %q", name))
				else
					local read = readList(list, "signals." .. name, problems)
					if read then
						settings.signals[name] = read
					end
				end
			end
		else
			problem(problems, "signals", "must be a list of signals or an object of context name to list")
		end
	end
	return settings, problems
end

-- The configured signals for `context` (its own list, else "*"), or nil.
function M.signalsFor(settings: Settings, context: string): { SignalSpec }?
	local list = settings.signals[context] or settings.signals["*"]
	return if list and #list > 0 then list else nil
end

return M
