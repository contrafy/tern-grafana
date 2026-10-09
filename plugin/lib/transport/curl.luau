--!strict
-- The curl transport for endpoints with TLS options tern.fetch lacks. Headers
-- and the body travel in a curl config on stdin (`--config -`): argv is
-- readable by every local user, stdin is not. The response status follows the
-- body on a marker line written by `--write-out`.

local Auth = require("../auth/auth")
local ConfigTypes = require("../config/types")
local Http = require("./http")
local Types = require("./types")

type Endpoint = ConfigTypes.Endpoint
type Request = Types.Request
type Response = Types.Response

export type CurlPlan = {
	argv: { string },
	stdin: string,
	-- Process deadline: curl's own --max-time plus a grace period.
	timeout_ms: number,
}

local M = {}

M.MARKER = "__tern_grafana_status__"
M.GRACE_MS = 5000

local CURL_TIMEOUT_EXIT = 28

function M.needsCurl(endpoint: Endpoint): boolean
	local tls = endpoint.tls
	if tls == nil then
		return false
	end
	return tls.ca_file ~= nil or tls.cert_file ~= nil or tls.key_file ~= nil or tls.insecure == true
end

local CONFIG_ESCAPES: { [string]: string } = {
	["\\"] = "\\\\",
	['"'] = '\\"',
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local function quote(s: string): string
	return '"' .. string.gsub(s, '[\\"\n\r\t]', CONFIG_ESCAPES) .. '"'
end

local function seconds(ms: number): string
	return string.format("%g", ms / 1000)
end

function M.curlPlan(
	endpoint: Endpoint,
	request: Request,
	headers: { [string]: string },
	home: string?
): (CurlPlan?, string?)
	local argv = {
		"curl",
		"--disable",
		"--silent",
		"--show-error",
		"--location",
		"--globoff",
		"--max-time",
		seconds(endpoint.timeout_ms),
		"--request",
		string.upper(request.method),
		"--config",
		"-",
		"--write-out",
		"\\n" .. M.MARKER .. " %{http_code} %{content_type}\\n",
	}
	local tls = endpoint.tls
	if tls then
		for _, opt in { { "ca_file", "--cacert" }, { "cert_file", "--cert" }, { "key_file", "--key" } } do
			local raw: string? = (tls :: any)[opt[1]]
			if raw then
				local path, err = Auth.expandHome(raw, home)
				if path == nil then
					return nil, string.format("tls.%s %s: %s", opt[1], raw, err or "")
				end
				table.insert(argv, opt[2])
				table.insert(argv, path)
			end
		end
		if tls.insecure then
			table.insert(argv, "--insecure")
		end
	end
	table.insert(argv, "--url")
	table.insert(argv, Http.url(endpoint, request))

	local names: { string } = {}
	for name in headers do
		table.insert(names, name)
	end
	table.sort(names, function(a: string, b: string): boolean
		return string.lower(a) < string.lower(b)
	end)
	local lines: { string } = {}
	for _, name in names do
		local value = headers[name]
		if string.find(name, "[\r\n]") or string.find(value, "[\r\n]") then
			return nil, string.format("header %s contains a line break", (string.gsub(name, "[\r\n]", "")))
		end
		table.insert(lines, "header = " .. quote(name .. ": " .. value) .. "\n")
	end
	if request.body then
		-- data-raw: a leading @ is data, not a file to read.
		table.insert(lines, "data-raw = " .. quote(request.body) .. "\n")
	end
	return { argv = argv, stdin = table.concat(lines), timeout_ms = endpoint.timeout_ms + M.GRACE_MS }, nil
end

local function failed(message: string, timed_out: boolean): Response
	return { status = 0, headers = {}, body = "", error = message, timed_out = timed_out }
end

local function firstLine(s: string): string?
	local line = string.match(s, "^%s*([^\r\n]+)")
	return if line then (string.gsub(line, "%s+$", "")) else nil
end

-- `status`, `stderr` and `timed_out` are the curl process's.
function M.parseCurl(stdout: string, status: number, stderr: string?, timed_out: boolean?): Response
	if timed_out then
		return failed("curl was stopped after its time limit", true)
	end
	if status ~= 0 then
		local message = firstLine(stderr or "") or string.format("curl exited with status %d", status)
		return failed(message, status == CURL_TIMEOUT_EXIT)
	end
	local needle = "\n" .. M.MARKER .. " "
	local at: number? = nil
	local from = 1
	while true do
		local found = string.find(stdout, needle, from, true)
		if not found then
			break
		end
		at = found
		from = found + 1
	end
	if at == nil then
		return failed("curl output had no status line", false)
	end
	local code, ctype = string.match(string.sub(stdout, at + #needle), "^(%d+) ([^\n]*)")
	local http = tonumber(code)
	if http == nil or http == 0 then
		return failed("curl output had no status line", false)
	end
	local headers: { [string]: string } = {}
	if ctype and ctype ~= "" then
		headers["content-type"] = ctype
	end
	return { status = http, headers = headers, body = string.sub(stdout, 1, at - 1), timed_out = false }
end

return M
