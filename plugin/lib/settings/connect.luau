--!strict
-- "Connect Grafana" (pure): a Grafana URL plus a service account token,
-- tested against the server before anything is stored, datasource uids
-- discovered from /api/frontend/settings, then the token goes to the OS
-- keychain (or the user names an environment variable) and the context is
-- written with a reference to it.
--
-- The token lives only in this state's memory: it travels in the test
-- requests' Authorization header and in the keychain store effect, and is
-- cleared once stored. Views show bullets; errors are redacted.

local Auth = require("../auth/auth")
local Env = require("../env")
local Grafana = require("../source/grafana")
local Keychain = require("../auth/keychain")
local Model = require("./model")
local Probe = require("./probe")
local Response = require("../source/response")
local Route = require("../config/route")
local Tbl = require("../tbl")
local TransportTypes = require("../transport/types")

type Env = Env.Env
type Raw = Model.Raw
type Route = Route.Route
type Request = TransportTypes.Request
type QueryError = TransportTypes.QueryError

local M = {}

export type Storage = "keychain" | "env"
export type Mode = "new" | "update"
export type Step = "user" | "frontend" | "actions"
export type Phase = "edit" | "testing" | "tested" | "storing" | "stored"

export type Candidate = { uid: string, name: string, type: string, is_default: boolean }

export type Result = {
	login: string,
	version: string?,
	-- nil when Grafana did not say (no access-control API).
	can_silence: boolean?,
	can_annotate: boolean?,
	candidates: { [string]: { Candidate } },
}

export type Failure = { message: string, hint: string? }

export type Conn = {
	mode: Mode,
	context: string,
	-- The context name still follows the URL (the user has not typed one).
	context_auto: boolean,
	url: string,
	token: string,
	storage: Storage,
	env_name: string,
	-- "macos" | "linux" | nil: where a keychain is available.
	platform: string?,
	-- Datasource uid per kind; "" is none.
	picks: { [string]: string },
	phase: Phase,
	gen: number,
	-- Answers received for the current test generation.
	answers: { [string]: boolean },
	result: Result?,
	failure: Failure?,
}

export type Field = {
	id: string,
	label: string,
	kind: "text" | "enum",
	values: { string }?,
	hint: string,
	secret: boolean?,
}

M.KINDS = table.freeze({ "prometheus", "loki", "tempo", "alertmanager" })
M.DEFAULT_ENV = "GRAFANA_TOKEN"
M.STEPS = table.freeze({ "user", "frontend", "actions" })
M.TIMEOUT_MS = 15000
M.GUIDE = "In Grafana: Administration > Users and access > Service accounts > Add service account "
	.. "(role Viewer to read; Editor for silences and annotations) > Add service account token. "
	.. "Copy the token (glsa_...) and paste it below."

local TYPE: { [string]: string } = {
	prometheus = "prometheus",
	loki = "loki",
	tempo = "tempo",
	alertmanager = "alertmanager",
}

-- Grafana Cloud provisions these per stack; they are not the stack's data.
local INTERNAL = { "usage", "ml%-metrics", "alert%-state%-history", "insights" }

-- Cloud uid suffix for the stack's own datasource of each kind.
local CLOUD_SUFFIX: { [string]: string } = { prometheus = "prom", loki = "logs", tempo = "traces" }

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") :: string
end

-- Helpers ------------------------------------------------------------------------------

function M.validEnvName(name: string): boolean
	return string.match(name, "^[A-Za-z_][A-Za-z0-9_]*$") ~= nil and #name <= 128
end

