--!strict
-- Which signals an impact watch compares. Configured signals (impact.signals)
-- win: their placeholders are filled from the command and its directory, and
-- a signal whose placeholder cannot be filled is skipped with the reason.
-- Otherwise RED queries are guessed from the metric names the server has
-- (a `*_requests_total` counter with a status-code label, a matching
-- `*_request_duration_seconds_bucket` histogram) and badged "guessed".

local Settings = require("./settings")

type SignalSpec = Settings.SignalSpec

export type Vars = { namespace: string?, service: string?, cwd_basename: string? }

export type Signal = {
	name: string,
	expr: string,
	unit: string?,
	bad: Settings.Bad,
	guessed: boolean,
}

export type Skipped = { name: string, reason: string }

-- The probe result a guess is built from.
export type Probe = {
	counter: string?,
	-- The counter's status-code label, when it has one.
	status_label: string?,
	-- Label names of the counter (scoping by namespace/service).
	labels: { string },
	histogram: string?,
}

local M = {}

M.STATUS_LABELS = table.freeze({ "code", "status", "status_code", "http_status", "response_code" })
-- How many counters the guess probes for labels.
M.MAX_PROBES = 3

-- PromQL double-quoted string content.
local function escapeValue(v: string): string
	return (string.gsub(string.gsub(v, "\\", "\\\\"), '"', '\\"'))
end

-- `expr` with every placeholder filled, or nil and the missing name.
function M.fill(expr: string, vars: Vars): (string?, string?)
	local missing: string? = nil
	local out = string.gsub(expr, "{{%s*([^}]-)%s*}}", function(name: string): string
		local v = (vars :: any)[name]
		if type(v) ~= "string" or v == "" then
			missing = missing or name
			return ""
		end
		return escapeValue(v)
	end)
	if missing then
		return nil, missing
	end
	return out, nil
end

local REASON: { [string]: string } = {
	namespace = "needs {{namespace}}: the command named no namespace (-n/--namespace)",
	service = "needs {{service}}: no release, app or resource name was found in the command",
	cwd_basename = "needs {{cwd_basename}}: the command's directory is unknown",
}

function M.configured(specs: { SignalSpec }, vars: Vars): ({ Signal }, { Skipped })
	local out: { Signal } = {}
	local skipped: { Skipped } = {}
	for _, spec in specs do
		local expr, missing = M.fill(spec.expr, vars)
		if expr then
			table.insert(out, { name = spec.name, expr = expr, unit = spec.unit, bad = spec.bad, guessed = false })
		else
			table.insert(skipped, { name = spec.name, reason = REASON[missing :: string] or "unfilled placeholder" })
		end
	end
	return out, skipped
end

-- Guessing --------------------------------------------------------------------------

local function counterRank(name: string): number?
	if name == "http_requests_total" then
		return 0
	elseif string.match(name, "http_requests_total$") then
		return 1
	elseif string.match(name, "http.*_requests_total$") then
		return 2
	elseif string.match(name, "_requests_total$") then
		return 3
	end
	return nil
end

-- Request counters among `names`, most HTTP-like first.
function M.counters(names: { string }): { string }
	local list: { { name: string, rank: number } } = {}
	for _, n in names do
		local r = counterRank(n)
		if r then
			table.insert(list, { name = n, rank = r })
		end
	end
	table.sort(list, function(a, b)
		if a.rank ~= b.rank then
			return a.rank < b.rank
		end
		return a.name < b.name
	end)
	local out: { string } = {}
	for _, c in list do
		table.insert(out, c.name)
	end
	return out
end

-- The latency histogram that goes with `counter` (same prefix), else the
-- most HTTP-like `*_request_duration_seconds_bucket`.
function M.histogram(names: { string }, counter: string?): string?
	local set: { [string]: boolean } = {}
	for _, n in names do
		set[n] = true
	end
	if counter then
		local prefix = string.match(counter, "^(.-)_?requests_total$")
		if prefix then
			local sep = if prefix == "" then "" else "_"
			for _, cand in
				{ prefix .. sep .. "request_duration_seconds_bucket", prefix .. sep .. "duration_seconds_bucket" }
			do
				if set[cand] then
					return cand
				end
			end
		end
	end
	if set["http_request_duration_seconds_bucket"] then
		return "http_request_duration_seconds_bucket"
	end
	local best: string? = nil
	for _, n in names do
		if string.match(n, "http.*_request_duration_seconds_bucket$") and (best == nil or n < best) then
			best = n
		end
	end
	return best
end

function M.statusLabel(labels: { string }): string?
	for _, l in M.STATUS_LABELS do
		if table.find(labels, l) then
			return l
		end
	end
	return nil
end

-- The selector scoping a guessed query to the command's namespace/service,
-- using only labels the counter really has.
function M.selector(labels: { string }, vars: Vars): string
	local parts: { string } = {}
	if vars.namespace and table.find(labels, "namespace") then
		table.insert(parts, string.format('namespace="%s"', escapeValue(vars.namespace :: string)))
	end
	if vars.service then
		for _, l in { "service", "app", "app_kubernetes_io_name" } do
			if table.find(labels, l) then
				table.insert(parts, string.format('%s="%s"', l, escapeValue(vars.service :: string)))
				break
			end
		end
	end
	return table.concat(parts, ",")
end

local function sel(selector: string, extra: string?): string
	local parts: { string } = {}
	if selector ~= "" then
		table.insert(parts, selector)
	end
	if extra then
		table.insert(parts, extra)
	end
	return if #parts == 0 then "" else "{" .. table.concat(parts, ",") .. "}"
end

-- Requests, error ratio and p95 latency from a probe; `rate` is the rate
-- window ("1m").
function M.guess(probe: Probe, vars: Vars, rate: string): { Signal }
	local out: { Signal } = {}
	local selector = M.selector(probe.labels, vars)
	local counter = probe.counter
	if counter then
		local all = string.format("sum(rate(%s%s[%s]))", counter, sel(selector), rate)
		table.insert(out, { name = "requests", expr = all, unit = "reqps", bad = "down", guessed = true })
		if probe.status_label then
			local errors = string.format(
				"sum(rate(%s%s[%s])) / %s",
				counter,
				sel(selector, string.format('%s=~"5.."', probe.status_label :: string)),
				rate,
				all
			)
			table.insert(out, { name = "error ratio", expr = errors, unit = "percentunit", bad = "up", guessed = true })
		end
	end
	if probe.histogram then
		local p95 = string.format(
			"histogram_quantile(0.95, sum by (le) (rate(%s%s[%s])))",
			probe.histogram :: string,
			sel(selector),
			rate
		)
		table.insert(out, { name = "p95 latency", expr = p95, unit = "s", bad = "up", guessed = true })
	end
	return out
end

return M
