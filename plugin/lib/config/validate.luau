--!strict
-- Parses and validates the user's config file. Any problem rejects the whole
-- file: a half-applied config could send a token to the wrong server. Every
-- problem names its JSON path and says how to fix it; none echoes a value that
-- could be a secret.

local Types = require("./types")

type Config = Types.Config
type Context = Types.Context
type Endpoint = Types.Endpoint
type Auth = Types.Auth
type SecretSource = Types.SecretSource
type Tls = Types.Tls
type Datasources = Types.Datasources
type Problem = Types.Problem

local M = {}

M.VERSION = 1
M.DEFAULT_TIMEOUT_MS = 15000
M.MAX_TIMEOUT_MS = 600000
M.RELATIVE_PATH = "tern-grafana/config.json"

local ENDPOINTS = { "grafana", "prometheus", "alertmanager", "loki", "tempo" }
local FEATURE_SECTIONS = { "query", "dashboard", "alerts", "annotations", "impact", "watches", "hosts" }
local TOP_FIELDS = { "version", "default_context", "contexts" }
local ENDPOINT_FIELDS = { "url", "auth", "headers", "path_prefix", "tls", "timeout_ms" }
local GRAFANA_FIELDS = { "org_id", "datasources", "browser_url" }
local DATASOURCE_KEYS = { "prometheus", "loki", "tempo", "alertmanager" }
local TLS_FIELDS = { "ca_file", "cert_file", "key_file", "insecure" }
local LITERAL_SECRETS = { token = "token", password = "password" }

type Problems = { Problem }

local function add(problems: Problems, path: string, message: string)
	table.insert(problems, { path = path, message = message })
end

local function join(path: string, key: string): string
	return if path == "" then key else path .. "." .. key
end

local function set(list: { string }): { [string]: boolean }
	local out = {}
	for _, v in list do
		out[v] = true
	end
	return out
end

local function sortedKeys(t: { [any]: any }): { string }
	local keys: { string } = {}
	for k in t do
		if type(k) == "string" then
			table.insert(keys, k)
		end
	end
	table.sort(keys)
	return keys
end

local function sortedList(list: { string }): string
	local copy = table.clone(list)
	table.sort(copy)
	return table.concat(copy, ", ")
end

local function isObject(v: any): boolean
	if type(v) ~= "table" then
		return false
	end
	return next(v) == nil or #v == 0
end

local function isNonEmptyArray(v: any): boolean
	if type(v) ~= "table" or #v == 0 then
		return false
	end
	local n = 0
	for _ in v do
		n += 1
	end
	return n == #v
end

local function isInteger(v: any): boolean
	return type(v) == "number" and v == math.floor(v) and v == v
end

local function unknownField(problems: Problems, path: string, allowed: { string })
	add(problems, path, "unknown field; expected one of " .. sortedList(allowed))
end

local function checkPath(problems: Problems, path: string, v: any): string?
	if type(v) == "string" and (string.sub(v, 1, 1) == "/" or string.sub(v, 1, 2) == "~/") then
		return v
	end
	add(problems, path, "must be an absolute path or start with ~/")
	return nil
end

-- Returns the URL without trailing slashes. Never echoes a URL holding userinfo.
local function checkUrl(problems: Problems, path: string, v: any): string?
	if type(v) ~= "string" then
		add(problems, path, "must be an http(s) URL")
		return nil
	end
	local scheme, rest = string.match(v, "^(%a[%w+.-]*)://(.*)$")
	local authority = if rest then string.match(rest, "^[^/?#]*") else nil
	if authority and string.find(authority, "@", 1, true) then
		add(problems, path, 'must not contain credentials; configure auth (type "basic" or "bearer") instead')
		return nil
	end
	local lower = if scheme then string.lower(scheme) else nil
	if (lower ~= "http" and lower ~= "https") or authority == nil or authority == "" or string.find(v, "%s") then
		add(problems, path, string.format("must be an http(s) URL, got %q", v))
		return nil
	end
	if string.find(v, "[?#]") then
		add(problems, path, "must not contain a query or fragment")
		return nil
	end
	return (string.gsub(v, "/+$", ""))
end

local SOURCE_KINDS: { { suffix: string, from: "cmd" | "env" | "file" } } = {
	{ suffix = "_cmd", from = "cmd" },
	{ suffix = "_env", from = "env" },
	{ suffix = "_file", from = "file" },
}

local function sourceFields(base: string): { string }
	return { base .. "_cmd", base .. "_env", base .. "_file" }
end

