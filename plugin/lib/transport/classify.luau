--!strict
-- Maps a transport response to a QueryError (nil on 2xx), keeping the
-- server's own explanation when the body carries one.

local Types = require("./types")

type Response = Types.Response
type QueryError = Types.QueryError

local M = {}

local MAX_DETAIL = 300

local function clip(s: string): string
	if #s > MAX_DETAIL then
		return string.sub(s, 1, MAX_DETAIL) .. "..."
	end
	return s
end

local function nonEmpty(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

-- Prometheus `{status:"error", errorType, error}`, Grafana `{message}`,
-- Grafana /api/ds/query `{results: {<refId>: {error}}}` (first refId), a
-- JSON string (Alertmanager), else the first line of a non-HTML text body.
local function detail(body: string, decode: (string) -> any): string?
	local ok, doc = pcall(decode, body)
	if ok and type(doc) == "string" then
		return nonEmpty(doc)
	elseif ok and type(doc) == "table" then
		local promError = nonEmpty(doc.error)
		if promError then
			local errorType = nonEmpty(doc.errorType)
			return if errorType then errorType .. ": " .. promError else promError
		end
		local message = nonEmpty(doc.message)
		if message then
			return message
		end
		if type(doc.results) == "table" then
			local refs: { string } = {}
			for ref, result in doc.results do
				if type(ref) == "string" and type(result) == "table" and nonEmpty(result.error) then
					table.insert(refs, ref)
				end
			end
			table.sort(refs)
			if refs[1] then
				return refs[1] .. ": " .. doc.results[refs[1]].error
			end
		end
		return nil
	end
	local line = string.match(body, "^%s*([^\r\n]+)")
	if line == nil or string.sub(line, 1, 1) == "<" then
		return nil
	end
	return (string.gsub(line, "%s+$", ""))
end

local function isTls(err: string): boolean
	local lower = string.lower(err)
	return string.find(lower, "certificate", 1, true) ~= nil
		or string.find(lower, "ssl", 1, true) ~= nil
		or string.find(lower, "handshake", 1, true) ~= nil
end

function M.classify(response: Response, decode: (string) -> any): QueryError?
	if response.failure then
		return response.failure
	end
	local status = response.status
	if status == 0 then
		local err = response.error
		if response.timed_out then
			return {
				kind = "timeout",
				message = string.format(
					"the request timed out%s; try a shorter range or raise timeout_ms",
					if err then " (" .. err .. ")" else ""
				),
			}
		elseif err == nil or err == "" then
			return { kind = "network", message = "no response from the server" }
		elseif string.find(err, "larger than request limit", 1, true) then
			return {
				kind = "query",
				message = "the response is larger than 16 MiB; narrow the query (shorter range, larger step or fewer series)",
			}
		elseif isTls(err) then
			return {
				kind = "network",
				message = "TLS verification failed: "
					.. err
					.. "; set tls.ca_file for a private CA (or tls.insecure for a lab)",
			}
		end
		return { kind = "network", message = err }
	end
	if status >= 200 and status < 300 then
		return nil
	end
	local d = detail(response.body, decode)
	local suffix = if d then ": " .. clip(d) else ""
	if status == 401 then
		return { kind = "auth", status = status, message = "authentication failed (HTTP 401)" .. suffix }
	elseif status == 403 then
		return { kind = "auth", status = status, message = "permission denied (HTTP 403)" .. suffix }
	end
	return { kind = "http", status = status, message = string.format("HTTP %d%s", status, suffix) }
end

return M
