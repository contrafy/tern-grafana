--!strict
-- `tern-grafana://<action>?<query>` links. They end up in block args, saved
-- state, terminal output and kv, so every parameter is validated against a
-- per-action allow list and credentials are refused outright: a link can name
-- what to show, never how to authenticate.

local Range = require("../time/range")

local M = {}

M.SCHEME = "tern-grafana"

export type Link = {
	action: string,
	-- Single-valued parameters (context, uid, expr, from, to, ...).
	params: { [string]: string },
	-- Dashboard variables (`var-<name>`), multi-valued in Grafana.
	vars: { [string]: { string } },
}

export type ErrorCode = "not_link" | "unknown_action" | "unknown_param" | "bad_param" | "missing_param" | "credential"

export type LinkError = { code: ErrorCode, message: string }

type Check = (string) -> boolean

local MAX_VALUE = 8192

local function context(v: string): boolean
	return #v <= 128 and string.match(v, "^[%w_.%-]+$") ~= nil
end

local function uid(v: string): boolean
	return #v <= 128 and string.match(v, "^[%w_%-]+$") ~= nil
end

local function digits(v: string): boolean
	return #v <= 12 and string.match(v, "^%d+$") ~= nil
end

local function timeValue(v: string): boolean
	if #v > 64 then
		return false
	end
	return (Range.parse(v, false, { now_ms = 0 })) ~= nil
end

-- Free text (PromQL, LogQL, matchers, comments): no control characters other
-- than tab and newline, bounded.
local function text(v: string): boolean
	return #v > 0 and #v <= MAX_VALUE and string.find(v, "[%z\1-\8\11-\31\127]") == nil
end

local function traceId(v: string): boolean
	return #v <= 32 and string.match(v, "^%x+$") ~= nil
end

local function opsView(v: string): boolean
	return v == "targets" or v == "rules" or v == "cardinality" or v == "info"
end

local function alertsView(v: string): boolean
	return v == "inbox" or v == "rules"
end

local function queryMode(v: string): boolean
	return v == "graph" or v == "table"
end

-- The authority of an http(s) URL with no userinfo, whitespace or controls.
local function httpUrl(v: string): boolean
	if #v > MAX_VALUE or string.find(v, "[%s%z\1-\31\127]") then
		return false
	end
	local scheme, rest = string.match(v, "^(%a[%w+.-]*)://(.*)$")
	if not scheme or not rest then
		return false
	end
	local lower = string.lower(scheme)
	if lower ~= "http" and lower ~= "https" then
		return false
	end
	local authority = string.match(rest, "^[^/?#]*") :: string
	return authority ~= "" and string.find(authority, "@", 1, true) == nil
end

type Spec = { params: { [string]: Check }, required: { string }, vars: boolean }

local TIME: { [string]: Check } = { from = timeValue, to = timeValue }

local function spec(required: { string }, vars: boolean, params: { [string]: Check }): Spec
	local all: { [string]: Check } = { context = context }
	for k, v in params do
		all[k] = v
	end
	return { params = all, required = required, vars = vars }
end

local function withTime(params: { [string]: Check }): { [string]: Check }
	for k, v in TIME do
		params[k] = v
	end
	return params
end

local ACTIONS: { [string]: Spec } = {
	query = spec({}, false, withTime({ expr = text, ds = uid, mode = queryMode })),
	dashboard = spec({ "uid" }, true, withTime({ uid = uid, panel = digits, org = digits })),
	panel = spec({ "uid", "panel" }, true, withTime({ uid = uid, panel = digits, org = digits })),
	alerts = spec({}, false, { rule = uid, filter = text, view = alertsView }),
	silence = spec({}, false, { id = uid, matchers = text }),
	logs = spec({}, false, withTime({ expr = text, ds = uid })),
	trace = spec({ "id" }, false, { id = traceId, ds = uid }),
	ops = spec({}, false, { view = opsView }),
	settings = spec({}, false, {}),
	browse = { params = { url = httpUrl }, required = { "url" }, vars = false },
}

M.ACTIONS = table.freeze((function()
	local names = {}
	for name in ACTIONS do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end)())

local CREDENTIAL_WORDS = { "token", "password", "passwd", "secret", "auth", "apikey", "api_key", "api-key", "cookie" }

local function isCredentialName(name: string): boolean
	local lower = string.lower(name)
	for _, word in CREDENTIAL_WORDS do
		if string.find(lower, word, 1, true) then
			return true
		end
	end
	return false
end

local function fail(code: ErrorCode, message: string): (nil, LinkError)
	return nil, { code = code, message = message }
end

-- RFC 3986 unreserved characters stay; everything else is %XX.
function M.percentEncode(s: string): string
	return (
		string.gsub(s, "[^%w%-%._~]", function(c: string): string
			return string.format("%%%02X", string.byte(c))
		end)
	)
end