local function checkSource(problems: Problems, path: string, base: string, raw: { [string]: any }): SecretSource?
	local found: { SecretSource } = {}
	local present = 0
	for _, kind in SOURCE_KINDS do
		local field = base .. kind.suffix
		local v = raw[field]
		if v == nil then
			continue
		end
		present += 1
		local p = join(path, field)
		if kind.from == "cmd" then
			local ok = isNonEmptyArray(v)
			if ok then
				for _, arg in v do
					if type(arg) ~= "string" or arg == "" then
						ok = false
						break
					end
				end
			end
			if ok then
				table.insert(found, { from = "cmd", field = field, argv = table.clone(v) })
			else
				add(
					problems,
					p,
					'must be a non-empty array of strings, for example ["op", "read", "op://vault/item/token"]'
				)
			end
		elseif kind.from == "env" then
			if type(v) == "string" and string.match(v, "^[%a_][%w_]*$") then
				table.insert(found, { from = "env", field = field, name = v })
			else
				add(problems, p, "must be an environment variable name such as GRAFANA_TOKEN")
			end
		else
			local file = checkPath(problems, p, v)
			if file then
				table.insert(found, { from = "file", field = field, path = file })
			end
		end
	end
	local names = table.concat(sourceFields(base), ", ")
	if present > 1 then
		add(problems, path, "set only one of " .. names)
		return nil
	end
	return found[1]
end

local AUTH_FIELDS: { [string]: { string } } = {
	none = { "type" },
	bearer = { "type", "token_cmd", "token_env", "token_file" },
	basic = { "type", "username", "password_cmd", "password_env", "password_file" },
}

local function checkAuth(problems: Problems, path: string, raw: any): Auth?
	if not isObject(raw) then
		add(problems, path, 'must be an object such as {"type": "bearer", "token_env": "GRAFANA_TOKEN"}')
		return nil
	end
	local kind = raw.type
	local allowed = if type(kind) == "string" then AUTH_FIELDS[kind] else nil
	if not allowed then
		add(problems, join(path, "type"), 'must be one of "none", "bearer", "basic"')
		return nil
	end
	local before = #problems
	local allowedSet = set(allowed)
	for _, key in sortedKeys(raw) do
		local literal = LITERAL_SECRETS[key]
		if literal then
			add(
				problems,
				join(path, key),
				string.format(
					"secrets cannot be written in the config file; use %s_cmd, %s_env or %s_file",
					literal,
					literal,
					literal
				)
			)
		elseif not allowedSet[key] then
			add(
				problems,
				join(path, key),
				string.format("not used by auth type %q; expected one of %s", kind, sortedList(allowed))
			)
		end
	end
	if kind == "none" then
		return if #problems == before then { type = "none" } else nil
	end
	local base = if kind == "bearer" then "token" else "password"
	local username: string? = nil
	if kind == "basic" then
		local u = raw.username
		if type(u) ~= "string" or u == "" then
			add(problems, join(path, "username"), "is required for basic auth")
		elseif string.find(u, ":", 1, true) then
			add(problems, join(path, "username"), "must not contain ':'")
		else
			username = u
		end
	end
	local present = false
	for _, field in sourceFields(base) do
		if raw[field] ~= nil then
			present = true
		end
	end
	local source = checkSource(problems, path, base, raw)
	if not present then
		add(problems, path, string.format("%s auth needs one of %s", kind, table.concat(sourceFields(base), ", ")))
	end
	if #problems ~= before or not source then
		return nil
	end
	if kind == "bearer" then
		return { type = "bearer", token = source }
	end
	return { type = "basic", username = username :: string, password = source }
end

local function checkHeaders(problems: Problems, path: string, raw: any): { [string]: string }?
	if not isObject(raw) then
		add(problems, path, "must be an object of header names to string values")
		return nil
	end
	local out: { [string]: string } = {}
	local ok = true
	for _, name in sortedKeys(raw) do
		local v = raw[name]
		local p = join(path, name)
		if not string.match(name, "^[!#$%%&'*+%-.^_`|~%w]+$") then
			add(problems, p, "not a valid HTTP header name")
			ok = false
		elseif string.lower(name) == "authorization" then
			add(problems, p, "set credentials with auth, not a literal header")
			ok = false
		elseif type(v) ~= "string" then
			add(problems, p, "must be a string")
			ok = false
		elseif string.find(v, "[\r\n]") then
			add(problems, p, "must not contain line breaks")
			ok = false
		else
			out[name] = v
		end
	end
	return if ok then out else nil
end

