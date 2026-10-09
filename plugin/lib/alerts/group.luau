--!strict
-- Inbox ordering: filter (free text plus Alertmanager label matchers), sort
-- (what needs attention first) and group (by configured labels, like an
-- Alertmanager route's group_by).

local Normalize = require("./normalize")
local Regex = require("../regex")

type Alert = Normalize.Alert
type State = Normalize.State
type Severity = Normalize.Severity

export type MatchOp = "=" | "!=" | "=~" | "!~"
export type Matcher = { name: string, op: MatchOp, value: string, re: any? }
export type Filter = { matchers: { Matcher }, words: { string } }

export type Group = {
	-- Stable within one grouping: the group_by label values joined.
	key: string,
	labels: { { name: string, value: string } },
	alerts: { Alert },
	worst: Severity,
	counts: { [State]: number },
}

local M = {}

-- Firing and pending need attention; muted and resolved alerts sink below
-- them whatever their severity.
local STATE_BUCKET: { [State]: number } = {
	firing = 2,
	pending = 2,
	inhibited = 1,
	silenced = 1,
	resolved = 0,
}

local STATE_RANK: { [State]: number } = {
	firing = 5,
	pending = 4,
	inhibited = 3,
	silenced = 2,
	resolved = 1,
}

local function unquote(v: string): string?
	local q = string.sub(v, 1, 1)
	if q == '"' or q == "'" then
		if #v < 2 or string.sub(v, -1) ~= q then
			return nil
		end
		local inner = string.sub(v, 2, -2)
		-- Alertmanager matcher values use Go string escapes.
		return (
			string.gsub(inner, "\\(.)", function(c: string): string
				if c == "n" then
					return "\n"
				elseif c == "t" then
					return "\t"
				end
				return c
			end)
		)
	end
	return v
end

-- Splits on spaces and commas outside quotes; `{` and `}` around an
-- Alertmanager-style matcher list are dropped.
local function tokens(text: string): ({ string }?, string?)
	local out: { string } = {}
	local cur = ""
	local quote: string? = nil
	local i = 1
	while i <= #text do
		local c = string.sub(text, i, i)
		if quote then
			cur ..= c
			if c == "\\" and i < #text then
				i += 1
				cur ..= string.sub(text, i, i)
			elseif c == quote then
				quote = nil
			end
		elseif c == '"' or c == "'" then
			quote = c
			cur ..= c
		elseif c == " " or c == "\t" or c == "," or c == "{" or c == "}" then
			if cur ~= "" then
				table.insert(out, cur)
				cur = ""
			end
		else
			cur ..= c
		end
		i += 1
	end
	if quote then
		return nil, "unterminated quote"
	end
	if cur ~= "" then
		table.insert(out, cur)
	end
	return out, nil
end

-- `a=b`, `a!=b`, `a=~re`, `a!~re` (values optionally quoted) and free words.
-- Regex matchers are anchored on both ends like Alertmanager's.
function M.parseFilter(text: string): (Filter?, string?)
	local list, err = tokens(text)
	if list == nil then
		return nil, err
	end
	local filter: Filter = { matchers = {}, words = {} }
	for _, tok in list do
		local name, op, rest = string.match(tok, "^([%a_][%w_]*)(!~)(.*)$")
		if not name then
			name, op, rest = string.match(tok, "^([%a_][%w_]*)(=~)(.*)$")
		end
		if not name then
			name, op, rest = string.match(tok, "^([%a_][%w_]*)(!=)(.*)$")
		end
		if not name then
			name, op, rest = string.match(tok, "^([%a_][%w_]*)(=)(.*)$")
		end
		if name and op and rest then
			local value = unquote(rest)
			if value == nil then
				return nil, string.format("bad value in %s", tok)
			end
			local m: Matcher = { name = name, op = op :: MatchOp, value = value }
			if op == "=~" or op == "!~" then
				local re, reErr = Regex.compile(value)
				if re == nil then
					return nil, string.format("bad regex in %s: %s", tok, tostring(reErr))
				end
				m.re = re
			end
			table.insert(filter.matchers, m)
		else
			table.insert(filter.words, string.lower(tok))
		end
	end
	return filter, nil
end

-- A missing label matches as the empty string, as in Alertmanager.
function M.matches(m: Matcher, labels: { [string]: string }): boolean
	local v = labels[m.name] or ""
	if m.op == "=" then
		return v == m.value
	elseif m.op == "!=" then
		return v ~= m.value
	end
	local ok = Regex.fullMatch(m.re :: any, v)
	if m.op == "=~" then
		return ok
	end
	return not ok
end

local function hasWord(a: Alert, word: string): boolean
	local function has(s: string?): boolean
		return s ~= nil and string.find(string.lower(s), word, 1, true) ~= nil
	end
	if has(a.summary) or has(a.description) or has(a.state) or has(a.severity) then
		return true
	end
	for name, value in a.labels do
		if has(value) or has(name) then
			return true
		end
	end
	return false
end

function M.accept(filter: Filter, a: Alert): boolean
	for _, m in filter.matchers do
		if not M.matches(m, a.labels) then
			return false
		end
	end
	for _, w in filter.words do
		if not hasWord(a, w) then
			return false
		end
	end
	return true
end

function M.apply(filter: Filter, alerts: { Alert }): { Alert }
	local out: { Alert } = {}
	for _, a in alerts do
		if M.accept(filter, a) then
			table.insert(out, a)
		end
	end
	return out
end

-- True when `a` should come before `b`: attention bucket, severity, state,
-- newest first, then fingerprint for a stable order between polls.
function M.before(a: Alert, b: Alert): boolean
	local ba, bb = STATE_BUCKET[a.state], STATE_BUCKET[b.state]
	if ba ~= bb then
		return ba > bb
	end
	local sa, sb = Normalize.SEVERITY_RANK[a.severity], Normalize.SEVERITY_RANK[b.severity]
	if sa ~= sb then
		return sa > sb
	end
	local ra, rb = STATE_RANK[a.state], STATE_RANK[b.state]
	if ra ~= rb then
		return ra > rb
	end
	if a.starts_at_ms ~= b.starts_at_ms then
		return a.starts_at_ms > b.starts_at_ms
	end
	return a.fingerprint < b.fingerprint
end

function M.sort(alerts: { Alert }): { Alert }
	local out = table.clone(alerts)
	table.sort(out, M.before)
	return out
end

-- Groups sorted alerts; a group takes the place of its most urgent alert.
-- group_by {"..."} puts every alert in a group of its own.
function M.group(alerts: { Alert }, group_by: { string }): { Group }
	local sorted = M.sort(alerts)
	local all = table.find(group_by, "...") ~= nil
	local groups: { Group } = {}
	local byKey: { [string]: Group } = {}
	for _, a in sorted do
		local key: string
		local labels: { { name: string, value: string } } = {}
		if all then
			key = a.context .. "\0" .. a.fingerprint
			for _, name in group_by do
				if name ~= "..." and a.labels[name] then
					table.insert(labels, { name = name, value = a.labels[name] })
				end
			end
			if #labels == 0 and a.labels.alertname then
				table.insert(labels, { name = "alertname", value = a.labels.alertname })
			end
		else
			local parts: { string } = {}
			for _, name in group_by do
				local v = a.labels[name] or ""
				table.insert(parts, v)
				if v ~= "" then
					table.insert(labels, { name = name, value = v })
				end
			end
			key = table.concat(parts, "\0")
		end
		local g = byKey[key]
		if g == nil then
			g = { key = key, labels = labels, alerts = {}, worst = "none", counts = {} }
			byKey[key] = g
			table.insert(groups, g)
		end
		local grp = g :: Group
		table.insert(grp.alerts, a)
		grp.counts[a.state] = (grp.counts[a.state] or 0) + 1
		if STATE_BUCKET[a.state] == 2 and Normalize.SEVERITY_RANK[a.severity] > Normalize.SEVERITY_RANK[grp.worst] then
			grp.worst = a.severity
		end
	end
	return groups
end

return M
