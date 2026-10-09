--!strict
-- Suggestions for the Query block's PromQL input: what data a context needs
-- (metric names, label names, label values, metadata), the ranked items
-- from that data, and the edit accepting an item makes.

local Promql = require("./promql")

type Context = Promql.Context

export type ItemKind = "metric" | "function" | "aggregation" | "keyword" | "label" | "value" | "duration"

export type Item = {
	label: string,
	kind: ItemKind,
	detail: string?,
}

export type Meta = { type: string?, help: string?, unit: string? }

-- One cached list a context needs. `key` identifies it in the block's
-- per-context cache.
export type Need = {
	key: string,
	kind: "values" | "labels" | "metadata",
	label: string?,
	-- Series selector limiting the answer (a metric name).
	match: string?,
}

export type Data = {
	-- By Need.key.
	lists: { [string]: { string } },
	metadata: { [string]: Meta }?,
}

local M = {}

M.MAX_ITEMS = 50
M.DETAIL_MAX = 80

function M.valuesKey(label: string, match: string?): string
	return "values|" .. label .. "|" .. (match or "")
end

function M.labelsKey(match: string?): string
	return "labels|" .. (match or "")
end

M.METADATA_KEY = "metadata"

local function metricNames(): Need
	return { key = M.valuesKey("__name__", nil), kind = "values", label = "__name__" }
end

function M.needs(ctx: Context): { Need }
	local k = ctx.kind
	if k == "expr" then
		return { metricNames(), { key = M.METADATA_KEY, kind = "metadata" } }
	elseif k == "label_name" then
		return { { key = M.labelsKey(ctx.metric), kind = "labels", match = ctx.metric } }
	elseif k == "grouping" then
		return { { key = M.labelsKey(nil), kind = "labels" } }
	elseif k == "label_value" then
		local label = ctx.label or ""
		if label == "__name__" then
			return { metricNames() }
		end
		return { { key = M.valuesKey(label, ctx.metric), kind = "values", label = label, match = ctx.metric } }
	end
	return {}
end

local function clip(s: string): string
	s = string.gsub(s, "%s+", " ")
	if #s > M.DETAIL_MAX then
		return string.sub(s, 1, M.DETAIL_MAX - 3) .. "..."
	end
	return s
end

type Candidate = { label: string, kind: ItemKind }

-- Prefix matches first, then other substring matches, case-insensitive,
-- each group in candidate order. The text being replaced itself is left out
-- (accepting it changes nothing).
local function rank(cands: { Candidate }, prefix: string, keepExact: { [ItemKind]: boolean }): { Candidate }
	local needle = string.lower(prefix)
	local front: { Candidate }, back: { Candidate } = {}, {}
	for _, c in cands do
		if c.label == prefix and not keepExact[c.kind] then
			continue
		end
		if needle == "" then
			table.insert(front, c)
		else
			local at = string.find(string.lower(c.label), needle, 1, true)
			if at == 1 then
				table.insert(front, c)
			elseif at then
				table.insert(back, c)
			end
		end
		if #front >= M.MAX_ITEMS then
			break
		end
	end
	for _, c in back do
		if #front >= M.MAX_ITEMS then
			break
		end
		table.insert(front, c)
	end
	return front
end

local function add(cands: { Candidate }, list: { string }?, kind: ItemKind, skip: { [string]: boolean }?)
	if list then
		for _, v in list do
			if not (skip and skip[v]) then
				table.insert(cands, { label = v, kind = kind })
			end
		end
	end
end

local function set(list: { string }): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for _, v in list do
		out[v] = true
	end
	return out
end

local KEEP_CALLS: { [ItemKind]: boolean } = { ["function"] = true, aggregation = true }

