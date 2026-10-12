--!strict
-- Loki log results to log Lines and Frames. Two inputs reach the same Line
-- model:
-- - Loki direct `streams` (`data.result[i] = {stream, values}`); with the
--   `X-Loki-Response-Encoding-Flags: categorize-labels` request header (Loki
--   3.x) `stream` holds only the indexed labels and each value carries a third
--   element `{structuredMetadata, parsed}`; without it every label is in
--   `stream`.
-- - Grafana's Loki data frame (/api/ds/query, frameType LabeledTimeValues):
--   `labels`, `Time`, `Line`, `tsNs`, `labelTypes` (name -> "I" indexed,
--   "S" structured metadata, "P" parsed) and `id`.
-- Direct streams also become a frame of Grafana's shape, so the logs panel
-- and every other frame consumer read both data planes alike.
--
-- Lines are newest first (by nanosecond timestamp, then input order). A
-- line's `id` is its nanosecond timestamp plus a hash of its stream labels
-- and text: the same entry fetched twice (overlapping tail windows) gets the
-- same id, two streams logging the same text at the same instant do not.

local Env = require("../env")
local Frame = require("./types")
local LogsPanel = require("../panels/logs")

type Env = Env.Env
type Frame = Frame.Frame

export type Level = LogsPanel.Level
export type Labels = { [string]: string }

export type Line = {
	id: string,
	-- Epoch nanoseconds as Loki sends them (doubles cannot hold them exactly).
	ts_ns: string,
	time_ms: number,
	line: string,
	level: Level,
	-- Indexed (stream) labels; every label when the source did not categorize.
	labels: Labels,
	metadata: Labels,
	parsed: Labels,
	-- The source told the label kinds apart (Loki categorize-labels or
	-- Grafana labelTypes); otherwise parsed labels hide among `labels`.
	categorized: boolean,
}

local M = {}

M.FRAME_TYPE = "LabeledTimeValues"

-- 32-bit FNV-1a of `s` as 8 hex digits.
function M.hash(s: string): string
	local h = 2166136261
	for i = 1, #s do
		h = bit32.bxor(h, string.byte(s, i))
		-- h * 16777619 mod 2^32 without leaving exact double range.
		h = (bit32.lshift(h, 24) + h * 403) % 4294967296
	end
	return string.format("%08x", h)
end

