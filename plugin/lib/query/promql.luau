--!strict
-- What the user is typing at the caret of a PromQL expression, so the Query
-- block can suggest the right thing: metric names and functions at an
-- expression position, label names inside `{}` and grouping clauses, label
-- values inside a matcher's quotes, durations inside `[]`.
--
-- A forgiving scanner over the text before the caret (the expression is
-- usually incomplete): it tracks open brackets, the matcher being written
-- inside braces, and strings, and never fails.

local M = {}

export type Kind = "none" | "expr" | "label_name" | "label_value" | "grouping" | "duration"

export type Context = {
	kind: Kind,
	-- The partial token before the caret (raw text; inside quotes it is the
	-- string body typed so far).
	prefix: string,
	-- 0-based byte offset where the prefix starts: accepting a suggestion
	-- replaces `from` .. caret.
	from: number,
	-- label_name / label_value: the metric written before the braces.
	metric: string?,
	-- label_value: the matcher's label and operator.
	label: string?,
	op: string?,
	-- label_value: the opening quote, nil when the value is not quoted yet.
	quote: string?,
	-- label_name / grouping: labels already written in this matcher list.
	used: { string },
}

M.FUNCTIONS = table.freeze({
	"abs",
	"absent",
	"absent_over_time",
	"acos",
	"acosh",
	"asin",
	"asinh",
	"atan",
	"atanh",
	"avg_over_time",
	"ceil",
	"changes",
	"clamp",
	"clamp_max",
	"clamp_min",
	"cos",
	"cosh",
	"count_over_time",
	"day_of_month",
	"day_of_week",
	"day_of_year",
	"days_in_month",
	"deg",
	"delta",
	"deriv",
	"double_exponential_smoothing",
	"exp",
	"floor",
	"histogram_avg",
	"histogram_count",
	"histogram_fraction",
	"histogram_quantile",
	"histogram_stddev",
	"histogram_stdvar",
	"histogram_sum",
	"holt_winters",
	"hour",
	"idelta",
	"increase",
	"irate",
	"label_join",
	"label_replace",
	"last_over_time",
	"ln",
	"log10",
	"log2",
	"mad_over_time",
	"max_over_time",
	"min_over_time",
	"minute",
	"month",
	"pi",
	"predict_linear",
	"present_over_time",
	"quantile_over_time",
	"rad",
	"rate",
	"resets",
	"round",
	"scalar",
	"sgn",
	"sin",
	"sinh",
	"sort",
	"sort_by_label",
	"sort_by_label_desc",
	"sort_desc",
	"sqrt",
	"stddev_over_time",
	"stdvar_over_time",
	"sum_over_time",
	"tan",
	"tanh",
	"time",
	"timestamp",
	"vector",
	"year",
})

M.AGGREGATIONS = table.freeze({
	"avg",
	"bottomk",
	"count",
	"count_values",
	"group",
	"limit_ratio",
	"limitk",
	"max",
	"min",
	"quantile",
	"stddev",
	"stdvar",
	"sum",
	"topk",
})

M.KEYWORDS = table.freeze({
	"and",
	"atan2",
	"bool",
	"by",
	"group_left",
	"group_right",
	"ignoring",
	"offset",
	"on",
	"or",
	"unless",
	"without",
})

-- Range selector and subquery durations; the Grafana macros come first.
M.DURATIONS = table.freeze({
	"$__rate_interval",
	"$__interval",
	"$__range",
	"1m",
	"5m",
	"10m",
	"15m",
	"30m",
	"1h",
	"6h",
	"1d",
})

-- Keywords whose parenthesis holds a label list.
local GROUPING: { [string]: boolean } = {
	by = true,
	without = true,
	on = true,
	ignoring = true,
	group_left = true,
	group_right = true,
}

local NOT_METRIC: { [string]: boolean } = {}
for _, list in { M.FUNCTIONS, M.AGGREGATIONS, M.KEYWORDS } do
	for _, w in list do
		NOT_METRIC[w] = true
	end
end

type Open = {
	kind: "paren" | "brace" | "bracket",
	grouping: boolean,
	metric: string?,
	-- Braces: which part of a matcher comes next.
	phase: "name" | "op" | "value" | "sep",
	label: string?,
	op: string?,
	used: { string },
}

local function none(at: number): Context
	return { kind = "none", prefix = "", from = at, used = {} }
end

local function open(kind: "paren" | "brace" | "bracket", grouping: boolean, metric: string?): Open
	return { kind = kind, grouping = grouping, metric = metric, phase = "name", used = {} }
end

