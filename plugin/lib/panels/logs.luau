--!strict
-- The logs panel (public/app/plugins/panel/logs: panelcfg.cue) over Loki
-- frames, with Grafana's log row model (public/app/features/logs/
-- logsModel.ts logSeriesToLogsModel, dedupLogRows; utils.ts getLogLevel,
-- getLogLevelFromKey; packages/grafana-data/src/types/logs.ts LogLevel):
-- - level: a `level` field, else the `detected_level` label, else the
--   `level` label (by name or syslog number), else the first level word
--   found in the line (`\bwarn\b`, `\berror\b`, ... case-insensitive);
-- - sortOrder Descending (newest first) or Ascending;
-- - dedupStrategy none, exact (ignoring ISO timestamps), numbers (ignoring
--   digits), signature (ignoring word characters), counted on the kept row;
-- - showTime, showLabels (labels that differ between rows; showCommonLabels
--   adds the shared ones), wrapLogMessage.
-- Levels color by Grafana's LogLevelColor read as tones: critical purple
-- (accent), error red, warning yellow, info green (success), debug and trace
-- blue (info), unknown muted.

local Common = require("./common")
local Env = require("../env")
local Frame = require("../frame/types")
local Json = require("./json")
local Range = require("../time/range")
local Regex = require("../regex")
local ui = require("../ui")

type Env = Env.Env
type Frame = Frame.Frame
type Node = ui.Node

export type Level = "critical" | "error" | "warning" | "info" | "debug" | "trace" | "unknown"

export type Row = {
	time_ms: number?,
	line: string,
	level: Level,
	labels: { [string]: string },
	-- Rows folded into this one by dedup.
	duplicates: number,
}

local M = {}

M.MAX_ROWS = 1000

-- LogLevel's keys in declaration order (getLogLevel prefers the earliest
-- match in the line, then the earlier key).
local KEYS: { { string } } = {
	{ "emerg", "critical" },
	{ "fatal", "critical" },
	{ "alert", "critical" },
	{ "crit", "critical" },
	{ "critical", "critical" },
	{ "warn", "warning" },
	{ "warning", "warning" },
	{ "err", "error" },
	{ "eror", "error" },
	{ "error", "error" },
	{ "info", "info" },
	{ "information", "info" },
	{ "informational", "info" },
	{ "notice", "info" },
	{ "dbug", "debug" },
	{ "debug", "debug" },
	{ "trace", "trace" },
	{ "unknown", "unknown" },
}

local BY_KEY: { [string]: Level } = {}
for _, kv in KEYS do
	BY_KEY[kv[1]] = kv[2] :: Level
end

local NUMERIC: { [string]: Level } = {
	["0"] = "critical",
	["1"] = "critical",
	["2"] = "critical",
	["3"] = "error",
	["4"] = "warning",
	["5"] = "info",
	["6"] = "info",
	["7"] = "debug",
}

local TONES: { [Level]: string } = {
	critical = "accent",
	error = "error",
	warning = "warning",
	info = "success",
	debug = "info",
	trace = "info",
	unknown = "muted",
}

function M.tone(level: Level): string
	return TONES[level]
end

-- getLogLevelFromKey: a level name (any case) or a syslog number.
function M.levelFromKey(key: string | number): Level
	local s = if type(key) == "number" then tostring(key) else key
	local named = BY_KEY[string.lower(s)]
	if named then
		return named :: Level
	end
	if type(key) == "number" and key % 1 == 0 then
		return NUMERIC[string.format("%d", key)] or "unknown"
	end
	if string.match(s, "^%-?%d+$") then
		local n = tonumber(s) :: number
		if #s == #string.format("%d", n) then
			return NUMERIC[s] or "unknown"
		end
	end
	return "unknown"
end