-- Decodes %XX; `plus` also turns `+` into a space (form encoding, as used
-- by query strings). Returns nil on a malformed escape.
function M.percentDecode(s: string, plus: boolean): string?
	if string.find(s, "%%[^%x]") or string.find(s, "%%%x[^%x]") or string.find(s, "%%%x?$") then
		return nil
	end
	local out = if plus then string.gsub(s, "+", " ") else s
	return (
		string.gsub(out, "%%(%x%x)", function(h: string): string
			return string.char(tonumber(h, 16) :: number)
		end)
	)
end

-- Splits a query string into ordered (name, value) pairs; nil on a bad escape.
function M.parseQuery(query: string): { { name: string, value: string } }?
	local pairs_: { { name: string, value: string } } = {}
	for part in string.gmatch(query, "[^&]+") do
		local rawName, rawValue = string.match(part, "^([^=]*)=?(.*)$")
		local name = M.percentDecode(rawName or "", true)
		local value = M.percentDecode(rawValue or "", true)
		if name == nil or value == nil then
			return nil
		end
		table.insert(pairs_, { name = name, value = value })
	end
	return pairs_
end

local function checkVarName(name: string): boolean
	return #name <= 128 and string.match(name, "^[%w_]+$") ~= nil
end

-- Validates a link table (as built by callers or by `decode`).
function M.validate(link: Link): (Link?, LinkError?)
	local s = ACTIONS[link.action]
	if not s then
		return fail("unknown_action", string.format("unknown action %q", link.action))
	end
	for name, value in link.params do
		if isCredentialName(name) then
			return fail(
				"credential",
				string.format("parameter %q looks like a credential; links never carry one", name)
			)
		end
		local check = s.params[name]
		if not check then
			return fail("unknown_param", string.format("%s: unknown parameter %q", link.action, name))
		end
		if not check(value) then
			return fail("bad_param", string.format("%s: invalid %s", link.action, name))
		end
	end
	for _, name in s.required do
		if link.params[name] == nil then
			return fail("missing_param", string.format("%s: %s is required", link.action, name))
		end
	end
	for name, values in link.vars do
		if not s.vars then
			return fail("unknown_param", string.format("%s: unknown parameter %q", link.action, "var-" .. name))
		end
		if isCredentialName(name) then
			return fail("credential", string.format("variable %q looks like a credential; links never carry one", name))
		end
		if not checkVarName(name) then
			return fail("bad_param", string.format("%s: invalid variable name %q", link.action, name))
		end
		for _, v in values do
			if #v > MAX_VALUE or string.find(v, "[%z\1-\31\127]") then
				return fail("bad_param", string.format("%s: invalid value for variable %q", link.action, name))
			end
		end
	end
	return link, nil
end

function M.decode(url: string): (Link?, LinkError?)
	local prefix = M.SCHEME .. "://"
	if string.lower(string.sub(url, 1, #prefix)) ~= prefix then
		return fail("not_link", "not a " .. prefix .. " link")
	end
	local rest = string.sub(url, #prefix + 1)
	if string.find(rest, "#", 1, true) then
		return fail("bad_param", "links must not contain a fragment")
	end
	local action, query = string.match(rest, "^([^?/]*)/?%??(.*)$")
	if not action or not query then
		return fail("bad_param", "malformed link")
	end
	action = string.lower(action)
	if not ACTIONS[action] then
		return fail("unknown_action", string.format("unknown action %q", action))
	end
	local pairs_ = M.parseQuery(query)
	if not pairs_ then
		return fail("bad_param", "malformed percent-encoding")
	end
	local link: Link = { action = action, params = {}, vars = {} }
	for _, p in pairs_ do
		local varName = string.match(p.name, "^var%-(.+)$")
		if varName then
			local list = link.vars[varName]
			if not list then
				list = {}
				link.vars[varName] = list
			end
			table.insert(list, p.value)
		elseif link.params[p.name] ~= nil then
			return fail("bad_param", string.format("%s: duplicate parameter %q", action, p.name))
		else
			link.params[p.name] = p.value
		end
	end
	return M.validate(link)
end

local function sortedKeys<T>(t: { [string]: T }): { string }
	local keys = {}
	for k in t do
		table.insert(keys, k)
	end
	table.sort(keys)
	return keys
end

-- Canonical form: parameters sorted by name, variables after them, values
-- percent-encoded. Raises on an invalid link (a caller bug).
function M.encode(link: Link): string
	local ok, err = M.validate(link)
	if not ok then
		error("scheme.encode: " .. (err :: LinkError).message, 2)
	end
	local parts = {}
	for _, name in sortedKeys(link.params) do
		table.insert(parts, M.percentEncode(name) .. "=" .. M.percentEncode(link.params[name]))
	end
	for _, name in sortedKeys(link.vars) do
		for _, v in link.vars[name] do
			table.insert(parts, "var-" .. M.percentEncode(name) .. "=" .. M.percentEncode(v))
		end
	end
	local out = M.SCHEME .. "://" .. link.action
	if #parts > 0 then
		out ..= "?" .. table.concat(parts, "&")
	end
	return out
end

function M.isLink(url: string): boolean
	local prefix = M.SCHEME .. "://"
	return string.lower(string.sub(url, 1, #prefix)) == prefix
end

return M