local function checkTls(problems: Problems, path: string, raw: any): (Tls?, boolean)
	if not isObject(raw) then
		add(problems, path, "must be an object with ca_file, cert_file, key_file or insecure")
		return nil, false
	end
	local before = #problems
	local tls: Tls = { insecure = false }
	local allowed = set(TLS_FIELDS)
	for _, key in sortedKeys(raw) do
		local v = raw[key]
		local p = join(path, key)
		if not allowed[key] then
			unknownField(problems, p, TLS_FIELDS)
		elseif key == "insecure" then
			if type(v) == "boolean" then
				tls.insecure = v
			else
				add(problems, p, "must be true or false")
			end
		elseif key == "ca_file" then
			tls.ca_file = checkPath(problems, p, v)
		elseif key == "cert_file" then
			tls.cert_file = checkPath(problems, p, v)
		else
			tls.key_file = checkPath(problems, p, v)
		end
	end
	if raw.key_file ~= nil and raw.cert_file == nil then
		add(problems, join(path, "key_file"), "needs tls.cert_file")
	end
	if #problems ~= before then
		return nil, false
	end
	if tls.ca_file == nil and tls.cert_file == nil and tls.key_file == nil and not tls.insecure then
		return nil, true
	end
	return tls, true
end

local function checkDatasources(problems: Problems, path: string, raw: any): Datasources?
	if not isObject(raw) then
		add(problems, path, 'must be an object such as {"prometheus": "<datasource uid>"}')
		return nil
	end
	local before = #problems
	local out: { [string]: string } = {}
	local allowed = set(DATASOURCE_KEYS)
	for _, key in sortedKeys(raw) do
		local v = raw[key]
		if not allowed[key] then
			unknownField(problems, join(path, key), DATASOURCE_KEYS)
		elseif type(v) ~= "string" or v == "" then
			add(problems, join(path, key), "must be a non-empty datasource uid")
		else
			out[key] = v
		end
	end
	if #problems ~= before then
		return nil
	end
	return out :: any
end

local function normalizePrefix(problems: Problems, path: string, v: any): string?
	if type(v) ~= "string" or string.find(v, "[?#%s]") then
		add(problems, path, "must be a URL path without '?' or '#'")
		return nil
	end
	local trimmed = string.gsub(string.gsub(v, "^/+", ""), "/+$", "")
	return if trimmed == "" then "" else "/" .. trimmed
end

