--!strict
-- LogQL text edits for the Logs block: where the stream selector is, the
-- matchers in it, adding or removing a label filter (a chip click), the
-- volume query, and what to suggest at the caret.
--
-- A filter on an indexed label goes into the stream selector (Loki then reads
-- fewer streams); one on structured metadata or a parsed field becomes a
-- label filter stage `| name="value"` at the end of the pipeline, which is
-- where those labels exist. Clicking the same chip again removes the filter;
-- the opposite chip flips it. Strings are written double-quoted with Go
-- escapes, as LogQL reads them.

local M = {}

export type Op = "=" | "!=" | "=~" | "!~"

export type Matcher = {
	name: string,
	op: Op,
	value: string,
	-- 1-based byte span of the whole matcher in the expression.
	from: number,
	to: number,
}

export type Ctx =
	{ kind: "none" }
	| { kind: "label", prefix: string, from: number, to: number }
	| { kind: "value", label: string, prefix: string, from: number, to: number }
	| { kind: "pipe", prefix: string, from: number, to: number }

export type Item = { label: string, insert: string, detail: string? }

M.PIPE_KEYWORDS = table.freeze({
	{ "json", "parse JSON lines into labels" },
	{ "logfmt", "parse logfmt lines into labels" },
	{ "pattern", 'parse with a pattern, `pattern "<_> <status>"`' },
	{ "regexp", "parse with named regexp groups" },
	{ "unpack", "unpack Promtail packed lines" },
	{ "line_format", "rewrite the line from a template" },
	{ "label_format", "rename or template labels" },
	{ "drop", "drop labels" },
	{ "keep", "keep only these labels" },
	{ "decolorize", "strip ANSI colors" },
})

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or ""
end

-- A log query starts with its stream selector; anything else (a range
-- aggregation, a vector function) is a metric query.
function M.isMetric(expr: string): boolean
	local t = trim(expr)
	return t ~= "" and string.sub(t, 1, 1) ~= "{"
end

-- The double-quoted LogQL string of `value`.
function M.quote(value: string): string
	local escaped = string.gsub(value, '[\\"]', "\\%0")
	escaped = string.gsub(escaped, "\n", "\\n")
	escaped = string.gsub(escaped, "\t", "\\t")
	return '"' .. escaped .. '"'
end

-- End (1-based, inclusive) of the string starting at `i` (a `"` or a
-- backtick), or nil when it is not closed.
local function stringEnd(expr: string, i: number): number?
	local q = string.sub(expr, i, i)
	local j = i + 1
	while j <= #expr do
		local c = string.sub(expr, j, j)
		if q == '"' and c == "\\" then
			j += 2
		elseif c == q then
			return j
		else
			j += 1
		end
	end
	return nil
end

local function unquote(s: string): string
	if string.sub(s, 1, 1) == "`" then
		return string.sub(s, 2, -2)
	end
	local inner = string.sub(s, 2, -2)
	local out = string.gsub(inner, "\\(.)", function(c: string): string
		if c == "n" then
			return "\n"
		elseif c == "t" then
			return "\t"
		end
		return c
	end)
	return out
end

-- 1-based positions of the first stream selector's `{` and `}`.
function M.selector(expr: string): (number?, number?)
	local i = 1
	local open: number? = nil
	while i <= #expr do
		local c = string.sub(expr, i, i)
		if c == '"' or c == "`" then
			local e = stringEnd(expr, i)
			if e == nil then
				return open, nil
			end
			i = e + 1
		elseif c == "{" and open == nil then
			open = i
			i += 1
		elseif c == "}" and open ~= nil then
			return open, i
		else
			i += 1
		end
	end
	return open, nil
end

-- The first selector's matchers, in order.
function M.matchers(expr: string): { Matcher }
	local out: { Matcher } = {}
	local open, close = M.selector(expr)
	if open == nil or close == nil then
		return out
	end
	local i = open + 1
	while i < close do
		local a, b, name, op = string.find(expr, "^%s*,?%s*([%a_][%w_]*)%s*([=!][=~]?)%s*", i)
		if a == nil or b == nil or (op ~= "=" and op ~= "!=" and op ~= "=~" and op ~= "!~") then
			break
		end
		local q = b + 1
		local e = stringEnd(expr, q)
		if e == nil or e > close or (string.sub(expr, q, q) ~= '"' and string.sub(expr, q, q) ~= "`") then
			break
		end
		local start = (string.find(expr, "[%a_]", a)) :: number
		table.insert(out, {
			name = name :: string,
			op = op :: Op,
			value = unquote(string.sub(expr, q, e)),
			from = start,
			to = e,
		})
		i = e + 1
	end
	return out
