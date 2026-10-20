--!strict
-- limit: packages/grafana-data/src/transformations/transformers/limit.ts
-- (https://raw.githubusercontent.com/grafana/grafana/main/packages/
-- grafana-data/src/transformations/transformers/limit.ts). Every frame
-- longer than `limitField` (default 10) keeps its first `limitField` rows, or
-- its last -`limitField` when negative. A string limit (a dashboard variable,
-- interpolated before this runs) reads as parseInt(s, 10); one that is not
-- a number leaves the frames alone, as `length > NaN` is false in Grafana.

local Frame = require("../../frame/types")
local Json = require("../json")
local Shared = require("./shared")

type Frame = Frame.Frame
type Field = Frame.Field
type Ctx = Shared.Ctx

local M = {}

local DEFAULT_LIMIT = 10
local NAN = 0 / 0

-- parseInt(s, 10).
local function parseInt(s: string): number
	local sign, digits = string.match(s, "^%s*([+-]?)(%d+)")
	if digits == nil then
		return NAN
	end
	local n = tonumber(digits) :: number
	return if sign == "-" then -n else n
end

-- ToIntegerOrInfinity, then clamped as Array.prototype.slice clamps.
local function sliceIndex(x: number, len: number): number
	if x ~= x then
		return 0
	end
	local n = if x < 0 then math.ceil(x) else math.floor(x)
	if n < 0 then
		return math.max(len + n, 0)
	end
	return math.min(n, len)
end

-- values.slice(from, to), 0-based and end-exclusive like JavaScript.
local function slice(values: { any }, from: number, to: number): { any }
	local len = #values
	local a, b = sliceIndex(from, len), sliceIndex(to, len)
	local out: { any } = table.create(math.max(b - a, 0))
	for i = a + 1, b do
		out[i - a] = values[i]
	end
	return out
end

function M.unsupported(_options: any, _ctx: Ctx): string?
	return nil
end

function M.apply(data: { Frame }, options: any, ctx: Ctx): { Frame }
	local raw = Json.path(ctx.env, options, "limitField")
	local limit: number = DEFAULT_LIMIT
	if type(raw) == "string" then
		limit = parseInt(raw)
	elseif raw ~= nil then
		limit = Shared.jsNumber(raw)
	end
	if limit ~= limit then
		return data
	end
	local out: { Frame } = table.create(#data)
	for i, frame in data do
		if Shared.length(frame) > limit then
			local fields: { Field } = table.create(#frame.fields)
			for k, f in frame.fields do
				local len = #f.values
				fields[k] = Shared.withValues(
					f,
					if limit >= 0 then slice(f.values, 0, limit) else slice(f.values, len + limit, len)
				)
			end
			out[i] = Shared.withFields(frame, fields)
		else
			out[i] = frame
		end
	end
	return out
end

return M
