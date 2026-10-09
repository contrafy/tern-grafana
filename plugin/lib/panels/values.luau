--!strict
-- The values a stat, gauge or bar gauge shows: Grafana's
-- getFieldDisplayValues (packages/grafana-data/src/field/fieldDisplay.ts)
-- driven by the panel's `reduceOptions`:
-- - `values: false` (default): each matching field reduced by each calc
--   in `calcs` (default lastNotNull; an explicit empty list means last);
-- - `values: true`: every row of every matching field;
-- - `fields`: "" matches number fields, anything else is a byRegexp
--   pattern on the display name (bare text is anchored, "/re/" is not);
-- - `limit` (default 25) caps the values.
-- With nothing to show, one "No data" value (or the field's noValue).

local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Frame = require("../frame/types")
local Json = require("./json")
local Reduce = require("./reduce")

type Env = Env.Env
type Frame = Frame.Frame
type Item = FieldConfig.Item

export type Spark = {
	values: { any },
	times: { any }?,
	-- 1-based sample the calc picked (getSparklineHighlight), if any.
	highlight: number?,
}

export type Value = {
	title: string,
	display: FieldConfig.Display,
	-- nil for the "No data" placeholder.
	item: Item?,
	calc: string?,
	row: number?,
	spark: Spark?,
}

export type Options = {
	-- Compute sparklines (stat graphMode area).
	sparkline: boolean?,
	theme: any?,
	offset_min: number?,
}

local M = {}

M.DEFAULT_LIMIT = 25

function M.calcsOf(panel: any, env: Env): { string }
	local raw = Json.path(env, panel, "options", "reduceOptions", "calcs")
	local t = Json.tbl(env, raw)
	if t == nil then
		return { "lastNotNull" }
	end
	local out: { string } = {}
	for _, c in t :: { any } do
		if type(c) == "string" then
			table.insert(out, c)
		end
	end
	if #out == 0 then
		return { "last" }
	end
	return out
end

-- The reduceOptions calcs Tern cannot compute, as a reason.
function M.unsupported(panel: any, env: Env): string?
	if Json.bool(env, Json.path(env, panel, "options", "reduceOptions", "values")) == true then
		return nil
	end
	for _, c in M.calcsOf(panel, env) do
		if not Reduce.supports(c) then
			return string.format("reducer %s is not supported", c)
		end
	end
	return nil
end

local function highlightOf(values: { any }, calc: string): number?
	local function present(v: any): boolean
		return not Frame.isNull(v) and not (type(v) == "number" and v ~= v)
	end
	if calc == "last" then
		return #values
	elseif calc == "first" then
		return 1
	elseif calc == "lastNotNull" then
		for k = #values, 1, -1 do
			if present(values[k]) then
				return k
			end
		end
	elseif calc == "firstNotNull" then
		for k = 1, #values do
			if present(values[k]) then
				return k
			end
		end
	elseif calc == "min" or calc == "max" then
		local best: number?, at: number? = nil, nil
		for k, v in values do
			if present(v) and type(v) == "number" then
				if best == nil or (calc == "min" and v < best) or (calc == "max" and v > best) then
					best, at = v, k
				end
			end
		end
		return at
	end
	return nil
end

-- getSmartDisplayNameForRow.
local function rowName(item: Item, items: { Item }, row: number, opts: Options): string
	if item.config.display_name then
		return item.config.display_name
	end
	local parts: { string } = {}
	local otherNumeric = 0
	for _, other in items do
		if other.frame ~= item.frame or other == item then
			continue
		end
		if other.field.type == "string" then
			local v = other.field.values[row]
			local text = FieldConfig.display(other, if Frame.isNull(v) then "" else v, opts).text
			if text ~= "" then
				table.insert(parts, text)
			end
		elseif other.field.type == "number" then
			otherNumeric += 1
		end
	end
	if otherNumeric > 0 or #parts == 0 then
		table.insert(parts, item.name)
	end
	return table.concat(parts, " ")
end

function M.values(panel: any, items: { Item }, env: Env, opts: Options?): { Value }
	local o: Options = opts or {}
	local reduceOptions = Json.obj(env, Json.path(env, panel, "options", "reduceOptions"))
	local calcs = M.calcsOf(panel, env)
	local allRows = Json.bool(env, reduceOptions.values) == true
	local limit = Json.num(env, reduceOptions.limit)
	if limit == nil or limit <= 0 then
		limit = M.DEFAULT_LIMIT
	end
	local pattern = Json.str(env, reduceOptions.fields) or ""
	local match: (Item) -> boolean
	if pattern ~= "" then
		local m = FieldConfig.matcherFor(env, { id = "byRegexp", options = pattern })
		match = function(item: Item): boolean
			return m ~= nil and m(item.field, item.frame, {})
		end
	else
		match = function(item: Item): boolean
			return item.field.type == "number"
		end
	end
	local disp = { theme = o.theme, offset_min = o.offset_min }
	local out: { Value } = {}
	for _, item in items do
		if #out >= (limit :: number) then
			break
		end
		if not match(item) or FieldConfig.hidden(item) then
			continue
		end
		local values = item.field.values
		if allRows then
			for j = 1, #values do
				local d = FieldConfig.display(item, values[j], disp)
				table.insert(out, { title = rowName(item, items, j, disp), display = d, item = item, row = j })
				if #out >= (limit :: number) then
					break
				end
			end
		else
			local results = Reduce.calcs(values, calcs, item.field.type, item.config.null_mode)
			local timeField = Frame.timeField(item.frame)
			for _, calc in calcs do
				local d = FieldConfig.display(item, results[calc], disp)
				local spark: Spark? = nil
				if o.sparkline and timeField then
					spark = { values = values, times = timeField.values, highlight = highlightOf(values, calc) }
				end
				table.insert(out, { title = item.name, display = d, item = item, calc = calc, spark = spark })
			end
		end
	end
	if #out == 0 then
		local base = FieldConfig.defaults(panel, env)
		local placeholder: Item = {
			frame = { fields = {} },
			field = Frame.field("", "other", {}),
			frame_index = 0,
			field_index = 0,
			name = "No data",
			config = base,
			series_index = 1,
			range_min = base.min or 0,
			range_max = base.max or 0,
		}
		local d = FieldConfig.display(placeholder, nil, disp)
		if d.text == "" then
			d.text = "No data"
		end
		table.insert(out, { title = "No data", display = d })
	end
	return out
end

return M
