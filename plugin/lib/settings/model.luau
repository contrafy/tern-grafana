--!strict
-- The settings block's view of the config file: contexts and endpoints read
-- from the decoded document (which may be invalid), edit forms, and the
-- document edits they produce. Edits change only the tables on their path,
-- so feature sections and anything else in the file are kept as decoded.
-- The block never handles secrets: forms only hold references (a command, an
-- environment variable name, a file path) and header values, which the
-- config already stores in plain text.

local M = {}

M.ENDPOINTS = table.freeze({ "grafana", "prometheus", "alertmanager", "loki", "tempo" })
M.AUTH_TYPES = table.freeze({ "none", "bearer", "basic" })
M.SOURCES = table.freeze({ "cmd", "env", "file" })
M.DATASOURCE_KEYS = table.freeze({ "prometheus", "loki", "tempo", "alertmanager" })
M.MASK = "********"

local VERSION = 1

export type Raw = { [string]: any }

export type Problem = { path: string, message: string }

export type Mode = "new_context" | "new_endpoint" | "edit_endpoint" | "rename_context"

export type Form = {
	mode: Mode,
	-- The context being edited, renamed or extended ("" for a new context).
	context: string,
	-- The endpoint being edited ("" when it is new: `values.kind` names it).
	endpoint: string,
	values: { [string]: string },
	-- Header names in display order; values live under "header:<name>".
	headers: { string },
}

export type FieldKind = "text" | "enum"

export type Field = {
	id: string,
	label: string,
	kind: FieldKind,
	values: { string }?,
	-- JSON path of the config value the field writes; problems attach here.
	path: string,
	-- Problems attach only on an exact path match (not to paths below it).
	exact: boolean?,
	hint: string,
	-- A header whose name looks like it carries a credential: its value is
	-- never shown.
	sensitive: boolean?,
}

-- Helpers ------------------------------------------------------------------------

local function isTable(v: any): boolean
	return type(v) == "table"
end

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") :: string
end

function M.contextNames(raw: Raw?): { string }
	local out: { string } = {}
	local contexts = if raw then raw.contexts else nil
	if not isTable(contexts) then
		return out
	end
	for name, v in contexts do
		if type(name) == "string" and isTable(v) then
			table.insert(out, name)
		end
	end
	table.sort(out)
	return out
end

local function contextOf(raw: Raw?, name: string): Raw?
	local contexts = if raw then raw.contexts else nil
	if not isTable(contexts) then
		return nil
	end
	local ctx = contexts[name]
	return if isTable(ctx) then ctx else nil
end

-- Endpoints present in a context, in documented order.
function M.endpointNames(raw: Raw?, context: string): { string }
	local ctx = contextOf(raw, context)
	local out: { string } = {}
	if ctx == nil then
		return out
	end
	for _, name in M.ENDPOINTS do
		if ctx[name] ~= nil then
			table.insert(out, name)
		end
	end
	return out
end

function M.rawEndpoint(raw: Raw?, context: string, endpoint: string): Raw?
	local ctx = contextOf(raw, context)
	local ep = if ctx then ctx[endpoint] else nil
	return if isTable(ep) then ep else nil
end

function M.defaultContext(raw: Raw?): string?
	if raw == nil then
		return nil
	end
	local d = raw.default_context
	if type(d) == "string" then
		return d
	end
	local names = M.contextNames(raw)
	return if #names == 1 then names[1] else nil
end

-- Names such as Authorization-like API keys, cookies and tokens.
local SENSITIVE = { "auth", "token", "key", "secret", "passw", "cookie", "session", "credential", "signature" }

function M.isSensitiveHeader(name: string): boolean
	local lower = string.lower(name)
	for _, word in SENSITIVE do
		if string.find(lower, word, 1, true) then
			return true
		end
	end
	return false
end

function M.headerDisplay(name: string, value: any): string
	if M.isSensitiveHeader(name) then
		return name .. ": " .. M.MASK
	end
	return name .. ": " .. (if type(value) == "string" then value else "(not a string)")
