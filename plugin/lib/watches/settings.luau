--!strict
-- The `watches` section of the config file (docs/watches.md): personal
-- PromQL threshold watches the host polls in the background. The validator
-- keeps the section as written; this module gives it meaning. A bad watch is
-- skipped with a problem naming its path, so one typo never disables the
-- others.

local BlobCache = require("../render/blob_cache")
local Step = require("../time/step")
local Types = require("../config/types")

type Config = Types.Config
type Problem = Types.Problem

export type Op = ">" | ">=" | "<" | "<=" | "==" | "!="
export type Severity = "critical" | "error" | "warning" | "info"

export type Watch = {
	name: string,
	-- nil: the host's default context at poll time.
	context: string?,
	expr: string,
	op: Op,
	threshold: number,
	for_ms: number,
	severity: Severity,
	interval_ms: number,
	-- Changes whenever what the watch evaluates changes; state built for an
	-- older definition is dropped.
	def: string,
}

local M = {}

M.DEFAULT_FOR_MS = 0
M.DEFAULT_SEVERITY = "warning" :: Severity
M.DEFAULT_INTERVAL_MS = 60000
M.MIN_INTERVAL_MS = 15000
-- Bounds the work of one poll and the kv summary.
M.MAX_WATCHES = 32
M.MAX_NAME = 64
M.MAX_EXPR = 8192

local OPS: { [string]: boolean } =
	{ [">"] = true, [">="] = true, ["<"] = true, ["<="] = true, ["=="] = true, ["!="] = true }
local SEVERITIES: { [string]: boolean } = { critical = true, error = true, warning = true, info = true }
local KNOWN: { [string]: boolean } = {
	name = true,
	context = true,
	expr = true,
	op = true,
	threshold = true,
	["for"] = true,
	severity = true,
	interval = true,
}

local function problem(problems: { Problem }, path: string, message: string)
	table.insert(problems, { path = "watches" .. path, message = message })
end

local function duration(raw: any): number?
	if type(raw) ~= "string" then
		return nil
	end
	return Step.parseDuration(raw)
end

local function finite(n: any): boolean
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- One entry; nil (with problems) when it cannot be used.
local function readWatch(config: Config, raw: any, path: string, problems: { Problem }): Watch?
	if type(raw) ~= "table" then
		problem(problems, path, "must be an object with name, expr, op and threshold")
		return nil
	end
	local bad = false
	local function fail(key: string, message: string)
		problem(problems, path .. "." .. key, message)
		bad = true
	end
	local keys: { string } = {}
	for key in raw do
		table.insert(keys, tostring(key))
	end
	table.sort(keys)
	for _, key in keys do
		if not KNOWN[key] then
			problem(
				problems,
				path .. "." .. key,
				"unknown key (known: context, expr, for, interval, name, op, severity, threshold)"
			)
		end
	end
	local name = raw.name
	if type(name) ~= "string" or name == "" or #name > M.MAX_NAME then
		fail("name", string.format("is required: a non-empty string of at most %d characters", M.MAX_NAME))
	end
	local context = raw.context
	if context ~= nil and (type(context) ~= "string" or config.contexts[context] == nil) then
		local names: { string } = {}
		for n in config.contexts do
			table.insert(names, n)
		end
		table.sort(names)
		fail(
			"context",
			string.format("no context named %q (defined: %s)", tostring(context), table.concat(names, ", "))
		)
	end
	local expr = raw.expr
	if type(expr) ~= "string" or string.match(expr, "^%s*$") or #expr > M.MAX_EXPR then
		fail("expr", "is required: a PromQL expression")
	end
	local op = raw.op
	if type(op) ~= "string" or not OPS[op] then
		fail("op", 'is required: one of ">", ">=", "<", "<=", "==", "!="')
	end
	local threshold = raw.threshold
	if not finite(threshold) then
		fail("threshold", "is required: a number")
	end
	local for_ms = M.DEFAULT_FOR_MS
	if raw["for"] ~= nil then
		local d = duration(raw["for"])
		if d == nil then
			fail("for", 'must be a duration such as "0s", "5m" or "1h30m"')
		else
			for_ms = d
		end
	end
	local severity: Severity = "warning"
	if raw.severity ~= nil then
		local s = if type(raw.severity) == "string" then string.lower(raw.severity) else nil
		if s and SEVERITIES[s] then
			severity = s :: Severity
		else
			fail("severity", "must be one of critical, error, warning, info")
		end
	end
	local interval_ms = M.DEFAULT_INTERVAL_MS
	if raw.interval ~= nil then
		local d = duration(raw.interval)
		if d == nil or d < M.MIN_INTERVAL_MS then
			fail(
				"interval",
				string.format('must be a duration of at least %ds such as "60s"', M.MIN_INTERVAL_MS // 1000)
			)
		else
			interval_ms = d
		end
	end
	if bad then
		return nil
	end
	local def =
		BlobCache.fnv1a64(table.concat({ context or "", expr, op, tostring(threshold), tostring(for_ms) }, "\1"))
	return {
		name = name,
		context = context,
		expr = expr,
		op = op :: Op,
		threshold = threshold,
		for_ms = for_ms,
		severity = severity,
		interval_ms = interval_ms,
		def = def,
	}
end

function M.read(config: Config?): ({ Watch }, { Problem })
	local problems: { Problem } = {}
	local watches: { Watch } = {}
	local raw = if config then config.watches else nil
	if raw == nil or config == nil then
		return watches, problems
	end
	if type(raw) ~= "table" or (next(raw) ~= nil and #raw == 0) then
		problem(problems, "", "must be a list of watches")
		return watches, problems
	end
	local seen: { [string]: boolean } = {}
	for i, entry in raw do
		local path = string.format("[%d]", i)
		local w = readWatch(config, entry, path, problems)
		if w then
			if seen[w.name] then
				problem(problems, path .. ".name", string.format("repeats %q; names must be unique", w.name))
			elseif #watches >= M.MAX_WATCHES then
				problem(problems, path, string.format("at most %d watches are polled", M.MAX_WATCHES))
			else
				seen[w.name] = true
				table.insert(watches, w)
			end
		end
	end
	return watches, problems
end

return M