-- Labels as `k="v"` sorted by name, the stable identity of a stream.
function M.labelsKey(labels: Labels): string
	local keys: { string } = {}
	for k in labels do
		table.insert(keys, k)
	end
	table.sort(keys)
	local parts: { string } = table.create(#keys)
	for i, k in keys do
		parts[i] = k .. "=" .. string.format("%q", labels[k])
	end
	return table.concat(parts, ",")
end

-- -1, 0, 1 comparing two decimal nanosecond strings.
function M.compareNs(a: string, b: string): number
	if #a ~= #b then
		return if #a < #b then -1 else 1
	end
	if a == b then
		return 0
	end
	return if a < b then -1 else 1
end

-- Epoch ms of a nanosecond string (sub-ms digits kept as a fraction).
function M.nsToMs(ns: string): number
	if #ns <= 6 then
		return (tonumber(ns) or 0) / 1e6
	end
	local ms = tonumber(string.sub(ns, 1, #ns - 6)) or 0
	local frac = tonumber(string.sub(ns, -6)) or 0
	return ms + frac / 1e6
end

-- Epoch ms as a nanosecond string (whole milliseconds).
function M.msToNs(ms: number): string
	return string.format("%d", math.floor(ms)) .. "000000"
end

local function strings(env: Env, raw: any): Labels
	local out: Labels = {}
	if type(raw) == "table" then
		for k, v in raw do
			if type(k) == "string" and not Env.isNull(env, v) and (type(v) == "string" or type(v) == "number") then
				out[k] = tostring(v)
			end
		end
	end
	return out
end

-- The level as Grafana's log model reads it: detected_level (Loki's own
-- detection), else a `level` label, else the first level word in the line.
local function levelOf(line: string, labels: Labels, metadata: Labels, parsed: Labels): Level
	local key = metadata.detected_level
		or labels.detected_level
		or labels.level
		or parsed.level
		or metadata.level
		or parsed.detected_level
	if key and key ~= "" then
		local level: Level = LogsPanel.levelFromKey(key)
		local known = level ~= "unknown"
		if known then
			return level
		end
	end
	return LogsPanel.level(line)
end

local function makeLine(
	ns: string,
	text: string,
	labels: Labels,
	metadata: Labels,
	parsed: Labels,
	categorized: boolean,
	streamKey: string
): Line
	return {
		id = ns .. "_" .. M.hash(streamKey .. "\n" .. text),
		ts_ns = ns,
		time_ms = M.nsToMs(ns),
		line = text,
		level = levelOf(text, labels, metadata, parsed),
		labels = labels,
		metadata = metadata,
		parsed = parsed,
		categorized = categorized,
	}
end

-- Newest first, ties in input order.
function M.sort(lines: { Line })
	local order: { [Line]: number } = {}
	for i, l in lines do
		order[l] = i
	end
	table.sort(lines, function(a: Line, b: Line): boolean
		local c = M.compareNs(a.ts_ns, b.ts_ns)
		if c ~= 0 then
			return c > 0
		end
		return order[a] < order[b]
	end)
end

local function isNs(v: any): boolean
	return type(v) == "string" and #v > 0 and #v <= 20 and string.match(v, "^%d+$") ~= nil
end

-- Loki `data` with resultType "streams" to lines, newest first.
function M.streams(data: any, env: Env): { Line }
	local lines: { Line } = {}
	local result = if type(data) == "table" then Env.value(env, data.result) else nil
	if type(result) ~= "table" then
		return lines
	end
	local flags = Env.value(env, data.encodingFlags)
	local categorized = false
	if type(flags) == "table" then
		for _, f in flags do
			if f == "categorize-labels" then
				categorized = true
			end
		end
	end
	for _, s in result do
		if type(s) ~= "table" then
			continue
		end
		local labels = strings(env, Env.value(env, s.stream))
		local values = Env.value(env, s.values)
		if type(values) ~= "table" then
			continue
		end
		local streamKey = M.labelsKey(labels)
		for _, v in values do
			if type(v) ~= "table" or not isNs(v[1]) or type(v[2]) ~= "string" then
				continue
			end
			local extra = Env.value(env, v[3])
			local metadata: Labels = {}
			local parsed: Labels = {}
			if type(extra) == "table" then
				metadata = strings(env, Env.value(env, extra.structuredMetadata))
				parsed = strings(env, Env.value(env, extra.parsed))
			end
			table.insert(lines, makeLine(v[1], v[2], labels, metadata, parsed, categorized, streamKey))
		end
	end
	M.sort(lines)
	return lines
end

local function field(frame: Frame, name: string): Frame.Field?
	for _, f in frame.fields do
		if f.name == name then
			return f
		end
	end
	return nil
end

-- A logs frame: Grafana's LabeledTimeValues, or any frame with a time field
-- and a `Line`/`line`/`body` string field.
function M.isLogsFrame(frame: Frame): boolean
	local custom = if frame.meta then frame.meta.custom else nil
	if custom and custom.frameType == M.FRAME_TYPE then
		return true
	end
	if Frame.timeField(frame) == nil then
		return false
	end
	for _, name in { "Line", "line", "body" } do
		local f = field(frame, name)
		if f and f.type == "string" then
			return true
		end
	end
	return false
end

-- Lines of every logs frame (Grafana's or M.toFrame's), newest first.
function M.fromFrames(frames: { Frame }, env: Env): { Line }
	local lines: { Line } = {}
	for _, frame in frames do
		if not M.isLogsFrame(frame) then
			continue
		end
		local body = field(frame, "Line") or field(frame, "line") or field(frame, "body")
		if body == nil then
			continue
		end
		local bodyField = body :: Frame.Field
		local time = Frame.timeField(frame)
		local tsNs = field(frame, "tsNs")
		local labelsField = field(frame, "labels")
		local typesField = field(frame, "labelTypes")
		for j, raw in bodyField.values do
			local text = if type(raw) == "string" then raw elseif Frame.isNull(raw) then "" else tostring(raw)
			local ns = if tsNs then tsNs.values[j] else nil
			if not isNs(ns) then
				local t = if time then time.values[j] else nil
				if type(t) ~= "number" then
					continue
				end
				ns = string.format("%d", math.floor(t * 1e6 + 0.5))
			end
			local all = table.clone(bodyField.labels or {})
			for k, v in strings(env, if labelsField then labelsField.values[j] else nil) do
				all[k] = v
			end
			local types = strings(env, if typesField then typesField.values[j] else nil)
			local categorized = typesField ~= nil and next(types) ~= nil
			local labels: Labels, metadata: Labels, parsed: Labels = {}, {}, {}
			for k, v in all do
				local kind = types[k]
				if kind == "S" then
					metadata[k] = v
				elseif kind == "P" then
					parsed[k] = v
				else
					labels[k] = v
				end
			end
			table.insert(
				lines,
				makeLine(ns :: string, text, labels, metadata, parsed, categorized, M.labelsKey(labels))
			)
		end
	end
	M.sort(lines)
	return lines
end

-- Lines as one frame of Grafana's Loki shape (labels merged, labelTypes
-- saying where each came from).
function M.toFrame(lines: { Line }, refId: string?): Frame
	local n = #lines
	local labels, times, bodies, ns, types, ids =
		table.create(n), table.create(n), table.create(n), table.create(n), table.create(n), table.create(n)
	for i, l in lines do
		local all: Labels = {}
		local kinds: Labels = {}
		for k, v in l.labels do
			all[k], kinds[k] = v, "I"
		end
		for k, v in l.metadata do
			all[k], kinds[k] = v, "S"
		end
		for k, v in l.parsed do
			all[k], kinds[k] = v, "P"
		end
		labels[i] = all
		times[i] = math.floor(l.time_ms)
		bodies[i] = l.line
		ns[i] = l.ts_ns
		types[i] = if l.categorized then kinds else Frame.NULL
		ids[i] = l.id
	end
	return {
		refId = refId,
		fields = {
			Frame.field("labels", "other", labels),
			Frame.field("Time", "time", times),
			Frame.field("Line", "string", bodies),
			Frame.field("tsNs", "string", ns),
			Frame.field("labelTypes", "other", types),
			Frame.field("id", "string", ids),
		},
		meta = { custom = { frameType = M.FRAME_TYPE } },
	}
end

return M
