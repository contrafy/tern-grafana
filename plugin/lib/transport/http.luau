--!strict
-- URL building and header layering for a request against an endpoint.

local ConfigTypes = require("../config/types")
local Types = require("./types")

type Endpoint = ConfigTypes.Endpoint
type Request = Types.Request

local M = {}

-- RFC 3986 percent-encoding of every byte outside the unreserved set; usable
-- for query keys, values and single path segments.
function M.escape(s: string): string
	return (
		string.gsub(s, "[^%w%-._~]", function(c: string): string
			return string.format("%%%02X", string.byte(c))
		end)
	)
end

function M.url(endpoint: Endpoint, request: Request): string
	local base = string.gsub(endpoint.url, "/+$", "")
	local prefix = string.gsub(string.gsub(endpoint.path_prefix, "^/+", ""), "/+$", "")
	local path = string.gsub(request.path, "^/+", "")
	local out = base .. (if prefix == "" then "" else "/" .. prefix) .. "/" .. path
	local query = request.query
	if query and #query > 0 then
		local parts = table.create(#query)
		for i, pair in query do
			parts[i] = M.escape(pair[1]) .. "=" .. M.escape(pair[2])
		end
		out ..= (if string.find(path, "?", 1, true) then "&" else "?") .. table.concat(parts, "&")
	end
	return out
end

local function put(out: { [string]: string }, name: string, value: string)
	local lower = string.lower(name)
	for existing in out do
		if string.lower(existing) == lower then
			out[existing] = nil
		end
	end
	out[name] = value
end

-- Endpoint headers, Grafana's org, the request's own, then auth headers; a
-- later layer replaces an earlier header of the same name in any case.
function M.headers(endpoint: Endpoint, request: Request, secret_headers: { [string]: string }): { [string]: string }
	local out: { [string]: string } = {}
	for name, value in endpoint.headers do
		put(out, name, value)
	end
	if endpoint.org_id then
		put(out, "X-Grafana-Org-Id", tostring(endpoint.org_id))
	end
	if request.headers then
		for name, value in request.headers do
			put(out, name, value)
		end
	end
	for name, value in secret_headers do
		put(out, name, value)
	end
	return out
end

return M
