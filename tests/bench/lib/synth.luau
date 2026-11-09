--!strict
-- Synthetic server answers for the benchmark scenarios, shaped exactly like
-- the recorded fixtures (Grafana /api/ds/query timeseries-multi frames,
-- Prometheus matrix, Loki streams) but sized at will. Values come from a
-- seeded generator so two runs produce identical bytes, and a different seed
-- produces a different answer (a refresh with new data).

local M = {}

local function rng(seed: number): () -> number
	local state = (seed * 2654435761 + 12345) % 4294967296
	return function(): number
		state = (1664525 * state + 1013904223) % 4294967296
		return state / 4294967296
	end
end

-- A random walk per series around its own level, printed with full double
-- precision like Prometheus and Grafana do.
local function walk(rand: () -> number, level: number): () -> string
	local v = level
	return function(): string
		v = math.max(0, v + (rand() - 0.5) * level * 0.05)
		return tostring(v)
	end
end

local INSTANCES = 10

local function labelsFor(i: number): { [string]: string }
	return {
		instance = string.format("host-%02d:9100", (i - 1) % INSTANCES + 1),
		job = "synthetic",
		mode = string.format("mode%d", (i - 1) // INSTANCES + 1),
	}
end

local function labelsJson(labels: { [string]: string }): string
	local keys: { string } = {}
	for k in labels do
		table.insert(keys, k)
	end
	table.sort(keys)
	local parts = table.create(#keys)
	for i, k in keys do
		parts[i] = string.format("%q:%q", k, labels[k])
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

-- One Grafana /api/ds/query result for `refId`: `series` frames of `points`
-- samples spread evenly over [from_ms, to_ms].
function M.grafanaResult(
	refId: string,
	series: number,
	points: number,
	from_ms: number,
	to_ms: number,
	seed: number
): string
	local rand = rng(seed)
	local step = math.max(1, (to_ms - from_ms) // math.max(1, points - 1))
	local times = table.create(points)
	for p = 1, points do
		times[p] = tostring(from_ms + (p - 1) * step)
	end
	local timesJson = "[" .. table.concat(times, ",") .. "]"
	local frames = table.create(series)
	for i = 1, series do
		local labels = labelsFor(i)
		local next = walk(rand, 1 + i)
		local values = table.create(points)
		for p = 1, points do
			values[p] = next()
		end
		frames[i] = string.format(
			'{"schema":{"refId":%q,"meta":{"type":"timeseries-multi","typeVersion":[0,1],'
				.. '"custom":{"resultType":"matrix"},"executedQueryString":"synthetic"},"fields":['
				.. '{"name":"Time","type":"time","typeInfo":{"frame":"time.Time"},"config":{"interval":%d}},'
				.. '{"name":"Value","type":"number","typeInfo":{"frame":"float64"},"labels":%s,'
				.. '"config":{"displayNameFromDS":%q}}]},"data":{"values":[%s,[%s]]}}',
			refId,
			step,
			labelsJson(labels),
			labels.instance .. " " .. labels.mode,
			timesJson,
			table.concat(values, ",")
		)
	end
	return string.format('%q:{"status":200,"frames":[%s]}', refId, table.concat(frames, ","))
end

-- A whole /api/ds/query body for the queries of one request body.
function M.grafanaAnswer(request: any, series: number, points: number, seed: number): string
	local from_ms = tonumber(request.from) :: number
	local to_ms = tonumber(request.to) :: number
	local results: { string } = {}
	for i, q in request.queries do
		table.insert(results, M.grafanaResult(q.refId, series, points, from_ms, to_ms, seed * 31 + i))
	end
	return '{"results":{' .. table.concat(results, ",") .. "}}"
end

-- A Prometheus /api/v1/query_range matrix: `series` series stepping from
-- start_s to end_s every step_s seconds.
function M.promMatrix(series: number, start_s: number, end_s: number, step_s: number, seed: number): string
	local rand = rng(seed)
	local points = math.floor((end_s - start_s) / step_s) + 1
	local out = table.create(series)
	for i = 1, series do
		local next = walk(rand, 1 + i)
		local samples = table.create(points)
		for p = 1, points do
			samples[p] = string.format('[%d,"%s"]', start_s + (p - 1) * step_s, next())
		end
		out[i] = string.format('{"metric":%s,"values":[%s]}', labelsJson(labelsFor(i)), table.concat(samples, ","))
	end
	return '{"status":"success","data":{"resultType":"matrix","result":[' .. table.concat(out, ",") .. "]}}"
end

local LEVELS = { "debug", "info", "info", "info", "warn", "error" }
local APPS = { "checkout", "cart", "payments", "search", "auth" }
local PATHS = { "/api/v1/items", "/api/v1/cart", "/api/v1/pay", "/healthz", "/api/v1/search?q=shoes" }

-- A Loki /query_range streams answer: one line every `every_ms` from
-- start_ms to end_ms, newest first, spread over app x level streams. A
-- line's text depends only on its timestamp, so overlapping tail polls
-- answer byte-identical lines for the same instant, as Loki does.
function M.lokiStreams(start_ms: number, end_ms: number, every_ms: number): string
	local streams: { [string]: { string } } = {}
	local labelsOf: { [string]: string } = {}
	local keys: { string } = {}
	local last = end_ms // every_ms
	for seq = last, math.ceil(start_ms / every_ms), -1 do
		local app = APPS[seq % #APPS + 1]
		local level = LEVELS[(seq // #APPS) % #LEVELS + 1]
		local key = app .. "/" .. level
		local list = streams[key]
		if list == nil then
			list = {}
			streams[key] = list
			labelsOf[key] = labelsJson({
				app = app,
				detected_level = level,
				env = "dev",
				job = "synthetic",
				level = level,
				service_name = app,
			})
			table.insert(keys, key)
		end
		local text = string.format(
			'level=%s msg=\\"request served\\" path=%s status=%d duration=%dms seq=%d trace_id=%08x%08x',
			level,
			PATHS[seq % #PATHS + 1],
			if level == "error" then 500 else 200,
			seq * 7919 % 900 + 3,
			seq,
			seq * 2654435761 % 4294967296,
			seq * 40503 % 4294967296
		)
		table.insert(list, string.format('["%.0f","%s"]', seq * every_ms * 1000000, text))
	end
	local out = table.create(#keys)
	for i, key in keys do
		out[i] = string.format('{"stream":%s,"values":[%s]}', labelsOf[key], table.concat(streams[key], ","))
	end
	return '{"status":"success","data":{"resultType":"streams","result":[' .. table.concat(out, ",") .. '],"stats":{}}}'
end
return M