function M.items(ctx: Context, data: Data): { Item }
	local cands: { Candidate } = {}
	local keep: { [ItemKind]: boolean } = {}
	local prefix = ctx.prefix
	local k = ctx.kind
	if k == "expr" then
		keep = KEEP_CALLS
		add(cands, Promql.AGGREGATIONS, "aggregation")
		add(cands, Promql.FUNCTIONS, "function")
		add(cands, Promql.KEYWORDS, "keyword")
		add(cands, data.lists[M.valuesKey("__name__", nil)], "metric")
	elseif k == "label_name" then
		local skip = set(ctx.used)
		skip.__name__ = ctx.metric ~= nil
		add(cands, data.lists[M.labelsKey(ctx.metric)], "label", skip)
	elseif k == "grouping" then
		local skip = set(ctx.used)
		skip.__name__ = true
		add(cands, data.lists[M.labelsKey(nil)], "label", skip)
	elseif k == "label_value" then
		local label = ctx.label or ""
		local key = if label == "__name__" then M.valuesKey("__name__", nil) else M.valuesKey(label, ctx.metric)
		add(cands, data.lists[key], "value")
	elseif k == "duration" then
		add(cands, Promql.DURATIONS, "duration")
	end
	local ranked = rank(cands, prefix, keep)
	local items: { Item } = table.create(#ranked)
	local metadata = data.metadata
	for i, c in ranked do
		local detail: string? = nil
		if c.kind == "metric" and metadata then
			local m = metadata[c.label]
			if m then
				local parts: { string } = {}
				if m.type and m.type ~= "" then
					table.insert(parts, m.type)
				end
				if m.help and m.help ~= "" then
					table.insert(parts, m.help)
				end
				detail = if #parts > 0 then clip(table.concat(parts, "  ")) else nil
			end
		elseif c.kind ~= "metric" and c.kind ~= "label" and c.kind ~= "value" then
			detail = c.kind
		end
		items[i] = { label = c.label, kind = c.kind, detail = detail }
	end
	return items
end

-- RE2 metacharacters, escaped for `=~` / `!~` so a picked value matches
-- itself literally.
local function regexEscape(v: string): string
	return (string.gsub(v, "[\\%.%+%*%?%(%)|%[%]{}%^%$]", "\\%0"))
end

-- Escapes for a PromQL string in `quote` (Go string syntax; backticks are raw).
local function quoteEscape(v: string, quote: string): string
	if quote == "`" then
		return v
	end
	v = string.gsub(v, "\\", "\\\\")
	return (string.gsub(v, quote, "\\" .. quote))
end

-- The text and caret (0-based byte offset) after accepting `item` at
-- `cursor` in context `ctx`.
function M.apply(text: string, cursor: number, ctx: Context, item: Item): (string, number)
	local before = string.sub(text, 1, ctx.from)
	local after = string.sub(text, cursor + 1)
	local k = ctx.kind
	if k == "label_value" then
		local value = item.label
		if ctx.op == "=~" or ctx.op == "!~" then
			value = regexEscape(value)
		end
		local quote = ctx.quote
		if quote == nil then
			local insert = '"' .. quoteEscape(value, '"') .. '"'
			return before .. insert .. after, #before + #insert
		end
		local insert = quoteEscape(value, quote)
		-- Replace the rest of the string body too, keeping its closing quote.
		local close = string.find(after, quote, 1, true)
		if close then
			after = string.sub(after, close + 1)
		end
		local out = before .. insert .. quote
		return out .. after, #out
	end
	-- Names replace the whole word under the caret.
	if k ~= "duration" then
		after = string.gsub(after, "^[%w_:]+", "")
	end
	local insert = item.label
	if item.kind == "function" or item.kind == "aggregation" then
		if string.sub(after, 1, 1) == "(" then
			return before .. insert .. after, #before + #insert + 1
		end
		insert ..= "("
	elseif k == "label_name" and not string.match(after, "^%s*[=!]") then
		local out = before .. insert .. '=""'
		return out .. after, #out - 1
	end
	return before .. insert .. after, #before + #insert
end

return M
