--!strict
-- One watch evaluation: the instant query's result becomes an observation
-- (how many series, how many cross the threshold), and the observation moves
-- the watch through ok -> pending -> firing the way a Prometheus alerting
-- rule's `for` does: the condition must hold on every evaluation for `for`
-- before it fires, and one evaluation without it resolves.
--
-- No data (an empty result) is not firing and is reported as such. NaN
-- samples never cross a threshold, whatever the operator. A failed query
-- changes nothing: a transient error must neither resolve a firing watch nor
-- restart a pending one.

local Frame = require("../frame/types")
local Settings = require("./settings")

type Watch = Settings.Watch
type Op = Settings.Op
type QueryResult = Frame.QueryResult

export type Observation = {
	-- Series with a sample.
	series: number,
	-- Series whose sample crosses the threshold.
	matching: number,
	-- Series whose sample is NaN.
	nan: number,
	-- The most extreme crossing sample, else the first sample; nil when no
	-- finite sample exists.
	value: number?,
	-- The query failed; nothing else is meaningful.
	error: string?,
	error_message: string?,
}

export type Status = "ok" | "pending" | "firing"

export type State = {
	status: Status,
	-- When the current status began.
	since_ms: number,
	-- When the condition began to hold (pending and firing), Prometheus' activeAt.
	active_ms: number?,
	-- Last evaluation (success or failure).
	eval_ms: number?,
	-- The definition the state belongs to (Settings.Watch.def).
	def: string,
	series: number,
	matching: number,
	value: number?,
	-- The last evaluation failed (error kind); status is carried over.
	error: string?,
	-- The last successful evaluation returned no series.
	no_data: boolean,
}

local M = {}

function M.compare(op: Op, value: number, threshold: number): boolean
	if value ~= value then
		return false
	end
	if op == ">" then
		return value > threshold
	elseif op == ">=" then
		return value >= threshold
	elseif op == "<" then
		return value < threshold
	elseif op == "<=" then
		return value <= threshold
	elseif op == "==" then
		return value == threshold
	end
	return value ~= threshold
end

-- Whether `a` is further past the threshold than `b`.
local function worse(op: Op, a: number, b: number): boolean
	if op == ">" or op == ">=" then
		return a > b
	elseif op == "<" or op == "<=" then
		return a < b
	end
	return false
end

local function finite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

-- The last non-missing sample of every number field: one per series for
-- vectors, the newest point for matrices, the value for scalars.
local function samples(result: QueryResult): { number }
	local out: { number } = {}
	if not result.ok then
		return out
	end
	for _, frame in result.frames do
		for _, field in frame.fields do
			if field.type == "number" then
				for i = #field.values, 1, -1 do
					local v = field.values[i]
					if type(v) == "number" then
						table.insert(out, v)
						break
					end
				end
			end
		end
	end
	return out
end

function M.observe(watch: Watch, result: QueryResult): Observation
	if not result.ok then
		return {
			series = 0,
			matching = 0,
			nan = 0,
			value = nil,
			error = result.error.kind,
			error_message = result.error.message,
		}
	end
	local obs: Observation = { series = 0, matching = 0, nan = 0, value = nil }
	local first: number? = nil
	local hit: number? = nil
	for _, v in samples(result) do
		obs.series += 1
		if v ~= v then
			obs.nan += 1
		else
			if first == nil then
				first = v
			end
			if M.compare(watch.op, v, watch.threshold) then
				obs.matching += 1
				if hit == nil or worse(watch.op, v, hit :: number) then
					hit = v
				end
			end
		end
	end
	local value = hit or first
	obs.value = if value and finite(value) then value else nil
	return obs
end

-- The state after observing `obs` at `now_ms`; `prev` is dropped when it
-- belongs to another definition.
function M.step(prev: State?, watch: Watch, obs: Observation, now_ms: number): State
	local p: State? = if prev and prev.def == watch.def then prev else nil
	if obs.error then
		if p then
			local carried = table.clone(p)
			carried.eval_ms = now_ms
			carried.error = obs.error
			return carried
		end
		return {
			status = "ok",
			since_ms = now_ms,
			eval_ms = now_ms,
			def = watch.def,
			series = 0,
			matching = 0,
			error = obs.error,
			no_data = false,
		}
	end
	local status: Status = if p then p.status else "ok"
	local since = if p then p.since_ms else now_ms
	local active = if p then p.active_ms else nil
	if obs.matching > 0 then
		if status == "ok" then
			active = now_ms
			if watch.for_ms <= 0 then
				status, since = "firing", now_ms
			else
				status, since = "pending", now_ms
			end
		elseif status == "pending" and now_ms - (active or now_ms) >= watch.for_ms then
			status, since = "firing", now_ms
		end
	else
		if status ~= "ok" then
			status, since = "ok", now_ms
		end
		active = nil
	end
	return {
		status = status,
		since_ms = since,
		active_ms = active,
		eval_ms = now_ms,
		def = watch.def,
		series = obs.series,
		matching = obs.matching,
		value = obs.value,
		error = nil,
		no_data = obs.series == 0,
	}
end

return M
