--!strict
-- The Zabbix datasource against what the dev stack recorded: every Zabbix API
-- request is answered from the capture of exactly that request
-- (scripts/fixtures/capture.sh capture_zabbix), so a request that differs
-- from the browser plugin's fails the spec that sent it.
local Fixtures = require("./fixtures")
local Support = require("./support")
local Zabbix = require("../../plugin/lib/datasources/zabbix")
local ZabbixApi = require("../../plugin/lib/datasources/zabbix_api")
local json = require("./json")
local t = require("./test")
local expect = t.expect

local M = {}

local env = Support.env()
env.array = json.array
M.env = env
local mod: any = Zabbix

local VERSIONS = { "11.6.16", "12.4.12", "13.3.1" }
local API = ZabbixApi.path("zabbix")

-- JSON with sorted keys: equal requests compare equal whatever the key order.
local function canon(v: any): string
	if type(v) ~= "table" then
		return json.encode(v)
	end
	if getmetatable(v :: any) ~= nil or #v > 0 then
		local out = {}
		for i, x in v do
			out[i] = canon(x)
		end
		return "[" .. table.concat(out, ",") .. "]"
	end
	local keys: { string } = {}
	for k in v do
		table.insert(keys, k)
	end
	table.sort(keys)
	local out = {}
	for _, k in keys do
		table.insert(out, json.encode(k) .. ":" .. canon(v[k]))
	end
	return "{" .. table.concat(out, ",") .. "}"
end

-- The recorded Zabbix API exchanges of one Grafana: request -> response path.
type Exchange = { path: string, status: number }
local recorded: { [string]: { [string]: Exchange } } = {}
local function exchanges(version: string): { [string]: Exchange }
	local cached = recorded[version]
	if cached then
		return cached
	end
	local out: { [string]: Exchange } = {}
	for line in string.gmatch(Fixtures.read("MANIFEST.tsv"), "[^\n]+") do
		local cols = string.split(line, "\t")
		local path, req = cols[1], cols[7]
		if
			string.find(path, "grafana/" .. version .. "/zabbix_", 1, true) == 1
			and cols[3] == API
			and req ~= nil
			and req ~= "-"
		then
			out[canon(json.decode(Fixtures.read(req)))] = { path = path, status = tonumber(cols[4]) :: number }
		end
	end
	recorded[version] = out
	return out
end

local function dashboard(version: string): any
	return json.decode(Fixtures.read("grafana/" .. version .. "/dashboard_tern_s4_zabbix.json")).dashboard
end

local function panel(version: string, id: number): any
	for _, p in dashboard(version).panels do
		if p.id == id then
			return p
		end
	end
	error("no panel " .. id)
end

local DS = { uid = "zabbix", name = "Zabbix", type = Zabbix.types[1], is_default = false }

local function ctx(): any
	return {
		scope = {},
		from_ms = 1794250800000 - 6 * 3600000,
		to_ms = 1794250800000,
		interval_ms = 30000,
		max_points = 1000,
		now_ms = 1794250800000,
		datasources = { DS },
		ds = DS,
		grafana_major = 12,
	}
end

-- Runs the targets to their outcome against what `version` recorded. `dsq`
-- is the recorded /api/ds/query answer (or a response) for metrics targets;
-- `over` answers chosen Zabbix API methods. Returns the outcome and the
-- methods called, round by round.
local function run(version: string, targets: { any }, dsq: any?, over: { [string]: any }?): (any, { { string } })
	local rounds: { { string } } = {}
	local job, reqs, outcome = mod.step(mod.start(targets, ctx(), env), {}, env)
	while outcome == nil do
		assert(#rounds < 12, "too many rounds")
		assert(#reqs > 0, "a job without requests or outcome")
		local round: { string } = {}
		local answers: { [string]: any } = {}
		for _, r in reqs do
			local req = r.request
			if req.path == "/api/ds/query" then
				table.insert(round, "ds/query")
				answers[r.tag] = if type(dsq) == "string"
					then Support.response("grafana/" .. version .. "/" .. dsq .. ".json")
					else assert(dsq, "unexpected /api/ds/query")
			else
				expect(req.path).toBe(API)
				local body = json.decode(req.body)
				table.insert(round, body.method)
				local answer = over and over[body.method]
				if answer == nil then
					local ex = exchanges(version)[canon(body)]
					assert(ex, "not recorded on " .. version .. ": " .. req.body)
					answer = Support.response(ex.path, ex.status)
				end
				answers[r.tag] = answer
			end
		end
		table.insert(rounds, round)
		job, reqs, outcome = mod.step(job, answers, env)
	end
	return outcome, rounds
end

M.VERSIONS = VERSIONS
M.API = API
M.DS = DS
M.canon = canon
M.panel = panel
M.ctx = ctx
M.run = run

return M