local function checkEndpoint(problems: Problems, path: string, name: string, raw: any): Endpoint?
	if not isObject(raw) then
		add(problems, path, "must be an object with a url")
		return nil
	end
	local before = #problems
	local isGrafana = name == "grafana"
	local allowedList = table.clone(ENDPOINT_FIELDS)
	if isGrafana then
		table.move(GRAFANA_FIELDS, 1, #GRAFANA_FIELDS, #allowedList + 1, allowedList)
	end
	local allowed = set(allowedList)

	local url: string? = nil
	local auth: Auth? = { type = "none" }
	local headers: { [string]: string }? = {}
	local prefix: string? = ""
	local tls: Tls? = nil
	local timeout = M.DEFAULT_TIMEOUT_MS
	local orgId: number? = nil
	local datasources: Datasources? = nil
	local browserUrl: string? = nil

	for _, key in sortedKeys(raw) do
		local v = raw[key]
		local p = join(path, key)
		local literal = LITERAL_SECRETS[key]
		if literal then
			add(
				problems,
				p,
				string.format(
					"secrets cannot be written in the config file; set auth with %s_cmd, %s_env or %s_file",
					literal,
					literal,
					literal
				)
			)
		elseif not allowed[key] then
			unknownField(problems, p, allowedList)
		elseif key == "url" then
			url = checkUrl(problems, p, v)
		elseif key == "auth" then
			auth = checkAuth(problems, p, v)
		elseif key == "headers" then
			headers = checkHeaders(problems, p, v)
		elseif key == "path_prefix" then
			prefix = normalizePrefix(problems, p, v)
		elseif key == "tls" then
			tls = checkTls(problems, p, v)
		elseif key == "timeout_ms" then
			if isInteger(v) and v >= 1 and v <= M.MAX_TIMEOUT_MS then
				timeout = v
			else
				add(problems, p, string.format("must be an integer between 1 and %d (milliseconds)", M.MAX_TIMEOUT_MS))
			end
		elseif key == "org_id" then
			if isInteger(v) and v >= 1 then
				orgId = v
			else
				add(problems, p, "must be a positive integer")
			end
		elseif key == "datasources" then
			datasources = checkDatasources(problems, p, v)
		elseif key == "browser_url" then
			browserUrl = checkUrl(problems, p, v)
		end
	end
	if raw.url == nil then
		add(problems, join(path, "url"), "is required")
	end
	if #problems ~= before then
		return nil
	end
	return {
		url = url :: string,
		auth = auth :: Auth,
		headers = headers :: { [string]: string },
		path_prefix = prefix :: string,
		tls = tls,
		timeout_ms = timeout,
		org_id = orgId,
		datasources = if isGrafana then datasources or {} else nil,
		browser_url = browserUrl,
	}
end

local function checkContext(problems: Problems, path: string, name: string, raw: any): Context?
	if not string.match(name, "^[%w_.%-]+$") then
		add(problems, path, "context names may only contain letters, digits, '.', '_' and '-'")
		return nil
	end
	if not isObject(raw) then
		add(problems, path, "must be an object with endpoints such as grafana or prometheus")
		return nil
	end
	local before = #problems
	local allowed = set(ENDPOINTS)
	local ctx: { [string]: any } = { name = name }
	local count = 0
	for _, key in sortedKeys(raw) do
		local p = join(path, key)
		if not allowed[key] then
			unknownField(problems, p, ENDPOINTS)
		else
			count += 1
			ctx[key] = checkEndpoint(problems, p, key, raw[key])
		end
	end
	if count == 0 then
		add(problems, path, "must configure at least one of " .. table.concat(ENDPOINTS, ", "))
	end
	if #problems ~= before then
		return nil
	end
	return ctx :: any
end

-- `raw` is the decoded file: JSON null object members are already dropped.
function M.validate(raw: any): (Config?, { Problem })
	local problems: Problems = {}
	if not isObject(raw) or raw == nil then
		add(problems, "", "the file must contain a JSON object")
		return nil, problems
	end

	local topAllowed = table.clone(TOP_FIELDS)
	table.move(FEATURE_SECTIONS, 1, #FEATURE_SECTIONS, #topAllowed + 1, topAllowed)
	local topSet = set(topAllowed)
	for _, key in sortedKeys(raw) do
		if not topSet[key] then
			unknownField(problems, key, topAllowed)
		end
	end

	local version = raw.version
	if version ~= nil and version ~= M.VERSION then
		if type(version) == "number" then
			add(
				problems,
				"version",
				string.format("unsupported version %s; this plugin reads version %d", tostring(version), M.VERSION)
			)
		else
			add(problems, "version", string.format("must be %d", M.VERSION))
		end
	end

	local contexts: { [string]: Context } = {}
	local names: { string } = {}
	local rawContexts = raw.contexts
	if rawContexts == nil then
		add(problems, "contexts", "is required: an object mapping context names to endpoints")
	elseif not isObject(rawContexts) then
		add(problems, "contexts", "must be an object mapping context names to endpoints")
	elseif next(rawContexts) == nil then
		add(problems, "contexts", "must define at least one context")
	else
		names = sortedKeys(rawContexts)
		for _, name in names do
			local ctx = checkContext(problems, join("contexts", name), name, rawContexts[name])
			if ctx then
				contexts[name] = ctx
			end
		end
	end

	local default = raw.default_context
	if default ~= nil then
		if type(default) ~= "string" then
			add(problems, "default_context", "must be a string naming a context")
		elseif #names > 0 and rawContexts[default] == nil then
			add(
				problems,
				"default_context",
				string.format("no context named %q (defined: %s)", default, table.concat(names, ", "))
			)
		end
	elseif #names == 1 then
		default = names[1]
	end

	if #problems > 0 then
		return nil, problems
	end
	return {
		version = M.VERSION,
		default_context = default,
		contexts = contexts,
		query = raw.query,
		dashboard = raw.dashboard,
		alerts = raw.alerts,
		annotations = raw.annotations,
		impact = raw.impact,
		watches = raw.watches,
		hosts = raw.hosts,
	},
		problems
end

function M.parseFile(text: string, decode: (string) -> any): (Config?, { Problem })
	local ok, raw = pcall(decode, text)
	if not ok then
		return nil, { { path = "", message = "invalid JSON: " .. tostring(raw) } }
	end
	return M.validate(raw)
end

function M.format(problem: Problem): string
	return (if problem.path == "" then "config" else problem.path) .. ": " .. problem.message
end

-- The config file location from the host's environment variables.
function M.path(vars: { XDG_CONFIG_HOME: string?, HOME: string? }): string?
	local xdg = vars.XDG_CONFIG_HOME
	if xdg and xdg ~= "" then
		return xdg .. "/" .. M.RELATIVE_PATH
	end
	local home = vars.HOME
	if home and home ~= "" then
		return home .. "/.config/" .. M.RELATIVE_PATH
	end
	return nil
end

return M