end

local function find(expr: string, name: string, op: Op, value: string): Matcher?
	for _, m in M.matchers(expr) do
		if m.name == name and m.op == op and m.value == value then
			return m
		end
	end
	return nil
end

function M.hasSelector(expr: string, name: string, op: Op, value: string): boolean
	return find(expr, name, op, value) ~= nil
end

local function opposite(op: Op): Op
	return if op == "=" then "!=" elseif op == "!=" then "=" elseif op == "=~" then "!~" else "=~"
end

local function removeMatcher(expr: string, m: Matcher): string
	local before = string.sub(expr, 1, m.from - 1)
	local after = string.sub(expr, m.to + 1)
	-- Drop one separating comma: the one before, else the one after.
	local trimmedBefore = string.gsub(before, "%s*,%s*$", "")
	if trimmedBefore ~= before then
		return trimmedBefore .. after
	end
	return before .. (string.gsub(after, "^%s*,%s*", ""))
end

-- (new expression, nil) or (unchanged expression, why not).
function M.toggleSelector(expr: string, name: string, op: Op, value: string): (string, string?)
	local open, close = M.selector(expr)
	if open == nil or close == nil then
		return expr, "the query has no stream selector"
	end
	local same = find(expr, name, op, value)
	if same then
		if #M.matchers(expr) == 1 then
			return expr, "a stream selector needs at least one matcher"
		end
		return removeMatcher(expr, same), nil
	end
	local text = name .. op .. M.quote(value)
	local other = find(expr, name, opposite(op), value)
	if other then
		return string.sub(expr, 1, other.from - 1) .. text .. string.sub(expr, other.to + 1), nil
	end
	local inner = trim(string.sub(expr, open + 1, close - 1))
	local sep = if inner == "" then "" else ", "
	local head = string.gsub(string.sub(expr, 1, close - 1), "%s*$", "")
	return head .. sep .. text .. string.sub(expr, close), nil
end