local function isWordByte(b: number?): boolean
	return b ~= nil and ((b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95)
end

-- getLogLevel: the level word that appears first in the line.
function M.level(line: string): Level
	if line == "" then
		return "unknown"
	end
	local lower = string.lower(line)
	local best: Level = "unknown"
	local bestAt: number? = nil
	for _, kv in KEYS do
		local key = kv[1]
		local init = 1
		while true do
			local a, b = string.find(lower, key, init, true)
			if a == nil or b == nil then
				break
			end
			if not isWordByte(string.byte(lower, a - 1)) and not isWordByte(string.byte(lower, b + 1)) then
				if bestAt == nil or a < bestAt then
					best = kv[2] :: Level
					bestAt = a
				end
				break
			end
			init = a + 1
		end
	end
	return best
end

local ISO_DATE = (
	Regex.compile("\\d{4}-[01]\\d-[0-3]\\dT[0-2]\\d:[0-5]\\d:[0-6]\\d[,\\.]\\d+([+-][0-2]\\d:[0-5]\\d|Z)", "g")
) :: Regex.Regex

local function dedupKey(line: string, strategy: string): string
	if strategy == "exact" then
		return (Regex.replace(ISO_DATE, line, ""))
	elseif strategy == "numbers" then
		return (string.gsub(line, "%d", ""))
	elseif strategy == "signature" then
		return (string.gsub(line, "[%w_]", ""))
	end
	return line
end

-- dedupLogRows: a row equal to the previous kept row under the strategy
-- folds into it.
function M.dedup(rows: { Row }, strategy: string): { Row }
	if strategy ~= "exact" and strategy ~= "numbers" and strategy ~= "signature" then
		return rows
	end
	local out: { Row } = {}
	local prevKey: string? = nil
	for _, r in rows do
		local k = dedupKey(r.line, strategy)
		if prevKey ~= nil and k == prevKey then
			out[#out].duplicates += 1
		else
			local copy = table.clone(r)
			copy.duplicates = 0
			table.insert(out, copy)
			prevKey = k
		end
	end
	return out
end

local function labelsOf(env: Env, v: any): { [string]: string }
	local out: { [string]: string } = {}
	local t = Json.tbl(env, v)
	if t and v ~= Frame.NULL then
		for k, x in t do
			if type(k) == "string" and (type(x) == "string" or type(x) == "number") then
				out[k] = tostring(x)
			end
		end
	end
	return out
end

local function findField(frame: Frame, pred: (Frame.Field) -> boolean): Frame.Field?
	for _, f in frame.fields do
		if pred(f) then
			return f
		end
	end
	return nil
end

-- Log rows of every logs frame (a time field and a string body), sorted
-- and deduplicated per the panel options.
function M.rows(panel: any, frames: { Frame }, env: Env): { Row }
	local options = Json.obj(env, Json.path(env, panel, "options"))
	local rows: { Row } = {}
	for _, frame in frames do
		local timeField = Frame.timeField(frame)
		local body = findField(frame, function(f): boolean
			return f.type == "string" and (f.name == "Line" or f.name == "line" or f.name == "body")
		end) or findField(frame, function(f): boolean
			return f.type == "string" and f.name ~= "tsNs" and f.name ~= "id"
		end)
		if body == nil then
			continue
		end
		local bodyField = body :: Frame.Field
		local labelsField = findField(frame, function(f): boolean
			return f.name == "labels" and f.type == "other"
		end)
		local levelField = findField(frame, function(f): boolean
			return f.name == "level" and (f.type == "string" or f.type == "number")
		end)
		for j, v in bodyField.values do
			local line = if type(v) == "string" then v elseif Frame.isNull(v) then "" else tostring(v)
			local labels = table.clone(bodyField.labels or {})
			if labelsField then
				for k, x in labelsOf(env, labelsField.values[j]) do
					labels[k] = x
				end
			end
			local key: any = if levelField then levelField.values[j] else nil
			if key == nil or key == "" or Frame.isNull(key) then
				key = labels.detected_level or labels.level
			end
			local level: Level
			if type(key) == "string" and key ~= "" or type(key) == "number" then
				level = M.levelFromKey(key)
			else
				level = M.level(line)
			end
			local t = if timeField then timeField.values[j] else nil
			table.insert(rows, {
				time_ms = if type(t) == "number" then t else nil,
				line = line,
				level = level,
				labels = labels,
				duplicates = 0,
			})
		end
	end
	local ascending = Json.str(env, options.sortOrder) == "Ascending"
	local indexed: { { row: Row, at: number } } = table.create(#rows)
	for i, r in rows do
		indexed[i] = { row = r, at = i }
	end
	table.sort(indexed, function(a, b): boolean
		local ta, tb = a.row.time_ms or -math.huge, b.row.time_ms or -math.huge
		if ta ~= tb then
			return if ascending then ta < tb else ta > tb
		end
		return a.at < b.at
	end)
	for i, x in indexed do
		rows[i] = x.row
	end
	return M.dedup(rows, Json.str(env, options.dedupStrategy) or "none")
end

-- Labels with the same value on every row.
function M.commonLabels(rows: { Row }): { [string]: string }
	if #rows == 0 then
		return {}
	end
	local common = table.clone(rows[1].labels)
	for i = 2, #rows do
		for k, v in common do
			if rows[i].labels[k] ~= v then
				common[k] = nil
			end
		end
	end
	return common
end

local LEVEL_TAGS: { [Level]: string } = {
	critical = "CRIT ",
	error = "ERROR",
	warning = "WARN ",
	info = "INFO ",
	debug = "DEBUG",
	trace = "TRACE",
	unknown = "",
}

local function formatTime(ms: number, offsetMin: number?): string
	local whole = math.floor(ms)
	return Range.formatMs(whole, offsetMin) .. string.format(".%03d", whole % 1000)
end

function M.view(panel: any, frames: { Frame }, env: Env, opts: Common.Options): Node
	local options = Json.obj(env, Json.path(env, panel, "options"))
	local rows = M.rows(panel, frames, env)
	if #rows == 0 then
		return ui.muted("No logs", { key = opts.key })
	end
	local showTime = Json.bool(env, options.showTime) ~= false
	local showLabels = if opts.show_labels ~= nil then opts.show_labels else Json.bool(env, options.showLabels) == true
	local showCommon = Json.bool(env, options.showCommonLabels) == true
	local wrap = Json.bool(env, options.wrapLogMessage) ~= false
	local common = if showLabels and not showCommon then M.commonLabels(rows) else {}
	local nodes: { Node } = {}
	for i = 1, math.min(#rows, M.MAX_ROWS) do
		local r = rows[i]
		local spans: { ui.SpanLike } = {}
		if showTime and r.time_ms then
			table.insert(spans, ui.span(formatTime(r.time_ms :: number, opts.offset_min) .. " ", "muted"))
		end
		local tag = LEVEL_TAGS[r.level]
		if tag ~= "" then
			table.insert(spans, ui.span(tag .. " ", M.tone(r.level)))
		end
		if showLabels then
			local keys: { string } = {}
			for k, v in r.labels do
				if common[k] ~= v then
					table.insert(keys, k)
				end
			end
			table.sort(keys)
			local parts: { string } = table.create(#keys)
			for k, name in keys do
				parts[k] = name .. "=" .. r.labels[name]
			end
			if #parts > 0 then
				table.insert(spans, ui.span(table.concat(parts, " ") .. " ", "dim"))
			end
		end
		table.insert(spans, r.line)
		if r.duplicates > 0 then
			table.insert(spans, ui.span(string.format(" (x%d)", r.duplicates + 1), "muted"))
		end
		local props: { [string]: any } = { key = "l" .. i }
		if wrap then
			props.wrap = "word"
		else
			props.truncate = "end"
		end
		table.insert(nodes, ui.text(spans, props))
	end
	if #rows > M.MAX_ROWS then
		table.insert(nodes, ui.muted(string.format("%d more lines", #rows - M.MAX_ROWS), { key = "more" }))
	end
	return ui.col(nodes, { key = opts.key, gap = "none", role = "tern-grafana.logs" })
end

return M