end

-- argv as one line: plain words joined, words with spaces or quotes quoted.
function M.argvText(argv: { any }): string
	local parts: { string } = {}
	for i, arg in argv do
		local s = tostring(arg)
		if s == "" or string.find(s, "[%s\"'\\]") then
			s = '"' .. string.gsub(s, '["\\]', "\\%0") .. '"'
		end
		parts[i] = s
	end
	return table.concat(parts, " ")
end

local function needsJson(argv: { any }): boolean
	for _, arg in argv do
		if type(arg) ~= "string" or arg == "" or string.find(arg, "[%s\"'\\%[]") then
			return true
		end
	end
	return false
end

-- Summaries (list view) ------------------------------------------------------------

local function sourceOf(auth: Raw, base: string): (string?, any)
	for _, from in M.SOURCES do
		local field = base .. "_" .. from
		if auth[field] ~= nil then
			return field, auth[field]
		end
	end
	return nil, nil
end

local function referenceText(field: string, v: any): string
	if string.sub(field, -4) == "_cmd" and isTable(v) then
		return M.argvText(v)
	end
	return tostring(v)
end

function M.authSummary(auth: any): string
	if auth == nil then
		return "no auth"
	end
	if not isTable(auth) or type(auth.type) ~= "string" then
		return "invalid auth"
	end
	if auth.type == "none" then
		return "no auth"
	end
	local base = if auth.type == "basic" then "password" else "token"
	local field, v = sourceOf(auth, base)
	local who = if auth.type == "basic" and type(auth.username) == "string" then " " .. auth.username else ""
	if field == nil then
		return auth.type .. who .. ", no " .. base .. " source"
	end
	return string.format("%s%s, %s: %s", auth.type, who, field, referenceText(field, v))
end

export type Summary = {
	url: string,
	path_prefix: string?,
	auth: string,
	headers: { string },
	tls: string?,
	datasources: string?,
	extra: { string },
}

function M.summary(ep: Raw): Summary
	local headers: { string } = {}
	if isTable(ep.headers) then
		local names: { string } = {}
		for name in ep.headers do
			if type(name) == "string" then
				table.insert(names, name)
			end
		end
		table.sort(names)
		for _, name in names do
			table.insert(headers, M.headerDisplay(name, ep.headers[name]))
		end
	end
	local tls: string? = nil
	if isTable(ep.tls) then
		local parts: { string } = {}
		for _, key in { "ca_file", "cert_file", "key_file" } do
			if ep.tls[key] ~= nil then
				table.insert(parts, key .. " " .. tostring(ep.tls[key]))
			end
		end
		if ep.tls.insecure == true then
			table.insert(parts, "insecure")
		end
		tls = if #parts > 0 then table.concat(parts, ", ") else nil
	end
	local datasources: string? = nil
	if isTable(ep.datasources) then
		local parts: { string } = {}
		for _, key in M.DATASOURCE_KEYS do
			if ep.datasources[key] ~= nil then
				table.insert(parts, key .. "=" .. tostring(ep.datasources[key]))
			end
		end
		datasources = if #parts > 0 then table.concat(parts, " ") else nil
	end
	local extra: { string } = {}
	if ep.org_id ~= nil then
		table.insert(extra, "org " .. tostring(ep.org_id))
	end
	if ep.timeout_ms ~= nil then
		table.insert(extra, "timeout " .. tostring(ep.timeout_ms) .. " ms")
	end
	if type(ep.browser_url) == "string" then
		table.insert(extra, "browser " .. ep.browser_url)
	end
	return {
		url = if type(ep.url) == "string" then ep.url else "(no url)",
		path_prefix = if type(ep.path_prefix) == "string" and ep.path_prefix ~= "" then ep.path_prefix else nil,
		auth = M.authSummary(ep.auth),
		headers = headers,
		tls = tls,
		datasources = datasources,
		extra = extra,
	}
end