-- A Grafana base URL from what the user typed or pasted: a scheme is added
-- when missing, query, fragment and trailing slashes are dropped, and a
-- Grafana Cloud URL (*.grafana.net) loses any page path copied with it.
function M.normalizeUrl(text: string): (string?, string?)
	local t = trim(text)
	if t == "" then
		return nil, "enter the Grafana URL, e.g. https://you.grafana.net"
	end
	if string.find(t, "%s") then
		return nil, "a URL has no spaces"
	end
	if not string.find(t, "^%a[%w+.-]*://") then
		t = "https://" .. t
	end
	local schemeText, restText = string.match(t, "^(%a[%w+.-]*)://(.*)$")
	local scheme = string.lower(schemeText or "")
	if scheme ~= "http" and scheme ~= "https" then
		return nil, "the URL must start with http:// or https://"
	end
	local rest: string = (string.gsub(restText or "", "[?#].*$", ""))
	local host: string? = string.match(rest, "^([^/]*)")
	local path: string = string.sub(rest, #(host or "") + 1)
	if host == nil or host == "" then
		return nil, "the URL has no host"
	end
	if string.find(host, "@", 1, true) then
		return nil, "credentials do not belong in the URL"
	end
	local bare = string.lower((string.gsub(host, ":%d+$", "")))
	if string.find(bare, "%.grafana%.net$") then
		path = ""
	end
	path = (string.gsub(path, "/+$", ""))
	return scheme .. "://" .. host .. path, nil
end

-- A context name for a URL: the stack name of a Grafana Cloud URL, else the
-- host without its port.
function M.contextFromUrl(url: string): string
	local host = string.match(url, "^%a[%w+.-]*://([^/:]+)") or ""
	host = string.lower(host)
	local stack = string.match(host, "^([^.]+)%.grafana%.net$")
	local name = stack or host
	name = string.gsub(name, "[^%w._-]", "-")
	return name
end

function M.itemName(context: string): string
	return Keychain.itemName(context, "grafana")
end

-- Bullets for a secret: its length shows the paste arrived, never its text.
function M.bullets(token: string): string
	return string.rep("•", math.min(#token, 64))
end

function M.masked(token: string): string
	if token == "" then
		return ""
	end
	return M.bullets(token) .. string.format(" (%d characters)", #token)
end

-- Construction -----------------------------------------------------------------------------

local function blank(platform: string?): Conn
	return {
		mode = "new",
		context = "",
		context_auto = true,
		url = "",
		token = "",
		storage = if platform then "keychain" else "env",
		env_name = M.DEFAULT_ENV,
		platform = platform,
		picks = {},
		phase = "edit",
		gen = 0,
		answers = {},
		result = nil,
		failure = nil,
	}
end

function M.new(platform: string?): Conn
	return blank(platform)
end

-- Update token for an existing context's grafana endpoint: URL, storage and
-- datasource picks start from what the file holds.
function M.forUpdate(raw: Raw?, context: string, platform: string?): Conn?
	local ep = Model.rawEndpoint(raw, context, "grafana")
	if ep == nil then
		return nil
	end
	local c = blank(platform)
	c.mode = "update"
	c.context = context
	c.context_auto = false
	c.url = if type(ep.url) == "string" then ep.url else ""
	local auth = ep.auth
	if type(auth) == "table" and type(auth.token_env) == "string" then
		c.storage = "env"
		c.env_name = auth.token_env
	elseif type(auth) == "table" and type(auth.token_keychain) == "string" and platform then
		c.storage = "keychain"
	end
	if type(ep.datasources) == "table" then
		for _, kind in M.KINDS do
			local uid = ep.datasources[kind]
			if type(uid) == "string" then
				c.picks[kind] = uid
			end
		end
	end
	return c
end

-- Fields -----------------------------------------------------------------------------------

local function pickValues(c: Conn, kind: string): { string }
	local out: { string } = {}
	local result = c.result
	if result then
		local list: { Candidate } = result.candidates[kind] or {}
		for _, cand in list do
			table.insert(out, cand.uid)
		end
	end
	table.insert(out, "")
	return out
end

function M.fields(c: Conn): { Field }
	local out: { Field } = {
		{ id = "url", label = "Grafana URL", kind = "text", hint = "e.g. https://you.grafana.net" },
		{
			id = "token",
			label = "Token",
			kind = "text",
			secret = true,
			hint = "service account token (glsa_...): paste it; it is never shown",
		},
	}
	if c.mode == "new" then
		table.insert(out, {
			id = "context",
			label = "Context name",
			kind = "text",
			hint = "how this Grafana is called in Tern; letters, digits, '.', '_' and '-'",
		})
	end
	local storages: { string } = if c.platform then { "keychain", "env" } else { "env" }
	table.insert(out, {
		id = "storage",
		label = "Store token in",
		kind = "enum",
		values = storages,
		hint = if c.platform
			then "keychain: the OS keychain (recommended); env: an environment variable you set yourself"
			else "no keychain tool found (macOS security, Linux secret-tool): an environment variable you set",
	})
	if c.storage == "env" then
		table.insert(out, {
			id = "env_name",
			label = "Variable name",
			kind = "text",
			hint = "the variable that will hold the token, e.g. GRAFANA_TOKEN (GRAFANA_PROD_TOKEN for a second stack)",
		})
	end
	if c.result then
		for _, kind in M.KINDS do
			table.insert(out, {
				id = "ds." .. kind,
				label = kind .. " datasource",
				kind = "enum",
				values = pickValues(c, kind),
				hint = if kind == "alertmanager"
					then "none uses Grafana-managed alerting (the usual choice)"
					else "the Grafana datasource the plugin queries for " .. kind,
			})
		end
	end
	return out
end

function M.value(c: Conn, id: string): string
	if id == "url" then
		return c.url
	elseif id == "token" then
		return c.token
	elseif id == "context" then
		return c.context
	elseif id == "storage" then
		return c.storage
	elseif id == "env_name" then
		return c.env_name
	elseif string.sub(id, 1, 3) == "ds." then
		return c.picks[string.sub(id, 4)] or ""
	end
	return ""
end

-- What a field shows: never the token.
function M.display(c: Conn, f: Field): string
	if f.secret then
		return M.masked(c.token)
	end
	local v = M.value(c, f.id)
	if string.sub(f.id, 1, 3) == "ds." then
		if v == "" then
			return "none"
		end
		local list: { Candidate } = (if c.result then c.result.candidates[string.sub(f.id, 4)] else nil) or {}
		for _, cand in list do
			if cand.uid == v then
				return string.format("%s (uid %s)", cand.name, cand.uid)
			end
		end
	end
	return v
end

-- Whatever changes what a test proved discards the test.
local function untested(c: Conn)
	c.phase = "edit"
	c.gen += 1
	c.answers = {}
	c.result = nil
	c.failure = nil
end

-- A pasted or typed token: whitespace never belongs to one.
function M.cleanToken(text: string): string
	return (string.gsub(text, "%s+", ""))
end

function M.setField(prev: Conn, id: string, text: string): (Conn, string?)
	local c = Tbl.copy(prev)
	if id == "url" then
		local t = trim(text)
		if t == c.url then
			return prev, nil
		end
		c.url = t
		if c.context_auto and c.mode == "new" then
			local url = M.normalizeUrl(t)
			c.context = if url then M.contextFromUrl(url) else ""
		end
		untested(c)
	elseif id == "token" then
		local t = M.cleanToken(text)
		if t == c.token then
			return prev, nil
		end
		local problem = if t ~= "" then Keychain.checkSecret(t) else nil
		if problem then
			return prev, problem
		end
		c.token = t
		untested(c)
	elseif id == "context" then
		c.context = trim(text)
		c.context_auto = c.context == ""
		if c.context_auto then
			local url = M.normalizeUrl(c.url)
			c.context = if url then M.contextFromUrl(url) else ""
		end
		-- The stored keychain item is named after the old context.
		if c.phase == "stored" and c.context ~= prev.context then
			untested(c)
		end
	elseif id == "env_name" then
		local t = trim(text)
		if t ~= "" and not M.validEnvName(t) then
			return prev, "an environment variable name is letters, digits and '_', not starting with a digit"
		end
		c.env_name = t
	elseif id == "storage" then
		if text ~= "keychain" and text ~= "env" then
			return prev, nil
		end
		if text == "keychain" and c.platform == nil then
			return prev, "no keychain tool was found on this machine"
		end
		c.storage = text :: Storage
	elseif string.sub(id, 1, 3) == "ds." then
		c.picks = Tbl.copy(c.picks)
		c.picks[string.sub(id, 4)] = text
	end
	return c, nil
end

function M.cycle(c: Conn, f: Field, delta: number): Conn
	local values = f.values or {}
	if #values == 0 then
		return c
	end
	local i = table.find(values, M.value(c, f.id)) or 1
	return (M.setField(c, f.id, values[(i - 1 + delta) % #values + 1]))
end

-- Test --------------------------------------------------------------------------------------

-- An in-memory route for the typed URL. In update mode the saved endpoint's
-- non-secret settings (TLS, headers, org, prefix) apply, so the test talks
-- to the server the way the plugin will.
function M.route(c: Conn, saved: Route?): Route?
	local url = M.normalizeUrl(c.url)
	if url == nil then
		return nil
	end
	local base = if saved then saved.endpoint else nil
	return {
		context = if c.context ~= "" then c.context else "connect",
		signal = "dashboards",
		via = "grafana",
		endpoint_name = "grafana",
		endpoint = {
			url = url,
			auth = { type = "none" },
			headers = if base then base.headers else {},
			path_prefix = if base then base.path_prefix else "",
			tls = if base then base.tls else nil,
			timeout_ms = if base then base.timeout_ms else M.TIMEOUT_MS,
			org_id = if base then base.org_id else nil,
		},
	}
end

local PATHS: { [string]: string } = {
	user = "/api/user",
	frontend = "/api/frontend/settings",
	actions = "/api/access-control/user/actions",
}

-- The test requests, each carrying the typed token in its own header.
function M.requests(c: Conn): { { step: Step, request: Request } }
	local out = {}
	for _, step in M.STEPS do
		table.insert(out, {
			step = step :: Step,
			request = {
				method = "GET",
				path = PATHS[step],
				headers = { Authorization = "Bearer " .. c.token },
			} :: Request,
		})
	end
	return out
end

-- Problems that keep a test from starting.
function M.testProblem(c: Conn): string?
	local _, urlErr = M.normalizeUrl(c.url)
	if urlErr then
		return urlErr
	end
	if c.token == "" then
		return "paste the service account token first"
	end
	return nil
end

function M.startTest(prev: Conn): Conn
	local c = Tbl.copy(prev)
	untested(c)
	c.phase = "testing"
	return c
end

local function redact(c: Conn, text: string): string
	if c.token == "" then
		return text
	end
	return Auth.redact(text, { c.token })
end

local function hintFor(route: Route, err: QueryError): string?
	if err.kind == "auth" and err.status == 401 then
		return "Grafana rejected the token: copy it again (it is shown only once) or add a new token to the "
			.. "service account"
	elseif err.kind == "auth" and err.status == 403 then
		return "the token works but cannot read this API: give the service account the Viewer role or higher"
	elseif err.kind == "http" and err.status == 404 then
		return "no Grafana API at this URL: use the address you open Grafana at, e.g. https://you.grafana.net"
	end
	local probeRoute = Tbl.copy(route)
	probeRoute.endpoint = Tbl.copy(route.endpoint)
	probeRoute.endpoint.auth = { type = "bearer", token = { from = "env", field = "token_env", name = "" } }
	return Probe.hint(probeRoute, err)
end

-- What a failed step shows: the error without the generic fix classify may
-- have appended (the flow's own hint replaces it), redacted.
local function failureOf(c: Conn, what: string, route: Route, err: QueryError): Failure
	local message = err.message
	local own = (err :: any).hint
	if type(own) == "string" and own ~= "" then
		local suffix = "; " .. own
		if string.sub(message, -#suffix) == suffix then
			message = string.sub(message, 1, -#suffix - 1)
		end
	end
	return { message = what .. ": " .. redact(c, message), hint = hintFor(route, err) }
end

local function rank(kind: string, cand: Candidate): number
	if cand.is_default then
		return 0
	end
	local uid = string.lower(cand.uid)
	for _, word in INTERNAL do
		if string.find(uid, word) then
			return 3
		end
	end
	local suffix = CLOUD_SUFFIX[kind]
	if
		suffix
		and (uid == "grafanacloud-" .. suffix or string.match(uid, "^grafanacloud%-.+%-" .. suffix .. "$") ~= nil)
	then
		return 1
	end
	return 2
end

-- Datasources of each kind from /api/frontend/settings, best pick first:
-- the default datasource, then a Grafana Cloud stack's own uid
-- (grafanacloud-[stack-]prom/logs/traces), then the rest by name, with
-- Grafana Cloud's internal ones (usage, ML, alert history) last.
function M.discover(doc: any, env: Env): { [string]: { Candidate } }
	local out: { [string]: { Candidate } } = {}
	for _, kind in M.KINDS do
		out[kind] = {}
	end
	local list = if type(doc) == "table" then Env.value(env, doc.datasources) else nil
	if type(list) ~= "table" then
		return out
	end
	for key, ds in list do
		if type(ds) ~= "table" then
			continue
		end
		local uid = Env.value(env, ds.uid)
		local dsType = Env.value(env, ds.type)
		if type(uid) ~= "string" or uid == "" or type(dsType) ~= "string" then
			continue
		end
		for _, kind in M.KINDS do
			if TYPE[kind] == dsType then
				local name = Env.value(env, ds.name)
				table.insert(out[kind], {
					uid = uid,
					name = if type(name) == "string" then name elseif type(key) == "string" then key else uid,
					type = dsType,
					is_default = Env.value(env, ds.isDefault) == true,
				})
			end
		end
	end
	for _, kind in M.KINDS do
		table.sort(out[kind], function(a: Candidate, b: Candidate): boolean
			local ra, rb = rank(kind, a), rank(kind, b)
			if ra ~= rb then
				return ra < rb
			end
			return a.name < b.name
		end)
	end
	return out
end

-- The pick per kind: a previous pick still offered, else the best
-- candidate; Alertmanager defaults to none (Grafana-managed alerting).
function M.choose(candidates: { [string]: { Candidate } }, previous: { [string]: string }): { [string]: string }
	local out: { [string]: string } = {}
	for _, kind in M.KINDS do
		local list: { Candidate } = candidates[kind] or {}
		local prev = previous[kind]
		local keep = false
		if prev then
			for _, cand in list do
				if cand.uid == prev then
					keep = true
				end
			end
		end
		if keep then
			out[kind] = prev :: string
		elseif kind ~= "alertmanager" and list[1] then
			out[kind] = list[1].uid
		else
			out[kind] = ""
		end
	end
	return out
end

-- Folds one answer into the test: once every step answered the test is
-- either "tested" (picks chosen) or back to "edit" with the failure.
function M.answer(prev: Conn, route: Route, step: Step, response: TransportTypes.Response, env: Env): Conn
	local c = Tbl.copy(prev)
	c.answers = Tbl.copy(c.answers)
	c.answers[step] = true
	local result: any = if c.result then Tbl.copy(c.result) else { login = "", candidates = {} }
	if step == "user" then
		local r = Grafana.parseUser(route, response, env)
		if not r.ok then
			local err = (r :: any).error :: QueryError
			c.failure = c.failure or failureOf(c, "sign-in", route, err)
		else
			result.login = (r :: any).user.login
		end
	elseif step == "frontend" then
		local doc, err = Response.json(response, env, "frontend settings")
		if err then
			c.failure = c.failure or failureOf(c, "settings", route, err)
		else
			local build = Env.value(env, doc.buildInfo)
			local version = if type(build) == "table" then Env.value(env, build.version) else nil
			result.version = if type(version) == "string" then version else nil
			result.candidates = M.discover(doc, env)
		end
	else
		-- Optional: older or restricted servers lack it; no warning then.
		local doc = Response.json(response, env, "permissions")
		if type(doc) == "table" then
			result.can_silence = Env.value(env, doc["alert.silences:create"]) == true
				or Env.value(env, doc["alert.instances:create"]) == true
			result.can_annotate = Env.value(env, doc["annotations:create"]) == true
		end
	end
	c.result = result
	for _, s in M.STEPS do
		if not c.answers[s] then
			return c
		end
	end
	if c.failure then
		c.result = nil
		c.phase = "edit"
	else
		c.phase = "tested"
		c.picks = M.choose(result.candidates, c.picks)
	end
	return c
end

-- Role warnings for the tested token.
function M.warnings(c: Conn): { string }
	local out: { string } = {}
	local r = c.result
	if r == nil then
		return out
	end
	if r.can_silence == false or r.can_annotate == false then
		local missing: { string } = {}
		if r.can_silence == false then
			table.insert(missing, "silences")
		end
		if r.can_annotate == false then
			table.insert(missing, "annotations")
		end
		table.insert(
			out,
			"This token cannot create "
				.. table.concat(missing, " or ")
				.. " (Viewer role): those actions stay disabled. Give the service account the Editor role to use them."
		)
	end
	local any = false
	for _, kind in M.KINDS do
		if c.picks[kind] and c.picks[kind] ~= "" then
			any = true
		end
	end
	if not any then
		table.insert(out, "No Prometheus, Loki or Tempo datasource is visible to this token; dashboards still work.")
	end
	return out
end

-- Saving ------------------------------------------------------------------------------------

-- What blocks storing and writing, checked before the token goes anywhere.
function M.saveProblem(c: Conn, raw: Raw?): string?
	if c.phase == "testing" then
		return "the test is still running"
	elseif c.phase ~= "tested" and c.phase ~= "stored" then
		return "test the token first (t): nothing is stored until Grafana accepts it"
	end
	if c.context == "" then
		return "enter a context name"
	end
	if c.mode == "new" and Model.rawEndpoint(raw, c.context, "grafana") ~= nil then
		return string.format(
			"context %q already has a Grafana endpoint: choose another name, or use Update token on it",
			c.context
		)
	end
	if c.storage == "keychain" then
		if c.platform == nil then
			return "no keychain tool was found on this machine; store the token in an environment variable"
		end
		if not Keychain.validItem(M.itemName(c.context)) then
			return "the context name cannot name a keychain item: use letters, digits, '.', '_' and '-', "
				.. "starting with a letter or digit"
		end
	elseif not M.validEnvName(c.env_name) then
		return "enter the environment variable name that will hold the token, e.g. GRAFANA_TOKEN"
	end
	return nil
end

-- The document with the context's grafana endpoint written for `c`. An
-- updated endpoint keeps its other settings (headers, TLS, org, prefix).
function M.apply(raw: Raw?, c: Conn): Raw
	local original = Model.rawEndpoint(raw, c.context, "grafana")
	local ep: Raw = if original then Tbl.copy(original) else {}
	ep.url = M.normalizeUrl(c.url) or c.url
	ep.auth = if c.storage == "keychain"
		then { type = "bearer", token_keychain = M.itemName(c.context) }
		else { type = "bearer", token_env = c.env_name }
	local ds: Raw = {}
	local any = false
	for _, kind in M.KINDS do
		local uid = c.picks[kind]
		if uid and uid ~= "" then
			ds[kind] = uid
			any = true
		end
	end
	ep.datasources = if any then ds else nil
	local out = Model.putEndpoint(raw, c.context, "grafana", ep)
	if out.default_context == nil then
		out.default_context = c.context
	end
	return out
end

-- Drops the token once it is stored (or not needed: env storage).
function M.forget(prev: Conn): Conn
	local c = Tbl.copy(prev)
	c.token = ""
	return c
end

-- Keychain items an endpoint's auth references.
function M.keychainItems(ep: Raw?): { string }
	local out: { string } = {}
	local auth = if ep then ep.auth else nil
	if type(auth) == "table" then
		for _, field in { "token_keychain", "password_keychain" } do
			if type(auth[field]) == "string" then
				table.insert(out, auth[field])
			end
		end
	end
	return out
end

return M
