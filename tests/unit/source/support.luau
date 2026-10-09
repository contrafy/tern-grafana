--!strict
-- Recorded exchanges as transport Responses (status from MANIFEST.tsv, so a
-- spec never restates what the server answered) and the routes the source
-- modules are called with.
local Fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")

local M = {}

M.env = { now_ms = 0, decode = json.decode, encode = json.encode, null = json.null } :: any

-- The capture window every list/range fixture used (seconds).
M.START = 1791576998
M.END = 1791577898

type Row = { method: string, url: string, status: number }

local rows: { [string]: Row }? = nil

function M.row(path: string): Row
	if rows == nil then
		local parsed: { [string]: Row } = {}
		for line in string.gmatch(Fixtures.read("MANIFEST.tsv"), "[^\n]+") do
			local cols = string.split(line, "\t")
			local status = tonumber(cols[4])
			if status then
				parsed[cols[1]] = { method = cols[2], url = cols[3], status = status }
			end
		end
		rows = parsed
	end
	local row = (rows :: { [string]: Row })[path]
	assert(row, "no MANIFEST row for " .. path)
	return row
end

function M.response(path: string): any
	return {
		status = M.row(path).status,
		headers = { ["Content-Type"] = "application/json" },
		body = Fixtures.read(path),
		timed_out = false,
	}
end

local function endpoint(url: string): any
	return { url = url, auth = { type = "none" }, headers = {}, path_prefix = "", timeout_ms = 15000 }
end

M.direct = {
	context = "lab",
	signal = "metrics",
	via = "direct",
	endpoint_name = "prometheus",
	endpoint = endpoint("http://127.0.0.1:9090"),
} :: any

M.datasource = {
	context = "lab",
	signal = "metrics",
	via = "datasource",
	endpoint_name = "grafana",
	endpoint = endpoint("http://127.0.0.1:3000"),
	datasource_uid = "prom3",
} :: any

M.grafana = {
	context = "lab",
	signal = "dashboards",
	via = "grafana",
	endpoint_name = "grafana",
	endpoint = endpoint("http://127.0.0.1:3000"),
} :: any

return M