-- Forms --------------------------------------------------------------------------

local function emptyValues(): { [string]: string }
	return {
		url = "",
		path_prefix = "",
		timeout_ms = "",
		["auth.type"] = "none",
		["auth.username"] = "",
		["auth.source"] = "env",
		["auth.reference"] = "",
		["tls.ca_file"] = "",
		["tls.cert_file"] = "",
		["tls.key_file"] = "",
		["tls.insecure"] = "false",
		org_id = "",
		browser_url = "",
		["ds.prometheus"] = "",
		["ds.loki"] = "",
		["ds.tempo"] = "",
		["ds.alertmanager"] = "",
		header_new = "",
	}
end

local function textOf(v: any, encode: (any) -> string): string
	if v == nil then
		return ""
	elseif type(v) == "string" then
		return v
	elseif type(v) == "table" then
		local ok, s = pcall(encode, v)
		return if ok then s else ""
	end
	return tostring(v)
end

-- Endpoint kinds a context does not have yet.
function M.missingEndpoints(raw: Raw?, context: string): { string }
	local present = M.endpointNames(raw, context)
	local out: { string } = {}
	for _, name in M.ENDPOINTS do
		if not table.find(present, name) then
			table.insert(out, name)
		end
	end
	return out
end

function M.newContextForm(): Form
	local values = emptyValues()
	values.context = ""
	values.kind = "prometheus"
	return { mode = "new_context", context = "", endpoint = "", values = values, headers = {} }
end

function M.newEndpointForm(raw: Raw?, context: string): Form?
	local missing = M.missingEndpoints(raw, context)
	if #missing == 0 then
		return nil
	end
	local values = emptyValues()
	values.kind = missing[1]
	return { mode = "new_endpoint", context = context, endpoint = "", values = values, headers = {} }
end

function M.renameForm(context: string): Form
	return { mode = "rename_context", context = context, endpoint = "", values = { context = context }, headers = {} }
end