local function escapePattern(s: string): string
	return (string.gsub(s, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

local function stagePattern(name: string, op: Op, value: string): string
	return "%s*|%s*" .. escapePattern(name) .. "%s*" .. escapePattern(op) .. "%s*" .. escapePattern(M.quote(value))
end

local function findStage(expr: string, name: string, op: Op, value: string): (number?, number?)
	local _, close = M.selector(expr)
	if close == nil then
		return nil, nil
	end
	local pattern = stagePattern(name, op, value)
	local init = close + 1
	while true do
		local a, b = string.find(expr, pattern, init)
		if a == nil or b == nil then
			return nil, nil
		end
		-- A stage ends at the end of the query or before the next stage.
		local rest = string.sub(expr, b + 1)
		if string.match(rest, "^%s*$") or string.match(rest, "^%s*|") then
			return a, b
		end
		init = b + 1
	end
end

function M.hasStage(expr: string, name: string, op: Op, value: string): boolean
	return (findStage(expr, name, op, value)) ~= nil
end

function M.toggleStage(expr: string, name: string, op: Op, value: string): (string, string?)
	local _, close = M.selector(expr)
	if close == nil then
		return expr, "the query has no stream selector"
	end
	local a, b = findStage(expr, name, op, value)
	if a and b then
		return string.sub(expr, 1, a - 1) .. string.sub(expr, b + 1), nil
	end
	local stage = " | " .. name .. " " .. op .. " " .. M.quote(value)
	local oa, ob = findStage(expr, name, opposite(op), value)
	if oa and ob then
		return string.sub(expr, 1, oa - 1) .. stage .. string.sub(expr, ob + 1), nil
	end
	return (string.gsub(expr, "%s*$", "")) .. stage, nil
end

-- A chip click: include (`=`) or exclude (`!=`) `name = value`, in the
-- selector for an indexed label, as a label filter stage otherwise.
function M.filter(expr: string, name: string, value: string, exclude: boolean, indexed: boolean): (string, string?)
	if M.isMetric(expr) then
		return expr, "filters apply to log queries"
	end
	local op: Op = if exclude then "!=" else "="
	if indexed then
		return M.toggleSelector(expr, name, op, value)
	end
	return M.toggleStage(expr, name, op, value)
end

-- Whether the filter a chip would toggle is on.
function M.active(expr: string, name: string, value: string, exclude: boolean): boolean
	local op: Op = if exclude then "!=" else "="
	return M.hasSelector(expr, name, op, value) or M.hasStage(expr, name, op, value)
end

-- Log volume by level over `interval` buckets (a duration like "1m").
function M.volume(expr: string, label: string, interval: string): string
	return string.format("sum by (%s) (count_over_time(%s [%s]))", label, trim(expr), interval)
end

-- Suggestions -------------------------------------------------------------------

local function scan(prefix: string): (number?, boolean, number?)
	-- (open brace of the selector the caret is in, in a string, string start)
	local i = 1
	local open: number? = nil
	while i <= #prefix do
		local c = string.sub(prefix, i, i)
		if c == '"' or c == "`" then
			local e = stringEnd(prefix, i)
			if e == nil then
				return open, true, i
			end
			i = e + 1
		elseif c == "{" then
			open = i
			i += 1
		elseif c == "}" then
			open = nil
			i += 1
		else
			i += 1
		end
	end
	return open, false, nil
end

-- What the caret (0-based byte offset) is completing. `from`/`to` are the
-- 1-based span an accepted item replaces.
function M.context(expr: string, cursor: number): Ctx
	local before = string.sub(expr, 1, cursor)
	local open, inString, stringAt = scan(before)
	if open then
		if inString and stringAt then
			local name = string.match(string.sub(before, 1, stringAt - 1), "([%a_][%w_]*)%s*[=!][=~]?%s*$")
			if name == nil then
				return { kind = "none" }
			end
			local to = cursor
			if string.sub(expr, cursor + 1, cursor + 1) == string.sub(expr, stringAt, stringAt) then
				to = cursor + 1
			end
			return {
				kind = "value",
				label = name,
				prefix = string.sub(before, stringAt + 1),
				from = stringAt,
				to = to,
			}
		end
		local name = string.match(before, "([%a_][%w_]*)%s*[=!][=~]?%s*$")
		if name then
			return { kind = "value", label = name, prefix = "", from = cursor + 1, to = cursor }
		end
		local word = string.match(before, "[{,]%s*([%a_][%w_]*)$") or string.match(before, "[{,]%s*()$") and ""
		if word ~= nil then
			return { kind = "label", prefix = word, from = cursor - #word + 1, to = cursor }
		end
		return { kind = "none" }
	end
	if inString then
		return { kind = "none" }
	end
	local _, close = M.selector(before)
	if close == nil then
		return { kind = "none" }
	end
	local word = string.match(before, "|%s*([%a_]*)$")
	if
		word ~= nil
		and string.sub(before, -#word - 2, -#word - 1) ~= "|="
		and string.match(before, "|[=~]%s*$") == nil
	then
		return { kind = "pipe", prefix = word, from = cursor - #word + 1, to = cursor }
	end
	return { kind = "none" }
end

-- Items for a context from the fetched lists; at most `max`, prefix matches
-- first, then substring matches.
function M.items(ctx: Ctx, list: { string }?, max: number): { Item }
	local out: { Item } = {}
	if ctx.kind == "none" then
		return out
	end
	local prefix = string.lower((ctx :: any).prefix)
	local function consider(candidates: { { string } }, make: (string, string?) -> Item)
		local later: { Item } = {}
		for _, c in candidates do
			local lower = string.lower(c[1])
			if prefix == "" or string.sub(lower, 1, #prefix) == prefix then
				if #out < max then
					table.insert(out, make(c[1], c[2]))
				end
			elseif string.find(lower, prefix, 1, true) and #later < max then
				table.insert(later, make(c[1], c[2]))
			end
		end
		for _, item in later do
			if #out >= max then
				break
			end
			table.insert(out, item)
		end
	end
	if ctx.kind == "pipe" then
		consider(M.PIPE_KEYWORDS :: any, function(word: string, detail: string?): Item
			return { label = word, insert = word .. " ", detail = detail }
		end)
		return out
	end
	local candidates: { { string } } = {}
	local values: { string } = list or {}
	for _, v in values do
		table.insert(candidates, { v })
	end
	if ctx.kind == "label" then
		consider(candidates, function(name: string): Item
			return { label = name, insert = name .. "=" }
		end)
	else
		consider(candidates, function(value: string): Item
			return { label = value, insert = M.quote(value) }
		end)
	end
	return out
end

-- The expression and caret after accepting `item` in `ctx`.
function M.apply(expr: string, ctx: Ctx, item: Item): (string, number)
	if ctx.kind == "none" then
		return expr, #expr
	end
	local c = ctx :: any
	local head = string.sub(expr, 1, c.from - 1)
	local text = head .. item.insert .. string.sub(expr, c.to + 1)
	return text, #head + #item.insert
end

return M
