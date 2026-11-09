--!strict
-- JSON API (marcusolsson-json-datasource 1.3.23; frontend-only, ported from
-- src/datasource.ts, api.ts, detectFieldType.ts and parseValues.ts). The
-- plugin has no backend: Grafana's frontend fetches each target through the
-- datasource proxy and shapes the document into a frame itself, so Tern
-- does the same.
--
-- Request (requestJson, Api.cachedGet/_request): the method must be GET or
-- POST ("Invalid method <m>"). Every text (urlPath, param and header keys and
-- values, body, field names and paths) goes through templateSrv.replace with
-- the default format, then the macros $__unixEpochFrom(), $__unixEpochTo()
-- (epoch seconds) and $__isoFrom(), $__isoTo() (toISOString). The URL is the
-- instance URL (the datasource proxy) plus the path, runs of `/` collapsed to
-- one, then `?` (or `&` when the path has a query) and the parameters: the
-- target's non-empty keys first (duplicates allowed), then the pairs of
-- jsonData.queryParams (URLSearchParams), each key and value
-- encodeURIComponent'ed, in JavaScript object key order (array-index keys
-- first). isSafeURL then rejects `/..` at the end, `/../`, `/..?` and tabs in
-- the decoded URL ("URL path contains unsafe characters"). Headers are the
-- target's (an `Authorization` header travels as X-DS-Authorization, as
-- Grafana's backendSrv sends it); the body only goes with POST.
--
-- Response: Grafana's backendSrv parsing (JSON when the body parses, else
-- the text), its error messages (the body's `message`, else its `error`,
-- else the text body, else "Query error: <status> <reason>"), and a falsy
-- document is "Query returned empty data".
--
-- Shaping (doRequest): per field with a path, the JSONPath values
-- (lib/datasources/jsonpath.luau), the type given or detected
-- (detectFieldType: all null -> string; every other value a strict moment
-- ISO 8601 date-time with offset or a YYYY-MM-DD date -> time; all numbers
-- -> number; all booleans -> boolean; else string), values parsed for it
-- (parseValues: time strings through dayjs, local time without an offset;
-- time numbers all below 1e12 are seconds), the name given else the path's
-- last part. Fields of different lengths fail ("Fields have different
-- lengths"). One frame named after the refId, or one per value of
-- experimentalGroupByField (without that field, named after the value);
-- experimentalMetricField's field shows the frame name. Grafana's query()
-- waits for every target (Promise.all): one failed target fails the panel,
-- so the panel shows that error and no frames.
--
-- Query variables (metricFindQuery): the variable's query runs the same way;
-- options from the first frame, text from experimentalVariableTextField else
-- the first field, value from experimentalVariableValueField else the text
-- field.
--
-- Not reproduced: JSONata fields (evaluated by the jsonata library in the
-- browser, with dashboard variables bound: a ladder reason) and browser
-- (direct) access. cacheDurationSeconds is not honored: Tern queries on every
-- refresh (never more often than dashboard.min_refresh).
--
-- Secrets: jsonData.queryParams holds API keys (OpenWeatherMap's appid) and
-- lands in every request URL. Request paths stay in the job (memory only);
-- error texts lose URL query strings and every queryParams value.

local Env = require("../env")
local Frame = require("../frame/types")
local Interpolate = require("../dashboard/interpolate")
local JP = require("./jsonpath")
local Response = require("../source/response")
local TransportTypes = require("../transport/types")
local Types = require("./types")
local Url = require("../url")

type Env = Env.Env

local M = {}

M.TYPE = "marcusolsson-json-datasource"

M.JSONATA = "JSON API JSONata expressions run in the browser"
M.DIRECT = "JSON API datasources with browser (direct) access are queried by the browser"
M.EMPTY = "Query returned empty data"
M.LENGTHS = "Fields have different lengths"
M.UNSAFE = "URL path contains unsafe characters"

-- Go's http.StatusText (the reason phrase Grafana's proxy answers with).
local REASONS: { [number]: string } = {
	[400] = "Bad Request",
	[401] = "Unauthorized",
	[402] = "Payment Required",
	[403] = "Forbidden",
	[404] = "Not Found",
	[405] = "Method Not Allowed",
	[406] = "Not Acceptable",
	[408] = "Request Timeout",
	[409] = "Conflict",
	[410] = "Gone",
	[413] = "Request Entity Too Large",
	[414] = "Request URI Too Long",
	[415] = "Unsupported Media Type",
	[422] = "Unprocessable Entity",
	[429] = "Too Many Requests",
	[500] = "Internal Server Error",
	[501] = "Not Implemented",
	[502] = "Bad Gateway",
	[503] = "Service Unavailable",
	[504] = "Gateway Timeout",
}

-- Content types backendSrv parses as JSON (any other body: JSON when it
-- parses, else text).
local JSON_TYPES = table.freeze({
	["application/json"] = true,
	["application/json-patch+json"] = true,
	["application/merge-patch+json"] = true,
	["application/strategic-merge-patch+json"] = true,
})

-- Helpers -----------------------------------------------------------------------

local function str(env: Env, v: any): string?
	v = Env.value(env, v)
	return if type(v) == "string" then v else nil
end

-- What templateSrv.replace receives for a possibly missing text: "" for
-- null/undefined, String(v) otherwise.
local function text(env: Env, v: any): string
	v = Env.value(env, v)
	if v == nil then
		return ""
	elseif type(v) == "string" then
		return v
	elseif type(v) == "number" then
		return JP.numberString(v)
	elseif type(v) == "boolean" then
		return if v then "true" else "false"
	end
	return ""
end

local function jsTruthy(env: Env, v: any): boolean
	v = Env.value(env, v)
	return v ~= nil and v ~= false and v ~= "" and v ~= 0 and not (type(v) == "number" and v ~= v)
end

local function list(env: Env, v: any): { any }
	v = Env.value(env, v)
	return if type(v) == "table" then v else {}
end

-- `${v}` of a target value for messages.
local function show(env: Env, v: any): string
	v = Env.value(env, v)
	if v == nil then
		return "undefined"
	elseif type(v) == "table" then
		return "[object Object]"
	end
	return text(env, v)
end

-- The instance's proxy path; nil for browser (direct) access.
local function proxyPath(ds: Types.Datasource): string?
	local url = ds.url
	if url == nil or string.sub(url, 1, 1) ~= "/" then
		return nil
	end
	return "/api/datasources/proxy/uid/" .. Url.percentEncode(ds.uid)
end

local function isoMs(ms: number): string
	local s = math.floor(ms / 1000)
	return os.date("!%Y-%m-%dT%H:%M:%S", s) .. string.format(".%03dZ", math.floor(ms - s * 1000))
end

local function plain(s: string): string
	return (string.gsub(s, "%%", "%%%%"))
end

-- replaceMacros after templateSrv.replace.
local function interpolator(ctx: Types.DsContext): (string) -> string
	local from = string.format("%d", math.floor(ctx.from_ms / 1000))
	local to = string.format("%d", math.floor(ctx.to_ms / 1000))
	local isoFrom, isoTo = isoMs(ctx.from_ms), isoMs(ctx.to_ms)
	return function(s: string): string
		s = Interpolate.replace(s, ctx.scope)
		if string.find(s, "$__", 1, true) then
			s = string.gsub(s, "%$__unixEpochFrom%(%)", plain(from))
			s = string.gsub(s, "%$__unixEpochTo%(%)", plain(to))
			s = string.gsub(s, "%$__isoFrom%(%)", plain(isoFrom))
			s = string.gsub(s, "%$__isoTo%(%)", plain(isoTo))
		end
		return s
	end
end

-- encodeURIComponent.
local function encodeComponent(s: string): string
	return (
		string.gsub(s, "[^%w%-_%.!~%*'%(%)]", function(c: string): string
			return string.format("%%%02X", string.byte(c))
		end)
	)
end

-- Percent-decoding as URLSearchParams does it (`+` is a space; a bad escape
-- stays as written).
local function formDecode(s: string): string
	s = string.gsub(s, "+", " ")
	return (
		string.gsub(s, "%%(%x%x)", function(h: string): string
			return string.char(tonumber(h, 16) :: number)
		end)
	)
end

-- new URLSearchParams("?" + queryParams), as ordered pairs.
local function searchParams(qs: string): { { string } }
	if string.sub(qs, 1, 1) == "?" then
		qs = string.sub(qs, 2)
	end
	local out: { { string } } = {}
	for part in string.gmatch(qs, "[^&]+") do
		local eq = string.find(part, "=", 1, true)
		local name = if eq then string.sub(part, 1, eq - 1) else part
		local value = if eq then string.sub(part, eq + 1) else ""
		table.insert(out, { formDecode(name), formDecode(value) })
	end
	return out
end

-- decodeURIComponent; nil for "URI malformed".
local function decodeComponent(s: string): string?
	local bad = false
	local out = string.gsub(s, "%%(.?.?)", function(h: string): string
		if not string.match(h, "^%x%x$") then
			bad = true
			return ""
		end
		return string.char(tonumber(h, 16) :: number)
	end)
	if bad or utf8.len(out) == nil then
		return nil
	end
	return out
end

-- isSafeURL: nil when safe, else the error.
local function unsafe(url: string): string?
	local decoded = decodeComponent((string.gsub(url, "\\", "/")))
	if decoded == nil then
		return "URI malformed"
	end
	local u = decoded :: string
	if
		string.sub(u, -3) == "/.."
		or string.find(u, "/../", 1, true)
		or string.find(u, "/..?", 1, true)
		or string.find(u, "\t", 1, true)
	then
		return M.UNSAFE
	end
	return nil
end

-- Request ----------------------------------------------------------------------

type FieldSpec = { path: string, name: string, ftype: string? }

-- One target, ready to send: its request (or the error requestJson throws)
-- and the shaping it needs.
type Prepared = {
	ref_id: string,
	request: TransportTypes.Request?,
	error: string?,
	fields: { FieldSpec },
	group_by: string?,
	metric: string?,
}

-- The secrets of an instance: its queryParams values, raw and encoded.
local function secretsOf(ds: Types.Datasource, env: Env): { string }
	local out: { string } = {}
	local jd = ds.json_data
	local qp = if jd then str(env, jd.queryParams) else nil
	if qp then
		for _, pair in searchParams(qp :: string) do
			local v = pair[2]
			if #v >= 3 then
				table.insert(out, v)
				local enc = encodeComponent(v)
				if enc ~= v then
					table.insert(out, enc)
				end
			end
		end
	end
	return out
end

-- Registry.redact plus every secret value.
local function redact(message: string, secrets: { string }): string
	local out = string.gsub(message, "([%w%-%._~/%%:]+)%?[^%s\"'<>%)]+", "%1?...")
	for _, s in secrets do
		local start = 1
		while true do
			local i, j = string.find(out, s, start, true)
			if i == nil then
				break
			end
			out = string.sub(out, 1, (i :: number) - 1) .. "..." .. string.sub(out, (j :: number) + 1)
			start = (i :: number) + 3
		end
	end
	return out
end

local function buildUrl(base: string, path: string, params: { { string } }, queryParams: string?): string
	local url = string.gsub(base .. path, "/+", "/")
	-- paramsData: an object, so a later key replaces an earlier one's value
	-- in place, and array-index keys come first.
	local keys: { string } = {}
	local values: { [string]: string } = {}
	local function set(k: string, v: string)
		if values[k] == nil then
			table.insert(keys, k)
		end
		values[k] = v
	end
	local i = 0
	for _, p in params do
		if p[1] ~= "" then
			set(p[1] .. "__" .. i, p[2])
			i += 1
		end
	end
	for _, p in searchParams(queryParams or "") do
		set(p[1], p[2])
	end
	if #keys == 0 then
		return url
	end
	local parts = table.create(#keys)
	for n, k in JP.jsKeyOrder(keys) do
		parts[n] = encodeComponent((string.gsub(k, "__%d+$", ""))) .. "=" .. encodeComponent(values[k])
	end
	return url .. (if string.find(url, "?", 1, true) then "&" else "?") .. table.concat(parts, "&")
end

local function pairsOf(env: Env, v: any, interp: (string) -> string): { { string } }
	local out: { { string } } = {}
	for _, p in list(env, v) do
		if type(p) == "table" then
			table.insert(out, { interp(text(env, p[1])), interp(text(env, p[2])) })
		end
	end
	return out
end

local function isJsonata(env: Env, f: any): boolean
	return type(f) == "table" and str(env, f.language) == "jsonata" and jsTruthy(env, f.jsonPath)
end

local function prepare(target: Types.Target, ctx: Types.DsContext, env: Env, base: string): Prepared
	local interp = interpolator(ctx)
	local p: Prepared = {
		ref_id = str(env, target.refId) or "",
		fields = {},
		group_by = str(env, target.experimentalGroupByField),
		metric = str(env, target.experimentalMetricField),
	}
	for _, f in list(env, target.fields) do
		if type(f) == "table" and jsTruthy(env, f.jsonPath) then
			local ftype = Env.value(env, f.type)
			table.insert(p.fields, {
				path = interp(text(env, f.jsonPath)),
				name = interp(text(env, f.name)),
				ftype = if type(ftype) == "string" and ftype ~= "" then ftype else nil,
			})
		end
	end
	local method = Env.value(env, target.method)
	if method ~= "GET" and method ~= "POST" then
		p.error = "Invalid method " .. show(env, method)
		return p
	end
	local jd = ctx.ds.json_data
	local queryParams = if jd then str(env, jd.queryParams) else nil
	local url = buildUrl(base, interp(text(env, target.urlPath)), pairsOf(env, target.params, interp), queryParams)
	local bad = unsafe(url)
	if bad then
		p.error = bad
		return p
	end
	local headers: { [string]: string } = {}
	for _, h in pairsOf(env, target.headers, interp) do
		if h[1] ~= "" then
			headers[h[1]] = h[2]
		end
	end
	local auth = headers.Authorization
	if auth then
		headers["X-DS-Authorization"] = auth;
		(headers :: any).Authorization = nil
	end
	local hasType, hasAccept = false, false
	for k in headers do
		local lower = string.lower(k)
		hasType = hasType or lower == "content-type"
		hasAccept = hasAccept or lower == "accept"
	end
	if not hasAccept then
		headers.Accept = "application/json, text/plain, */*"
	end
	if method == "POST" and not hasType then
		headers["Content-Type"] = "application/json"
	end
	local body = interp(text(env, target.body))
	p.request = {
		method = method :: string,
		path = url,
		headers = headers,
		body = if method ~= "GET" and body ~= "" then body else nil,
	}
	return p
end

-- Response ---------------------------------------------------------------------

local function header(response: TransportTypes.Response, name: string): string?
	for k, v in (response.headers or {}) :: { [string]: string } do
		if string.lower(k) == name then
			return v
		end
	end
	return nil
end

-- backendSrv's response data, or the error the panel shows.
local function document(response: TransportTypes.Response?, env: Env): (any, string?)
	if response == nil then
		return nil, "the datasource did not answer"
	end
	local r = response :: TransportTypes.Response
	if r.failure or r.status == 0 then
		local _, err = Response.json(r, env, "JSON API")
		return nil, if err then err.message else "no response from the server"
	end
	local body = r.body or ""
	local doc: any
	local ctype = header(r, "content-type")
	if ctype and JSON_TYPES[string.lower(ctype)] then
		if header(r, "content-length") == "0" then
			doc = JP.object({}, {})
		else
			local v, err = JP.decode(body)
			if err then
				return nil, err
			end
			doc = v
		end
	else
		local v = JP.decode(body)
		doc = if v == nil then body else v
	end
	if r.status >= 200 and r.status < 300 then
		return doc, nil
	end
	local reason = REASONS[r.status] or ""
	-- processRequestError, then toDataQueryError.
	local message: any = nil
	local errorText: any = nil
	if type(doc) == "string" then
		message = if doc ~= "" then doc else reason
		errorText = reason
	elseif JP.isObject(doc) then
		local values = (doc :: JP.Object).values
		message, errorText = values.message, values.error
		if not JP.truthy(message) and type(errorText) == "string" then
			message = errorText
		end
	end
	if JP.truthy(message) and message ~= "Query data error" then
		return nil, JP.toString(message)
	elseif JP.truthy(errorText) then
		return nil, JP.toString(errorText)
	end
	return nil, string.format("Query error: %d %s", r.status, reason)
end

-- Field types and values ---------------------------------------------------------

local function daysInMonth(y: number, m: number): number
	if m == 2 then
		return if (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0 then 29 else 28
	end
	return if m == 4 or m == 6 or m == 9 or m == 11 then 30 else 31
end

local function daysFromCivil(y: number, m: number, d: number): number
	y = if m <= 2 then y - 1 else y
	local era = (if y >= 0 then y else y - 399) // 400
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

-- moment(v, [moment.defaultFormat, "YYYY-MM-DD"], true).isValid():
-- YYYY-MM-DDTHH:mm:ssZ (offset Z, ±hh, ±hhmm or ±hh:mm) or YYYY-MM-DD.
local function isIsoValid(v: any): boolean
	if type(v) ~= "string" then
		return false
	end
	local y, mo, d = string.match(v, "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	local h, mi, s, zone = nil, nil, nil, nil
	if y == nil then
		y, mo, d, h, mi, s, zone = string.match(v, "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.+)$")
		if y == nil then
			return false
		end
		local z = zone :: string
		if not (z == "Z" or z == "z" or string.match(z, "^[%+%-]%d%d$") or string.match(z, "^[%+%-]%d%d:?%d%d$")) then
			return false
		end
	end
	local yy, mm, dd = tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number
	if mm < 1 or mm > 12 or dd < 1 or dd > daysInMonth(yy, mm) then
		return false
	end
	if h then
		local hh, mn, ss = tonumber(h) :: number, tonumber(mi) :: number, tonumber(s) :: number
		if hh > 24 or mn > 59 or ss > 59 or (hh == 24 and (mn ~= 0 or ss ~= 0)) then
			return false
		end
	end
	return true
end

local function detectFieldType(values: { any }): string
	local allNull = true
	for _, v in values do
		if v ~= JP.NULL then
			allNull = false
			break
		end
	end
	if allNull then
		return "string"
	end
	local iso, numbers, booleans = true, true, true
	for _, v in values do
		if v ~= JP.NULL and not isIsoValid(v) then
			iso = false
		end
		numbers = numbers and type(v) == "number"
		booleans = booleans and type(v) == "boolean"
	end
	if iso then
		return "time"
	elseif numbers then
		return "number"
	elseif booleans then
		return "boolean"
	end
	return "string"
end

local NAN = 0 / 0

-- Epoch ms of a local date-time with JavaScript's Date overflow rules.
local function localMs(
	y: number,
	mo: number,
	d: number,
	h: number,
	mi: number,
	s: number,
	ms: number,
	offsetMin: number
): number
	local months = y * 12 + mo
	local yy = months // 12
	local mm = months % 12
	local days = daysFromCivil(yy, mm + 1, 1) + d - 1
	return days * 86400000 + h * 3600000 + mi * 60000 + s * 1000 + ms - offsetMin * 60000
end

-- new Date(string) for ISO 8601 forms (date-only is UTC, date-time without
-- an offset local); NaN for anything else.
local function dateParse(v: string, offsetMin: number): number
	local y, rest = string.match(v, "^(%d%d%d%d)(.*)$")
	if y == nil then
		return NAN
	end
	local mo, d, tail = "01", "01", rest :: string
	local m1, r1 = string.match(tail, "^%-(%d%d)(.*)$")
	if m1 then
		mo, tail = m1 :: string, r1 :: string
		local d1, r2 = string.match(tail, "^%-(%d%d)(.*)$")
		if d1 then
			d, tail = d1 :: string, r2 :: string
		end
	end
	local h, mi, s, frac = "0", "0", "0", ""
	local hasTime = false
	local th, tm, r3 = string.match(tail, "^T(%d%d):(%d%d)(.*)$")
	if th then
		hasTime = true
		h, mi, tail = th :: string, tm :: string, r3 :: string
		local ts, r4 = string.match(tail, "^:(%d%d)(.*)$")
		if ts then
			s, tail = ts :: string, r4 :: string
			local tf, r5 = string.match(tail, "^%.(%d+)(.*)$")
			if tf then
				frac, tail = tf :: string, r5 :: string
			end
		end
	end
	local offset = if hasTime then offsetMin else 0
	if tail == "Z" or tail == "z" then
		offset = 0
	elseif tail ~= "" then
		local sign, oh, om = string.match(tail, "^([%+%-])(%d%d):?(%d%d)$")
		if sign == nil then
			return NAN
		end
		offset = (tonumber(oh) :: number) * 60 + (tonumber(om) :: number)
		if sign == "-" then
			offset = -offset
		end
	end
	local yy, mm, dd = tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number
	local hh, mn, ss = tonumber(h) :: number, tonumber(mi) :: number, tonumber(s) :: number
	if mm < 1 or mm > 12 or dd < 1 or dd > daysInMonth(yy, mm) or hh > 24 or mn > 59 or ss > 59 then
		return NAN
	end
	local ms = tonumber(string.sub(frac .. "000", 1, 3)) :: number
	return localMs(yy, mm - 1, dd, hh, mn, ss, ms, offset :: number)
end

-- dayjs(v).valueOf() for a string.
local function dayjsMs(v: string, offsetMin: number): number
	if not string.match(v, "[Zz]$") then
		local y, mo, d, h, mi, s, ms =
			string.match(v, "^(%d%d%d%d)[%-/]?(%d?%d?)[%-/]?(%d?%d?)[Tt%s]*(%d?%d?):?(%d?%d?):?(%d?%d?)[%.:]?(%d*)$")
		if y then
			local yy = tonumber(y) :: number
			if yy >= 0 and yy <= 99 then
				yy += 1900
			end
			local month = if mo ~= "" then (tonumber(mo) :: number) - 1 else 0
			local day = if d ~= "" then tonumber(d) :: number else 1
			return localMs(
				yy,
				month,
				day,
				tonumber(h) or 0,
				tonumber(mi) or 0,
				tonumber(s) or 0,
				tonumber(string.sub(if ms == nil or ms == "" then "0" else ms, 1, 3)) :: number,
				offsetMin
			)
		end
	end
	return dateParse(v, offsetMin)
end

local function fail(message: string): never
	error({ json_api_error = message }, 0)
end

local function parseValues(values: { any }, ftype: string, env: Env): { any }
	local out = table.create(#values)
	if ftype == "time" then
		local strings, numbers = true, true
		for _, v in values do
			if JP.truthy(v) then
				strings = strings and type(v) == "string"
				numbers = numbers and type(v) == "number"
			end
		end
		local offset = env.local_offset_min or 0
		if strings then
			for i, v in values do
				local ms: any = v
				if type(v) == "string" then
					ms = dayjsMs(v, offset)
				elseif type(v) == "boolean" then
					ms = if v then 1 else 0
				end
				out[i] = if type(ms) == "number" and ms ~= ms then JP.NULL else ms
			end
			return out
		elseif numbers then
			local seconds = true
			for _, v in values do
				if JP.truthy(v) and v >= 1e12 then
					seconds = false
					break
				end
			end
			for i, v in values do
				out[i] = if seconds and type(v) == "number" then v * 1000 else v
			end
			return out
		end
		fail("Unsupported time property")
	elseif ftype == "string" then
		for i, v in values do
			if v == JP.NULL or type(v) == "string" then
				out[i] = v
			elseif JP.isArray(v) or JP.isObject(v) then
				out[i] = JP.stringify(v)
			else
				out[i] = JP.toString(v)
			end
		end
		return out
	elseif ftype == "number" then
		for i, v in values do
			if v == JP.NULL or type(v) == "number" then
				out[i] = v
			else
				local s = string.match(JP.toString(v), "^%s*(.-)$") :: string
				local sign, rest = string.match(s, "^([%+%-]?)(.*)$")
				local n: number = NAN
				if string.sub(rest :: string, 1, 8) == "Infinity" then
					n = if sign == "-" then -math.huge else math.huge
				else
					local num = string.match(s, "^[%+%-]?%d+%.?%d*[eE][%+%-]?%d+")
						or string.match(s, "^[%+%-]?%.%d+[eE][%+%-]?%d+")
						or string.match(s, "^[%+%-]?%d+%.?%d*")
						or string.match(s, "^[%+%-]?%.%d+")
					if num then
						n = tonumber(num) :: number
					end
				end
				out[i] = n
			end
		end
		return out
	elseif ftype == "boolean" then
		for i, v in values do
			if v == JP.NULL or type(v) == "boolean" then
				out[i] = v
			else
				local s = JP.toString(v)
				if s == "0" or s == "false" or s == "FALSE" or s == "False" then
					out[i] = false
				elseif s == "1" or s == "true" or s == "TRUE" or s == "True" then
					out[i] = true
				else
					fail("Found non-boolean values in a field of type boolean: " .. s)
				end
			end
		end
		return out
	end
	fail("Unsupported field type")
	return out
end

-- The last part of JSONPath.toPathArray(path) (a field's default name).
local function lastPart(path: string): string
	local parts = JP.toPathArray(path)
	return parts[#parts] or "undefined"
end

-- groupBy: a frame per distinct value of the field (first-seen order).
local function groupBy(frame: Frame.Frame, name: string): { Frame.Frame }
	local by: Frame.Field? = nil
	for _, f in frame.fields do
		if f.name == name then
			by = f
			break
		end
	end
	if by == nil then
		return { frame }
	end
	local g = by :: Frame.Field
	local seen: { [any]: boolean } = {}
	local distinct: { any } = {}
	for _, v in g.values do
		local key = if v ~= v then "NaN" else v
		if not seen[key] then
			seen[key] = true
			table.insert(distinct, v)
		end
	end
	local out: { Frame.Frame } = {}
	for _, value in distinct do
		local fields: { Frame.Field } = {}
		for _, f in frame.fields do
			if f.name ~= g.name then
				local values: { any } = {}
				for i, v in f.values do
					if g.values[i] == value then
						table.insert(values, v)
					end
				end
				table.insert(fields, { name = f.name, type = f.type, values = values })
			end
		end
		table.insert(out, {
			name = if value == JP.NULL then nil else JP.toString(value),
			refId = frame.refId,
			fields = fields,
		})
	end
	return out
end

local function shape(p: Prepared, doc: any, env: Env): { Frame.Frame }
	if not JP.truthy(doc) then
		fail(M.EMPTY)
	end
	local fields: { Frame.Field } = {}
	local length: number? = nil
	local mixed = false
	for _, spec in p.fields do
		local values, err = JP.query(spec.path, doc)
		if err then
			fail(err)
		end
		local vs = values or {}
		local ftype = spec.ftype or detectFieldType(vs)
		local typed = parseValues(vs, ftype, env)
		table.insert(fields, {
			name = if spec.name ~= "" then spec.name else lastPart(spec.path),
			type = ftype :: Frame.FieldType,
			values = typed,
		})
		if length and length ~= #typed then
			mixed = true
		end
		length = length or #typed
	end
	if mixed then
		fail(M.LENGTHS)
	end
	local frame: Frame.Frame = { name = p.ref_id, refId = p.ref_id, fields = fields }
	local frames: { Frame.Frame } = if p.group_by and p.group_by ~= ""
		then groupBy(frame, p.group_by :: string)
		else { frame }
	if p.metric and p.metric ~= "" then
		for _, f in frames do
			for _, field in f.fields do
				if field.name == p.metric then
					field.config = { displayName = f.name }
				end
			end
		end
	end
	return frames
end

local function shaped(p: Prepared, doc: any, env: Env): ({ Frame.Frame }?, string?)
	local ok, res = pcall(shape, p, doc, env)
	if ok then
		return res, nil
	end
	local e = res :: any
	if type(e) == "table" and e.json_api_error then
		return nil, e.json_api_error
	end
	error(e, 0)
end

-- Jobs --------------------------------------------------------------------------

type Job = {
	kind: "panel" | "variable",
	queries: { Prepared },
	secrets: { string },
	sent: boolean,
	-- Variables: the option text and value field names.
	text_field: string?,
	value_field: string?,
	-- Why the job cannot run (variables: JSONata, direct access).
	blocked: string?,
}

function M.blocker(target: Types.Target, ctx: Types.BlockerContext, env: Env): string?
	if proxyPath(ctx.ds) == nil then
		return M.DIRECT
	end
	for _, f in list(env, target.fields) do
		if isJsonata(env, f) then
			return M.JSONATA
		end
	end
	return nil
end

function M.start(targets: { Types.Target }, ctx: Types.DsContext, env: Env): Types.Job
	local base = proxyPath(ctx.ds) or ""
	local job: Job = { kind = "panel", queries = {}, secrets = secretsOf(ctx.ds, env), sent = false }
	for _, t in targets do
		if Env.value(env, t.hide) ~= true then
			table.insert(job.queries, prepare(t, ctx, env, base))
		end
	end
	return job :: any
end

function M.variable(query: any, ctx: Types.DsContext, env: Env): Types.Job
	local q: Types.Target = if type(query) == "table" then query else {}
	local base = proxyPath(ctx.ds)
	local job: Job = {
		kind = "variable",
		queries = {},
		secrets = secretsOf(ctx.ds, env),
		sent = false,
		text_field = str(env, q.experimentalVariableTextField),
		value_field = str(env, q.experimentalVariableValueField),
	}
	if base == nil then
		job.blocked = M.DIRECT
	else
		for _, f in list(env, q.fields) do
			if isJsonata(env, f) then
				job.blocked = M.JSONATA
			end
		end
	end
	if job.blocked == nil then
		table.insert(job.queries, prepare(q, ctx, env, base :: string))
	end
	return job :: any
end

-- String(v) of an option value (null: "").
local function optionText(v: any): string?
	if v == nil or v == JP.NULL then
		return nil
	end
	return JP.toString(v)
end

-- metricFindQuery's options from the frames.
local function options(job: Job, frames: { Frame.Frame }): ({ Types.Option }?, string?)
	local frame = frames[1]
	if frame == nil then
		return nil, "Cannot read properties of undefined (reading 'fields')"
	end
	if #frame.fields == 0 then
		return {}, nil
	end
	local function named(name: string?): Frame.Field?
		if name == nil then
			return nil
		end
		for _, f in frame.fields do
			if f.name == name then
				return f
			end
		end
		return nil
	end
	local textF = named(job.text_field) or frame.fields[1]
	local valueF = named(job.value_field) or textF
	local rows = 0
	for _, f in frame.fields do
		rows = math.max(rows, #f.values)
	end
	local out: { Types.Option } = {}
	for i = 1, rows do
		local t, v = optionText(textF.values[i]), optionText(valueF.values[i])
		table.insert(out, { text = t or v or "", value = v or t or "" })
	end
	return out, nil
end

local function tagOf(i: number): string
	return "q" .. i
end

local function step(job: Types.Job, answers: Types.Answers, env: Env): (Types.Job, { Types.DsRequest }, Types.Outcome?)
	local j = job :: Job
	if j.blocked then
		return job, {}, { error = j.blocked }
	end
	if not j.sent then
		j.sent = true
		local requests: { Types.DsRequest } = {}
		for i, p in j.queries do
			if p.error then
				-- requestJson throws before any answer can arrive.
				local message = redact(p.error :: string, j.secrets)
				if j.kind == "variable" then
					return job, {}, { error = message }
				end
				return job, {}, { data = { frames = {}, errors = { p.ref_id .. ": " .. message }, warnings = {} } }
			end
			table.insert(requests, { tag = tagOf(i), request = p.request :: TransportTypes.Request })
		end
		if #requests == 0 then
			return job,
				{},
				if j.kind == "variable"
					then { options = {} }
					else { data = { frames = {}, errors = {}, warnings = {} } }
		end
		return job, requests, nil
	end
	local frames: { Frame.Frame } = {}
	for i, p in j.queries do
		local doc, err = document(answers[tagOf(i)], env)
		local out: { Frame.Frame }? = nil
		if err == nil then
			out, err = shaped(p, doc, env)
		end
		if err then
			local message = redact(err :: string, j.secrets)
			if j.kind == "variable" then
				return job, {}, { error = message }
			end
			return job, {}, { data = { frames = {}, errors = { p.ref_id .. ": " .. message }, warnings = {} } }
		end
		for _, f in out :: { Frame.Frame } do
			table.insert(frames, f)
		end
	end
	if j.kind == "variable" then
		local opts, err = options(j, frames)
		if err then
			return job, {}, { error = err }
		end
		return job, {}, { options = opts }
	end
	return job, {}, { data = { frames = frames, errors = {}, warnings = {} } }
end

M.step = step

local module: Types.DsModule = {
	types = { M.TYPE },
	blocker = M.blocker,
	start = M.start,
	step = step,
	variable = M.variable,
}

return module
