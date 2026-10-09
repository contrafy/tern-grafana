--!strict
-- Silence matchers: built from an alert's labels, parsed from and printed as
-- Alertmanager's `name="value"` syntax, validated the way Alertmanager
-- validates a new silence, and matched against alerts with Alertmanager's
-- semantics (regexes anchored on both ends, a missing label is "").

local Group = require("../alerts/group")
local Normalize = require("../alerts/normalize")
local Regex = require("../regex")
local Sources = require("../alerts/sources")

type Alert = Normalize.Alert

export type Op = "=" | "!=" | "=~" | "!~"
export type Matcher = { name: string, op: Op, value: string }
-- Alertmanager v2's wire shape.
export type ApiMatcher = { name: string, value: string, isRegex: boolean, isEqual: boolean }

local M = {}

-- Bounds the matchers of one silence (the form, the link and the preview).
M.MAX_MATCHERS = 32

-- Equality matchers on an alert's labels, as Grafana and Alertmanager do
-- when silencing from an alert (internal labels dropped, the Grafana rule
-- uid kept).
function M.fromLabels(alert: Alert): { Matcher }
	local out: { Matcher } = {}
	for _, pair in Sources.silenceMatchers(alert) do
		table.insert(out, { name = pair[1], op = "=", value = pair[2] })
	end
	return out
end

local function quote(s: string): string
	local escaped = string.gsub(s, '[\\"\n]', function(c: string): string
		return if c == "\n" then "\\n" else "\\" .. c
	end)
	return '"' .. escaped .. '"'
end

function M.format(m: Matcher): string
	return m.name .. m.op .. quote(m.value)
end

-- `{a="b", c=~"d.*"}`: what the alerts filter, amtool and Alertmanager's UI
-- accept.
function M.formatList(list: { Matcher }): string
	local parts: { string } = {}
	for _, m in list do
		table.insert(parts, M.format(m))
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

-- Matchers from text (`a="b" c!~d`, braces and commas optional); free words
-- are an error.
function M.parseList(text: string): ({ Matcher }?, string?)
	local filter, err = Group.parseFilter(text)
	if filter == nil then
		return nil, err
	end
	if #filter.words > 0 then
		return nil,
			string.format(
				"not a matcher: %s (write name=value, name!=value, name=~regex or name!~regex)",
				filter.words[1]
			)
	end
	if #filter.matchers > M.MAX_MATCHERS then
		return nil, string.format("at most %d matchers", M.MAX_MATCHERS)
	end
	local out: { Matcher } = {}
	for _, m in filter.matchers do
		table.insert(out, { name = m.name, op = m.op :: Op, value = m.value })
	end
	return out, nil
end

-- Exactly one matcher.
function M.parse(text: string): (Matcher?, string?)
	local list, err = M.parseList(text)
	if list == nil then
		return nil, err
	end
	if #list ~= 1 then
		return nil, "enter one matcher: name=value, name!=value, name=~regex or name!~regex"
	end
	return list[1], nil
end

export type Compiled = { Group.Matcher }

function M.compile(list: { Matcher }): (Compiled?, string?)
	local out: Compiled = {}
	for _, m in list do
		local gm: Group.Matcher = { name = m.name, op = m.op, value = m.value }
		if m.op == "=~" or m.op == "!~" then
			local re, err = Regex.compile(m.value)
			if re == nil then
				return nil, string.format("bad regex in %s: %s", M.format(m), tostring(err))
			end
			gm.re = re
		end
		table.insert(out, gm)
	end
	return out, nil
end

-- What Alertmanager refuses at creation, said before the request: no
-- matchers, a bad label name or regex, or matchers that all match the
-- empty string (such a silence would match every alert).
function M.validate(list: { Matcher }): string?
	if #list == 0 then
		return "add at least one matcher"
	end
	if #list > M.MAX_MATCHERS then
		return string.format("at most %d matchers", M.MAX_MATCHERS)
	end
	for _, m in list do
		if string.match(m.name, "^[%a_][%w_]*$") == nil then
			return string.format("%q is not a valid label name", m.name)
		end
	end
	local compiled, err = M.compile(list)
	if compiled == nil then
		return err
	end
	for _, gm in compiled do
		if not Group.matches(gm, {}) then
			return nil
		end
	end
	return "at least one matcher must not match the empty string (this silence would match every alert)"
end

-- All matchers match the labels.
function M.matches(compiled: Compiled, labels: { [string]: string }): boolean
	for _, gm in compiled do
		if not Group.matches(gm, labels) then
			return false
		end
	end
	return true
end

-- The alerts a silence with these matchers would cover; nil and the reason
-- when the matchers are invalid.
function M.affected(list: { Matcher }, alerts: { Alert }): ({ Alert }?, string?)
	local compiled, err = M.compile(list)
	if compiled == nil then
		return nil, err
	end
	local out: { Alert } = {}
	for _, a in alerts do
		if M.matches(compiled, a.labels) then
			table.insert(out, a)
		end
	end
	return Group.sort(out), nil
end

function M.toApi(m: Matcher): ApiMatcher
	return {
		name = m.name,
		value = m.value,
		isRegex = m.op == "=~" or m.op == "!~",
		isEqual = m.op == "=" or m.op == "=~",
	}
end

-- A matcher from Alertmanager's JSON; isEqual defaults to true (servers
-- before 0.22 omit it).
function M.fromApi(raw: any): Matcher?
	if type(raw) ~= "table" or type(raw.name) ~= "string" or type(raw.value) ~= "string" then
		return nil
	end
	local regex = raw.isRegex == true
	local equal = raw.isEqual ~= false
	local op: Op = if regex then (if equal then "=~" else "!~") else (if equal then "=" else "!=")
	return { name = raw.name, op = op, value = raw.value }
end

return M