-- The context for a token `prefix` starting at byte `start` (1-based) with
-- the brackets `stack` open around it.
local function decide(stack: { Open }, prefix: string, start: number): Context
	local top = stack[#stack]
	local from = start - 1
	if top and top.kind == "brace" then
		if top.phase == "name" then
			return {
				kind = "label_name",
				prefix = prefix,
				from = from,
				metric = top.metric,
				used = top.used,
			}
		elseif top.phase == "value" and prefix == "" then
			return {
				kind = "label_value",
				prefix = "",
				from = from,
				metric = top.metric,
				label = top.label,
				op = top.op,
				used = top.used,
			}
		end
		return none(from)
	elseif top and top.kind == "paren" and top.grouping then
		return { kind = "grouping", prefix = prefix, from = from, used = top.used }
	elseif top and top.kind == "bracket" then
		return { kind = "duration", prefix = prefix, from = from, used = {} }
	end
	return { kind = "expr", prefix = prefix, from = from, used = {} }
end

-- The context at byte offset `cursor` (0-based, as the input's caret).
function M.context(text: string, cursor: number): Context
	local s = string.sub(text, 1, math.clamp(cursor, 0, #text))
	local n = #s
	local stack: { Open } = {}
	-- The last significant token: "ident", "number", "string", "close", "op".
	local prev = "op"
	local lastIdent: string? = nil
	local i = 1
	while i <= n do
		local c = string.sub(s, i, i)
		if string.match(c, "%s") then
			i += 1
		elseif c == "#" then
			local nl = string.find(s, "\n", i, true)
			if nl == nil then
				return none(n)
			end
			i = nl + 1
		elseif c == '"' or c == "'" or c == "`" then
			local j = i + 1
			local closed = false
			while j <= n do
				local d = string.sub(s, j, j)
				if d == "\\" and c ~= "`" then
					j += 2
				elseif d == c then
					closed = true
					break
				else
					j += 1
				end
			end
			local top = stack[#stack]
			local isValue = top ~= nil and top.kind == "brace" and top.phase == "value"
			if not closed then
				if isValue and top then
					return {
						kind = "label_value",
						prefix = string.sub(s, i + 1),
						from = i,
						metric = top.metric,
						label = top.label,
						op = top.op,
						quote = c,
						used = top.used,
					}
				end
				return none(n)
			end
			if isValue and top then
				top.phase = "sep"
			end
			prev = "string"
			i = j + 1
		elseif c == ":" and stack[#stack] ~= nil and stack[#stack].kind == "bracket" then
			-- Subquery `[range:step]`.
			prev = "op"
			i += 1
		elseif string.match(c, "[%a_:]") then
			local word = string.match(s, "^[%a_:][%w_:]*", i) :: string
			local last = i + #word - 1
			if last == n then
				return decide(stack, word, i)
			end
			local top = stack[#stack]
			if top and top.kind == "brace" and top.phase == "name" then
				top.label = word
				top.phase = "op"
				table.insert(top.used, word)
			elseif top and top.kind == "paren" and top.grouping then
				table.insert(top.used, word)
			end
			lastIdent = word
			prev = "ident"
			i = last + 1
		elseif string.match(c, "[%d%.]") then
			local num = string.match(s, "^[%w%.]+", i) :: string
			local last = i + #num - 1
			if last == n then
				local top = stack[#stack]
				if top and top.kind == "bracket" then
					return { kind = "duration", prefix = num, from = i - 1, used = {} }
				end
				return none(n)
			end
			prev = "number"
			i = last + 1
		elseif c == "$" then
			local var = string.match(s, "^%$[%w_]*", i) :: string
			if string.sub(s, i, i + 1) == "${" then
				var = string.match(s, "^%${[^}]*}?", i) :: string
			end
			local last = i + #var - 1
			if last == n then
				local top = stack[#stack]
				if top and top.kind == "bracket" then
					return { kind = "duration", prefix = var, from = i - 1, used = {} }
				end
				return none(n)
			end
			prev = "number"
			i = last + 1
		elseif c == "{" then
			local metric = if prev == "ident" and lastIdent and not NOT_METRIC[lastIdent] then lastIdent else nil
			table.insert(stack, open("brace", false, metric))
			prev = "op"
			i += 1
		elseif c == "(" then
			local grouping = prev == "ident" and lastIdent ~= nil and GROUPING[lastIdent] == true
			table.insert(stack, open("paren", grouping, nil))
			prev = "op"
			i += 1
		elseif c == "[" then
			table.insert(stack, open("bracket", false, nil))
			prev = "op"
			i += 1
		elseif c == "}" or c == ")" or c == "]" then
			if #stack > 0 then
				table.remove(stack)
			end
			prev = "close"
			i += 1
		elseif c == "," then
			local top = stack[#stack]
			if top and top.kind == "brace" then
				top.phase = "name"
				top.label = nil
				top.op = nil
			end
			prev = "op"
			i += 1
		else
			local top = stack[#stack]
			if top and top.kind == "brace" and top.phase == "op" then
				local op = string.match(s, "^[=!]~", i) or string.match(s, "^!=", i) or string.match(s, "^=", i)
				if op then
					top.op = op
					top.phase = "value"
					i += #op
					prev = "op"
					continue
				end
			end
			prev = "op"
			i += 1
		end
	end
	return decide(stack, "", n + 1)
end

return M