function M.editForm(raw: Raw?, context: string, endpoint: string, encode: (any) -> string): Form?
	local ep = M.rawEndpoint(raw, context, endpoint)
	if ep == nil then
		return nil
	end
	local values = emptyValues()
	values.url = textOf(ep.url, encode)
	values.path_prefix = textOf(ep.path_prefix, encode)
	values.timeout_ms = textOf(ep.timeout_ms, encode)
	values.org_id = textOf(ep.org_id, encode)
	values.browser_url = textOf(ep.browser_url, encode)
	local auth = ep.auth
	if isTable(auth) and type(auth.type) == "string" and table.find(M.AUTH_TYPES, auth.type) then
		values["auth.type"] = auth.type
		values["auth.username"] = textOf(auth.username, encode)
		local base = if auth.type == "basic" then "password" else "token"
		local field, v = sourceOf(auth, base)
		if field then
			values["auth.source"] = string.sub(field, #base + 2)
			if isTable(v) and string.sub(field, -4) == "_cmd" then
				values["auth.reference"] = if needsJson(v) then textOf(v, encode) else M.argvText(v)
			else
				values["auth.reference"] = textOf(v, encode)
			end
		end
	end
	if isTable(ep.tls) then
		values["tls.ca_file"] = textOf(ep.tls.ca_file, encode)
		values["tls.cert_file"] = textOf(ep.tls.cert_file, encode)
		values["tls.key_file"] = textOf(ep.tls.key_file, encode)
		values["tls.insecure"] = if ep.tls.insecure == true then "true" else "false"
	end
	if isTable(ep.datasources) then
		for _, key in M.DATASOURCE_KEYS do
			values["ds." .. key] = textOf(ep.datasources[key], encode)
		end
	end
	local headers: { string } = {}
	if isTable(ep.headers) then
		for name, v in ep.headers do
			if type(name) == "string" then
				table.insert(headers, name)
				values["header:" .. name] = textOf(v, encode)
			end
		end
		table.sort(headers)
	end
	return { mode = "edit_endpoint", context = context, endpoint = endpoint, values = values, headers = headers }
end

function M.formKind(form: Form): string
	return if form.endpoint ~= "" then form.endpoint else form.values.kind or "prometheus"
end

function M.formContext(form: Form): string
	if form.mode == "new_context" then
		return trim(form.values.context or "")
	end
	return form.context
end

local function basePath(form: Form): string
	local name = M.formContext(form)
	return "contexts." .. (if name == "" then "<name>" else name) .. "." .. M.formKind(form)
end

local function sourceField(form: Form): string
	local base = if form.values["auth.type"] == "basic" then "password" else "token"
	return base .. "_" .. (form.values["auth.source"] or "env")
end

local REFERENCE_HINT: { [string]: string } = {
	cmd = 'program and arguments, e.g. op read op://vault/item/token (or a JSON array ["op", "read", "..."])',
	env = "environment variable of the Tern process, e.g. GRAFANA_TOKEN",
	file = "absolute path or ~/..., a private file (chmod 600)",
}

-- The form's fields, in display order, for its current values.
function M.fields(form: Form, raw: Raw?): { Field }
	local out: { Field } = {}
	local function add(f: Field)
		table.insert(out, f)
	end
	if form.mode == "new_context" or form.mode == "rename_context" then
		add({
			id = "context",
			label = "context",
			kind = "text",
			path = "contexts." .. trim(form.values.context or ""),
			exact = true,
			hint = "letters, digits, '.', '_' and '-'",
		})
	end
	if form.mode == "rename_context" then
		return out
	end
	local base = basePath(form)
	if form.mode == "new_context" then
		add({
			id = "kind",
			label = "endpoint",
			kind = "enum",
			values = M.ENDPOINTS,
			path = base,
			exact = true,
			hint = "the first endpoint of the context; add more later",
		})
	elseif form.mode == "new_endpoint" then
		add({
			id = "kind",
			label = "endpoint",
			kind = "enum",
			values = M.missingEndpoints(raw, form.context),
			path = base,
			exact = true,
			hint = "endpoints this context does not have yet",
		})
	end
	local isGrafana = M.formKind(form) == "grafana"
	add({ id = "url", label = "url", kind = "text", path = base .. ".url", hint = "http(s) base URL, no credentials" })
	if isGrafana then
		add({
			id = "browser_url",
			label = "browser_url",
			kind = "text",
			path = base .. ".browser_url",
			hint = "public URL for the browser pane, when it differs from url (optional)",
		})
	end
	add({
		id = "path_prefix",
		label = "path_prefix",
		kind = "text",
		path = base .. ".path_prefix",
		hint = "inserted before every API path, e.g. /prometheus for Mimir (optional)",
	})
	if isGrafana then
		add({
			id = "org_id",
			label = "org_id",
			kind = "text",
			path = base .. ".org_id",
			hint = "Grafana organization id (optional)",
		})
	end
	local authType = form.values["auth.type"] or "none"
	add({
		id = "auth.type",
		label = "auth",
		kind = "enum",
		values = M.AUTH_TYPES,
		path = base .. ".auth.type",
		hint = "none, bearer token or basic username and password",
	})
	if authType == "basic" then
		add({
			id = "auth.username",
			label = "username",
			kind = "text",
			path = base .. ".auth.username",
			hint = "not a secret; written as is",
		})
	end
	if authType ~= "none" then
		local secret = if authType == "basic" then "password" else "token"
		add({
			id = "auth.source",
			label = secret .. " from",
			kind = "enum",
			values = M.SOURCES,
			path = base .. ".auth",
			hint = "where the plugin reads the " .. secret .. " when a request needs it",
		})
		add({
			id = "auth.reference",
			label = sourceField(form),
			kind = "text",
			path = base .. ".auth." .. sourceField(form),
			hint = REFERENCE_HINT[form.values["auth.source"] or "env"] or "",
		})
	end
	for _, name in form.headers do
		add({
			id = "header:" .. name,
			label = "header " .. name,
			kind = "text",
			path = base .. ".headers." .. name,
			hint = if M.isSensitiveHeader(name)
				then "value hidden; type a new one to replace it, x removes the header"
				else "x removes the header",
			sensitive = M.isSensitiveHeader(name),
		})
	end
	add({
		id = "header_new",
		label = "add header",
		kind = "text",
		path = base .. ".headers",
		hint = "Name: value, e.g. X-Scope-OrgID: team-a (credentials belong in auth)",
	})
	add({
		id = "tls.ca_file",
		label = "tls.ca_file",
		kind = "text",
		path = base .. ".tls.ca_file",
		hint = "CA bundle for a private or self-signed CA (optional)",
	})
	add({
		id = "tls.cert_file",
		label = "tls.cert_file",
		kind = "text",
		path = base .. ".tls.cert_file",
		hint = "client certificate for mutual TLS (optional)",
	})
	add({
		id = "tls.key_file",
		label = "tls.key_file",
		kind = "text",
		path = base .. ".tls.key_file",
		hint = "client key; needs tls.cert_file (optional)",
	})
	add({
		id = "tls.insecure",
		label = "tls.insecure",
		kind = "enum",
		values = { "false", "true" },
		path = base .. ".tls.insecure",
		hint = "true skips certificate verification: local labs only",
	})
	add({
		id = "timeout_ms",
		label = "timeout_ms",
		kind = "text",
		path = base .. ".timeout_ms",
		hint = "per-request timeout, 1 to 600000 (default 15000)",
	})
	if isGrafana then
		for _, key in M.DATASOURCE_KEYS do
			add({
				id = "ds." .. key,
				label = "datasources." .. key,
				kind = "text",
				path = base .. ".datasources." .. key,
				hint = "uid of the Grafana datasource serving " .. key .. " (optional)",
			})
		end
	end
	return out
end

-- Assigns each problem to the field with the longest matching path; the
-- rest belong to the form as a whole.
function M.assign(fields: { Field }, problems: { Problem }): ({ [string]: { string } }, { Problem })
	local byField: { [string]: { string } } = {}
	local rest: { Problem } = {}
	for _, p in problems do
		local best: Field? = nil
		for _, f in fields do
			local match = p.path == f.path or (not f.exact and string.sub(p.path, 1, #f.path + 1) == f.path .. ".")
			if match and (best == nil or #f.path > #best.path) then
				best = f
			end
		end
		if best then
			local list = byField[best.id] or {}
			table.insert(list, p.message)
			byField[best.id] = list
		else
			table.insert(rest, p)
		end
	end
	return byField, rest
end

-- Form edits ------------------------------------------------------------------------

-- Sets a field's text. "header_new" takes "Name: value" and adds (or
-- replaces) that header; an empty edit of a sensitive header keeps its value.
function M.setField(form: Form, id: string, text: string): (Form, string?)
	local out = table.clone(form)
	out.values = table.clone(form.values)
	if id == "header_new" then
		local t = trim(text)
		if t == "" then
			return form, nil
		end
		local name, value = string.match(t, "^([^:%s]+)%s*:%s?(.*)$")
		if name == nil then
			return form, "enter a header as Name: value"
		end
		if string.lower(name :: string) == "authorization" then
			return form, "set credentials with auth, not an Authorization header"
		end
		out.headers = table.clone(form.headers)
		if not table.find(out.headers, name) then
			table.insert(out.headers, name)
		end
		out.values["header:" .. name] = value :: string
		return out, nil
	end
	if string.sub(id, 1, 7) == "header:" then
		if text == "" and M.isSensitiveHeader(string.sub(id, 8)) then
			return form, nil
		end
		out.values[id] = text
		return out, nil
	end
	out.values[id] = if id == "auth.reference" then text else trim(text)
	return out, nil
end

function M.removeHeader(form: Form, name: string): Form
	local out = table.clone(form)
	out.values = table.clone(form.values)
	out.values["header:" .. name] = nil
	out.headers = {}
	for _, h in form.headers do
		if h ~= name then
			table.insert(out.headers, h)
		end
	end
	return out
end

-- The text an edit of field `f` starts from.
function M.editText(form: Form, f: Field): string
	if f.sensitive then
		return ""
	end
	return form.values[f.id] or ""
end

-- The value shown for a field.
function M.display(form: Form, f: Field): string
	local v = form.values[f.id] or ""
	if f.sensitive then
		return M.MASK
	end
	return v
end

function M.cycle(form: Form, f: Field, delta: number): Form
	local values = f.values or {}
	if #values == 0 then
		return form
	end
	local i = table.find(values, form.values[f.id]) or 0
	local nextValue = values[(i - 1 + delta) % #values + 1]
	local out = table.clone(form)
	out.values = table.clone(form.values)
	out.values[f.id] = nextValue
	return out
end

-- Document edits ------------------------------------------------------------------

local function numberOr(text: string): any
	if string.match(text, "^%-?%d+$") then
		return tonumber(text)
	end
	return text
end

local function parseArgv(text: string, decode: (string) -> any): (any, string?)
	local t = trim(text)
	if t == "" then
		return nil, nil
	end
	if string.sub(t, 1, 1) == "[" then
		local ok, v = pcall(decode, t)
		if not ok then
			return nil, 'not a valid JSON array; write words separated by spaces or ["prog", "arg"]'
		end
		return v, nil
	end
	local argv: { string } = {}
	local i = 1
	local n = #t
	while i <= n do
		local c = string.sub(t, i, i)
		if string.find(c, "%s") then
			i += 1
		elseif c == '"' or c == "'" then
			local j = i + 1
			local word = {}
			while j <= n and string.sub(t, j, j) ~= c do
				local d = string.sub(t, j, j)
				if d == "\\" and c == '"' and j < n then
					j += 1
					d = string.sub(t, j, j)
				end
				table.insert(word, d)
				j += 1
			end
			if j > n then
				return nil, "unbalanced quote in the command"
			end
			table.insert(argv, table.concat(word))
			i = j + 1
		else
			local j = i
			while j <= n and not string.find(string.sub(t, j, j), "%s") do
				j += 1
			end
			table.insert(argv, string.sub(t, i, j - 1))
			i = j
		end
	end
	return argv, nil
end

local MANAGED = {
	"url",
	"path_prefix",
	"timeout_ms",
	"auth",
	"headers",
	"tls",
	"org_id",
	"browser_url",
	"datasources",
}

-- The endpoint object a form describes. Problems that the validator cannot
-- see (an unparsable command line) come back with their JSON path.
function M.endpointFromForm(form: Form, original: Raw?, decode: (string) -> any): (Raw, { Problem })
	local problems: { Problem } = {}
	local v = form.values
	local base = basePath(form)
	local ep: Raw = if original then table.clone(original) else {}
	for _, key in MANAGED do
		ep[key] = nil
	end
	local function setText(key: string, text: string?)
		if text and text ~= "" then
			ep[key] = text
		end
	end
	setText("url", v.url)
	setText("path_prefix", v.path_prefix)
	if v.timeout_ms and v.timeout_ms ~= "" then
		ep.timeout_ms = numberOr(v.timeout_ms)
	end
	local authType = v["auth.type"] or "none"
	if authType == "bearer" or authType == "basic" then
		local auth: Raw = { type = authType }
		if authType == "basic" and v["auth.username"] ~= "" then
			auth.username = v["auth.username"]
		end
		local field = sourceField(form)
		local ref = v["auth.reference"] or ""
		if v["auth.source"] == "cmd" then
			local argv, err = parseArgv(ref, decode)
			if err then
				table.insert(problems, { path = base .. ".auth." .. field, message = err })
			elseif argv ~= nil then
				auth[field] = argv
			end
		elseif trim(ref) ~= "" then
			auth[field] = trim(ref)
		end
		ep.auth = auth
	end
	if #form.headers > 0 then
		local headers: Raw = {}
		for _, name in form.headers do
			headers[name] = v["header:" .. name] or ""
		end
		ep.headers = headers
	end
	local tls: Raw = {}
	for _, key in { "ca_file", "cert_file", "key_file" } do
		local t = v["tls." .. key]
		if t and t ~= "" then
			tls[key] = t
		end
	end
	if v["tls.insecure"] == "true" then
		tls.insecure = true
	end
	if next(tls) ~= nil then
		ep.tls = tls
	end
	if M.formKind(form) == "grafana" then
		if v.org_id and v.org_id ~= "" then
			ep.org_id = numberOr(v.org_id)
		end
		setText("browser_url", v.browser_url)
		local ds: Raw = {}
		for _, key in M.DATASOURCE_KEYS do
			local t = v["ds." .. key]
			if t and t ~= "" then
				ds[key] = t
			end
		end
		if next(ds) ~= nil then
			ep.datasources = ds
		end
	end
	return ep, problems
end

-- Copies of the top-level document and its contexts table, ready to change.
-- A `contexts` that is not an object stays as written (the validator reports
-- it) and edits land in a detached table.
local function withContexts(raw: Raw?): (Raw, Raw)
	local out: Raw = if raw then table.clone(raw) else {}
	local current = out.contexts
	local contexts: Raw = {}
	if current == nil then
		out.contexts = contexts
	elseif isTable(current) and #current == 0 then
		contexts = table.clone(current)
		out.contexts = contexts
	end
	if out.version == nil then
		out.version = VERSION
	end
	return out, contexts
end

local NAME_PATTERN = "^[%w_.%-]+$"

-- The document after applying `form`, or the problems that block it.
function M.applyForm(raw: Raw?, form: Form, decode: (string) -> any): (Raw?, { Problem })
	local out, contexts = withContexts(raw)
	if form.mode == "rename_context" then
		local name = trim(form.values.context or "")
		if name == "" then
			return nil, { { path = "contexts.", message = "enter a context name" } }
		end
		if name == form.context then
			return nil, { { path = "contexts." .. name, message = "the name did not change" } }
		end
		if contexts[name] ~= nil then
			return nil, { { path = "contexts." .. name, message = "a context with this name already exists" } }
		end
		if not string.match(name, NAME_PATTERN) then
			return nil,
				{
					{
						path = "contexts." .. name,
						message = "context names may only contain letters, digits, '.', '_' and '-'",
					},
				}
		end
		contexts[name] = contexts[form.context]
		contexts[form.context] = nil
		if out.default_context == form.context then
			out.default_context = name
		end
		return out, {}
	end
	local name = M.formContext(form)
	local kind = M.formKind(form)
	if form.mode == "new_context" then
		if name == "" then
			return nil, { { path = "contexts.", message = "enter a context name" } }
		end
		if contexts[name] ~= nil then
			return nil, { { path = "contexts." .. name, message = "a context with this name already exists" } }
		end
		local ep, problems = M.endpointFromForm(form, nil, decode)
		if #problems > 0 then
			return nil, problems
		end
		contexts[name] = { [kind] = ep }
		return out, {}
	end
	local ctx = contexts[name]
	if not isTable(ctx) then
		return nil, { { path = "contexts." .. name, message = "this context is no longer in the file; reload" } }
	end
	local ctxCopy: Raw = table.clone(ctx)
	if form.mode == "new_endpoint" and ctxCopy[kind] ~= nil then
		return nil, { { path = "contexts." .. name .. "." .. kind, message = "this context already has one" } }
	end
	local original = if form.mode == "edit_endpoint" then ctxCopy[kind] else nil
	local ep, problems = M.endpointFromForm(form, if isTable(original) then original else nil, decode)
	if #problems > 0 then
		return nil, problems
	end
	ctxCopy[kind] = ep
	contexts[name] = ctxCopy
	return out, {}
end

function M.removeEndpoint(raw: Raw?, context: string, endpoint: string): Raw
	local out, contexts = withContexts(raw)
	local ctx = contexts[context]
	if isTable(ctx) then
		local copy = table.clone(ctx)
		copy[endpoint] = nil
		contexts[context] = copy
	end
	return out
end

-- Removing the default context also unsets default_context (with one
-- context left, it becomes the default implicitly).
function M.removeContext(raw: Raw?, context: string): Raw
	local out, contexts = withContexts(raw)
	contexts[context] = nil
	if out.default_context == context then
		out.default_context = nil
	end
	return out
end

function M.setDefault(raw: Raw?, context: string): Raw
	local out = withContexts(raw)
	out.default_context = context
	return out
end

-- Starter templates ----------------------------------------------------------------

export type Template = { id: string, title: string, description: string, raw: Raw }

M.TEMPLATES = table.freeze({
	{
		id = "local",
		title = "Local dev stack",
		description = "Grafana on :3000 plus direct Prometheus, Alertmanager, Loki and Tempo on localhost. "
			.. "Set GRAFANA_TOKEN where Tern starts.",
		raw = {
			version = 1,
			default_context = "lab",
			contexts = {
				lab = {
					grafana = {
						url = "http://localhost:3000",
						auth = { type = "bearer", token_env = "GRAFANA_TOKEN" },
						org_id = 1,
						datasources = { prometheus = "prom3", loki = "loki", tempo = "tempo" },
					},
					prometheus = { url = "http://localhost:9090" },
					alertmanager = { url = "http://localhost:9093" },
					loki = { url = "http://localhost:3100" },
					tempo = { url = "http://localhost:3200" },
				},
			},
		},
	},
	{
		id = "cloud",
		title = "Grafana Cloud",
		description = "A Grafana Cloud stack with a service account token, and direct Prometheus with basic auth "
			.. "(instance id and an access policy token from 1Password). Replace the URLs and item paths.",
		raw = {
			version = 1,
			default_context = "cloud",
			contexts = {
				cloud = {
					grafana = {
						url = "https://example.grafana.net",
						auth = {
							type = "bearer",
							token_cmd = { "op", "read", "op://Work/Grafana Cloud/service-account-token" },
						},
						datasources = { prometheus = "grafanacloud-prom", loki = "grafanacloud-logs" },
					},
					prometheus = {
						url = "https://prometheus-prod-13-prod-us-east-0.grafana.net",
						path_prefix = "/api/prom",
						auth = {
							type = "basic",
							username = "123456",
							password_cmd = { "op", "read", "op://Work/Grafana Cloud/access-policy-token" },
						},
					},
				},
			},
		},
	},
	{
		id = "prometheus",
		title = "Prometheus direct",
		description = "One Prometheus-compatible server (Prometheus, Thanos, VictoriaMetrics) and its "
			.. "Alertmanager, without Grafana.",
		raw = {
			version = 1,
			default_context = "prom",
			contexts = {
				prom = {
					prometheus = { url = "http://localhost:9090" },
					alertmanager = { url = "http://localhost:9093" },
				},
			},
		},
	},
	{
		id = "mimir",
		title = "Mimir multi-tenant",
		description = "Mimir's Prometheus API and Alertmanager under their path prefixes, with the tenant in "
			.. "X-Scope-OrgID. Replace the URL and tenant.",
		raw = {
			version = 1,
			default_context = "mimir",
			contexts = {
				mimir = {
					prometheus = {
						url = "https://mimir.internal",
						path_prefix = "/prometheus",
						headers = { ["X-Scope-OrgID"] = "team-a" },
					},
					alertmanager = {
						url = "https://mimir.internal",
						path_prefix = "/alertmanager",
						headers = { ["X-Scope-OrgID"] = "team-a" },
					},
				},
			},
		},
	},
} :: { Template })

function M.template(id: string): Template?
	for _, t in M.TEMPLATES do
		if t.id == id then
			return t
		end
	end
	return nil
end

return M
