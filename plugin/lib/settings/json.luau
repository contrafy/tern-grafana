--!strict
-- Config file text for the settings block: an ordered, indented encoding of
-- the decoded document, so a rewrite keeps the documented key order instead
-- of reshuffling a hand-written file. Parts the schema does not describe
-- (feature sections, anything unknown) go through the runtime's own JSON
-- encoder, which keeps empty arrays as `[]`, and are only re-indented.

local M = {}

M.INDENT = "  "

type Kind = "top" | "contexts" | "context" | "endpoint" | "auth" | "headers" | "tls" | "datasources" | "argv"

local ORDER: { [Kind]: { string } } = {
	top = {
		"version",
		"default_context",
		"contexts",
		"query",
		"alerts",
		"annotations",
		"impact",
		"watches",
		"hosts",
	},
	context = { "grafana", "prometheus", "alertmanager", "loki", "tempo" },
	endpoint = {
		"url",
		"browser_url",
		"path_prefix",
		"org_id",
		"auth",
		"headers",
		"tls",
		"timeout_ms",
		"datasources",
	},
	auth = {
		"type",
		"username",
		"token_cmd",
		"token_env",
		"token_file",
		"password_cmd",
		"password_env",
		"password_file",
	},
	tls = { "ca_file", "cert_file", "key_file", "insecure" },
	datasources = { "prometheus", "loki", "tempo", "alertmanager" },
}

local function childKind(kind: Kind, key: string): Kind?
	if kind == "top" then
		return if key == "contexts" then "contexts" else nil
	elseif kind == "contexts" then
		return "context"
	elseif kind == "context" then
		return "endpoint"
	elseif kind == "endpoint" then
		if key == "auth" then
			return "auth"
		elseif key == "headers" then
			return "headers"
		elseif key == "tls" then
			return "tls"
		elseif key == "datasources" then
			return "datasources"
		end
	elseif kind == "auth" then
		if string.sub(key, -4) == "_cmd" then
			return "argv"
		end
	end
	return nil
end

local ESCAPES: { [string]: string } = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
	["\b"] = "\\b",
	["\f"] = "\\f",
}

function M.quote(s: string): string
	return '"'
		.. string.gsub(s, '[%c"\\]', function(c: string): string
			return ESCAPES[c] or string.format("\\u%04x", string.byte(c))
		end)
		.. '"'
end

local function scalar(v: any): string?
	local tv = type(v)
	if tv == "string" then
		return M.quote(v)
	elseif tv == "boolean" then
		return tostring(v)
	elseif tv == "number" then
		if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
			return string.format("%d", v)
		end
		return string.format("%.17g", v)
	end
	return nil
end

-- Re-indents compact JSON text (as produced by an encoder) so nested values
-- line up with the surrounding document. Empty containers stay `{}` / `[]`.
function M.reindent(text: string, indent: string): string
	local out = buffer.create(#text * 2 + 64)
	local size = buffer.len(out)
	local o = 0
	local function put(s: string)
		local n = #s
		if o + n > size then
			local bigger = buffer.create(math.max(size * 2, o + n))
			buffer.copy(bigger, 0, out, 0, o)
			out = bigger
			size = buffer.len(out)
		end
		buffer.writestring(out, o, s)
		o += n
	end
	local depth = 0
	local i = 1
	local n = #text
	while i <= n do
		local c = string.sub(text, i, i)
		if c == '"' then
			local j = i + 1
			while j <= n do
				local d = string.sub(text, j, j)
				if d == "\\" then
					j += 2
				elseif d == '"' then
					break
				else
					j += 1
				end
			end
			put(string.sub(text, i, j))
			i = j + 1
		elseif c == "{" or c == "[" then
			local close = if c == "{" then "}" else "]"
			local k = i + 1
			while k <= n and string.find(string.sub(text, k, k), "^%s") do
				k += 1
			end
			if string.sub(text, k, k) == close then
				put(c .. close)
				i = k + 1
			else
				depth += 1
				put(c .. "\n" .. indent .. string.rep(M.INDENT, depth))
				i += 1
			end
		elseif c == "}" or c == "]" then
			depth -= 1
			put("\n" .. indent .. string.rep(M.INDENT, depth) .. c)
			i += 1
		elseif c == "," then
			put(",\n" .. indent .. string.rep(M.INDENT, depth))
			i += 1
		elseif c == ":" then
			put(": ")
			i += 1
		elseif string.find(c, "^%s") then
			i += 1
		else
			local j = i
			while j <= n and not string.find(string.sub(text, j, j), '^[%s,:%[%]{}"]') do
				j += 1
			end
			put(string.sub(text, i, j - 1))
			i = j
		end
	end
	return buffer.readstring(out, 0, o)
end

local function keysOf(t: { [any]: any }, kind: Kind): { string }
	local known: { string } = ORDER[kind] or {}
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, k in known do
		if t[k] ~= nil then
			table.insert(out, k)
			seen[k] = true
		end
	end
	local rest: { string } = {}
	for k in t do
		if type(k) == "string" and not seen[k] then
			table.insert(rest, k)
		end
	end
	table.sort(rest)
	table.move(rest, 1, #rest, #out + 1, out)
	return out
end

local function isPlainObject(t: { [any]: any }): boolean
	for k in t do
		if type(k) ~= "string" then
			return false
		end
	end
	return true
end

local function isStringList(t: { [any]: any }): boolean
	if #t == 0 then
		return false
	end
	local count = 0
	for k, v in t do
		if type(k) ~= "number" or type(v) ~= "string" then
			return false
		end
		count += 1
	end
	return count == #t
end

local function encodeAt(v: any, kind: Kind?, indent: string, encode: (any) -> string): string
	local s = scalar(v)
	if s then
		return s
	end
	if type(v) ~= "table" then
		return "null"
	end
	if kind == "argv" and isStringList(v) then
		local parts = table.create(#v)
		for i, item in v do
			parts[i] = M.quote(item)
		end
		return "[" .. table.concat(parts, ", ") .. "]"
	end
	if kind == nil or kind == "argv" or not isPlainObject(v) then
		return M.reindent(encode(v), indent)
	end
	local keys = keysOf(v, kind)
	if #keys == 0 then
		return "{}"
	end
	local inner = indent .. M.INDENT
	local parts = table.create(#keys)
	for i, k in keys do
		parts[i] = inner .. M.quote(k) .. ": " .. encodeAt(v[k], childKind(kind, k), inner, encode)
	end
	return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

-- The file text for a decoded (and edited) top-level object. `encode` is the
-- runtime's JSON encoder (tern.json.encode), used for unknown parts only.
function M.encode(raw: { [string]: any }, encode: (any) -> string): string
	return encodeAt(raw, "top", "", encode) .. "\n"
end

-- FNV-1a (32 bit) of the bytes plus the length: identifies the file text the
-- block loaded, so a write can refuse when the file changed underneath.
function M.hash(text: string): string
	local h = 2166136261
	for i = 1, #text do
		h = bit32.bxor(h, string.byte(text, i))
		-- h * 16777619 mod 2^32 without losing bits in a double.
		h = (bit32.lshift(h, 24) + h * 403) % 4294967296
	end
	return string.format("%08x-%d", h, #text)
end

return M
