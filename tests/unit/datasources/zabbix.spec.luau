--!strict
-- Zabbix (alexanderzobnin-zabbix-datasource), ported: the dashboard
-- tern-s4-zabbix must show in Tern what Grafana's browser builds. Metrics
-- targets go to /api/ds/query and get the plugin's browser post-processing
-- (Alias functions, Zabbix units, the wide merge); trigger counts and problems
-- are the browser's Zabbix API chains. Every request is answered from what
-- the dev stack's Grafana 11, 12 and 13 recorded for exactly that request
-- (tests/lib/zabbix.luau).
local Fixtures = require("../../lib/fixtures")
local Support = require("../../lib/support")
local Zabbix = require("../../../plugin/lib/datasources/zabbix")
local ZabbixApi = require("../../../plugin/lib/datasources/zabbix_api")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local Z = require("../../lib/zabbix")
local env = Z.env
local mod: any = Zabbix
local VERSIONS, DS, canon, panel, ctx, run = Z.VERSIONS, Z.DS, Z.canon, Z.panel, Z.ctx, Z.run

local function data(outcome: any): any
	assert(outcome.data, outcome.error)
	return outcome.data
end

-- A frame's value fields as name -> first value.
local function counts(frame: any): { [string]: any }
	local out: { [string]: any } = {}
	for _, f in frame.fields do
		if f.type ~= "time" then
			out[f.name] = f.values[1]
		end
	end
	return out
end

local function field(frame: any, name: string): any
	for _, f in frame.fields do
		if f.name == name then
			return f
		end
	end
	error("no field " .. name)
end

local function withFunctions(target: any, fns: { any }): any
	local c = table.clone(target)
	c.functions = json.array(fns)
	return c
end

for _, version in VERSIONS do
	describe("Zabbix on Grafana " .. version, function()
		it("counts the unacknowledged problems of the stat panel as Grafana's render shows (3)", function()
			local outcome, rounds = run(version, panel(version, 5).targets)
			local frames = data(outcome).frames
			expect(#frames).toBe(1)
			expect(frames[1].fields[1].type).toBe("time")
			-- One value field named after the target (`Count <refId>`).
			expect(frames[1].name).toBe("Count A")
			expect(counts(frames[1])).toEqual({ Value = 3 })
			-- apiinfo.version comes first: every call's params depend on the Zabbix version (7.0 here).
			expect(rounds[1]).toEqual({ "apiinfo.version" })
		end)

		it("counts problems per severity for the piechart, one wide frame of six counts", function()
			local outcome = run(version, panel(version, 6).targets)
			local frames = data(outcome).frames
			expect(#frames).toBe(1)
			expect(frames[1].name).toBe("wide")
			expect(counts(frames[1])).toEqual({
				-- Grafana's legend names: "Count " and the target's refId.
				["Count Not Classified"] = 4,
				-- Its target has an empty trigger filter, which matches no problem name.
				["Count Information"] = 0,
				["Count Warning"] = 1,
				["Count Average"] = 1,
				["Count High"] = 1,
				["Count Disaster"] = 1,
			})
		end)

		it("lists the problems panel's rows newest first with severities and tags", function()
			local outcome = run(version, panel(version, 7).targets)
			local frames = data(outcome).frames
			local rows: { string } = {}
			for _, f in frames do
				for _, p in f.fields[1].values do
					local tags: { string } = {}
					for _, tag in p.tags or {} do
						table.insert(tags, tag.tag .. ":" .. tag.value)
					end
					table.insert(
						rows,
						string.format("%s|%s|%s|%s", p.eventid, p.severity, p.description, table.concat(tags, ","))
					)
				end
			end
			-- Target B (tag Priority:1) then target A (severities, limit 5), as the browser joins them.
			expect(rows[1]).toBe(
				"27|5|Transit nni-edge-ord down|Priority:1,description:NNI-ACME-ORD: Chicago transit,component:network"
			)
			expect(rows[2]).toBe(
				"26|4|Transit nni-edge-dfw saturated|Priority:1,description:NNI-ACME-DFW: Dallas transit,component:network"
			)
			expect(#rows > 2).toBe(true)
		end)

		it("mirrors sent traffic with the backend's scale(-1) and merges both series into one wide frame", function()
			local p = panel(version, 1)
			local outcome, rounds = run(version, p.targets, "zabbix_ds_query_1")
			expect(rounds).toEqual({ { "ds/query" } })
			local frames = data(outcome).frames
			expect(#frames).toBe(1)
			local wide = frames[1]
			expect(wide.name).toBe("wide")
			expect(#wide.fields).toBe(3)
			local rx = field(wide, "Interface eth0(NNI-ACME-DFW: Dallas transit): Bits received")
			local tx = field(wide, "Interface eth0(NNI-ACME-DFW: Dallas transit): Bits sent")
			-- Zabbix unit bps -> Grafana bps on both value fields.
			expect(rx.config.unit).toBe("bps")
			expect(tx.config.unit).toBe("bps")
			local negative = false
			for _, v in tx.values do
				if type(v) == "number" and v < 0 then
					negative = true
				end
			end
			expect(negative).toBe(true)
		end)

		it("converts Zabbix units: % to percent 0..100, B to bytes", function()
			local cpu = data((run(version, panel(version, 3).targets, "zabbix_ds_query_3"))).frames
			for _, f in cpu[1].fields do
				if f.type ~= "time" then
					expect(f.config.unit).toBe("percent")
					expect(f.config.min).toBe(0)
					expect(f.config.max).toBe(100)
				end
			end
			local mem = data((run(version, panel(version, 4).targets, "zabbix_ds_query_4"))).frames
			for _, f in mem[1].fields do
				if f.type ~= "time" then
					expect(f.config.unit).toBe("bytes")
				end
			end
		end)

		it("sends the metrics targets as the plugin's frontend does", function()
			for _, pid in { 1, 3, 4 } do
				local sent: any = nil
				mod.step(mod.start(panel(version, pid).targets, ctx(), env), {}, env)
				local _, reqs = mod.step(mod.start(panel(version, pid).targets, ctx(), env), {}, env)
				sent = json.decode(reqs[1].request.body)
				local want =
					json.decode(Fixtures.read("grafana/" .. version .. "/zabbix_ds_query_" .. pid .. ".request.json"))
				expect(#sent.queries).toBe(#want.queries)
				for i, q in sent.queries do
					local w = want.queries[i]
					for _, k in { "intervalMs", "maxDataPoints", "datasource" } do
						q[k] = nil
						w[k] = nil
					end
					local differ: { string } = {}
					for k in w do
						if canon(q[k]) ~= canon(w[k]) then
							table.insert(differ, k .. " sent " .. canon(q[k]) .. " recorded " .. canon(w[k]))
						end
					end
					for k in q do
						-- interpolateVariablesInQueries always sets the interpolated filters; the dashboard JSON
						-- the capture sent has no empty ones.
						local filler = (
							k == "slaFilter"
							or k == "itServiceFilter"
							or k == "textFilter"
							or k == "itemids"
						) and q[k] == ""
						if w[k] == nil and not filler then
							table.insert(differ, k .. " sent " .. canon(q[k]) .. " not recorded")
						end
					end
					expect(differ).toEqual({})
				end
			end
		end)
	end)
end

describe("Zabbix Alias functions", function()
	local version = "12.4.12"
	local p = panel(version, 3)

	it("setAlias names the series from its __zbx_* scoped variables", function()
		local tg = withFunctions(p.targets[1], {
			{ def = { name = "setAlias", category = "Alias" }, params = { "$__zbx_host_name CPU" } },
		})
		local frames = data((run(version, { tg }, "zabbix_ds_query_3"))).frames
		local names: { string } = {}
		for _, f in frames[1].fields do
			if f.type ~= "time" then
				table.insert(names, f.name)
			end
		end
		table.sort(names)
		expect(names[1]).toBe("nni-edge-dfw CPU")
	end)

	it("replaceAlias rewrites the frame name with a regex", function()
		local tg = withFunctions(p.targets[1], {
			{ def = { name = "replaceAlias", category = "Alias" }, params = { "/^(.*): CPU utilization$/", "$1 cpu" } },
		})
		local frames = data((run(version, { tg }, "zabbix_ds_query_3"))).frames
		local names: { string } = {}
		for _, f in frames[1].fields do
			if f.type ~= "time" then
				table.insert(names, f.name)
			end
		end
		table.sort(names)
		expect(names[1]).toBe("nni-edge-dfw cpu")
	end)

	it("setAliasByRegex keeps the first match of the display name", function()
		local tg = withFunctions(p.targets[1], {
			{ def = { name = "setAliasByRegex", category = "Alias" }, params = { "nni-edge-[a-z]+" } },
		})
		local frames = data((run(version, { tg }, "zabbix_ds_query_3"))).frames
		local names: { string } = {}
		for _, f in frames[1].fields do
			if f.type ~= "time" then
				table.insert(names, f.name)
			end
		end
		table.sort(names)
		expect(names[1]).toBe("nni-edge-dfw")
	end)
end)

describe("Zabbix errors", function()
	local version = "12.4.12"

	it("shows a downstream failure of /api/ds/query per target, as Grafana's panel does", function()
		-- The shape Grafana answers when the Zabbix API behind the backend fails (seen on a live stack).
		local body = json.encode({
			results = {
				A = {
					error = "request failed, status: 500 Internal Server Error",
					errorSource = "downstream",
					status = 500,
					frames = json.array({}),
				},
				B = {
					error = "request failed, status: 500 Internal Server Error",
					errorSource = "downstream",
					status = 500,
					frames = json.array({}),
				},
			},
		})
		local outcome = run(version, panel(version, 1).targets, Support.body(body, 500))
		local d = data(outcome)
		expect(#d.frames).toBe(0)
		expect(d.errors).toEqual({
			"A: request failed, status: 500 Internal Server Error",
			"B: request failed, status: 500 Internal Server Error",
		})
	end)

	it("fails the whole triggers query with the Zabbix API's own message", function()
		local outcome = run(version, panel(version, 5).targets, nil, {
			["problem.get"] = Support.response("grafana/" .. version .. "/zabbix_error_invalid_params.json", 500),
		})
		expect(outcome.data).toBeNil()
		expect(type(outcome.error)).toBe("string")
		expect(string.find(outcome.error, "Invalid params", 1, true) ~= nil).toBe(true)
	end)
end)

describe("Zabbix targets kept on Grafana", function()
	local function reason(target: { [string]: any }, ds: any?): string?
		return mod.blocker(target, { scope = {}, datasources = { ds or DS }, ds = ds or DS }, env)
	end

	it("names the query modes and settings the browser plugin owns", function()
		expect(reason({ queryType = "0" })).toBeNil()
		expect(reason({ queryType = "4", countTriggersBy = "problems" })).toBeNil()
		expect(reason({ queryType = "1" })).toBe("Zabbix IT services queries are not reproduced")
		expect(reason({ queryType = "2" })).toBe("Zabbix text queries are not reproduced")
		expect(reason({ queryType = "6", schema = 13 })).toBe("Zabbix user macro queries are not reproduced")
		expect(reason({ queryType = "4", countTriggersBy = "items" })).toBe(
			"Zabbix trigger counts by items are not reproduced"
		)
		-- Schema < 11: the old "count triggers by items" mode 6.
		expect(reason({ mode = 6, schema = 10 })).toBe("Zabbix trigger counts by items are not reproduced")
		expect(reason({ queryType = "5", options = { fetchHistoricalItemValue = true } })).toBe(
			"Zabbix problems with item values at problem time (fetchHistoricalItemValue) are not reproduced"
		)
		expect(reason({ fromAnnotations = true })).toBe("Zabbix annotation queries run in Grafana's browser")
		local db: any = table.clone(DS)
		db.json_data = { dbConnectionEnable = true }
		expect(reason({ queryType = "0" }, db)).toBe(
			"Zabbix reads history through a direct database connection (dbConnectionEnable) in the browser"
		)
		-- A hidden target is never run, so it blocks nothing.
		expect(reason({ queryType = "1", hide = true })).toBeNil()
	end)
end)

describe("Zabbix requests by version", function()
	it("asks 7.0 for host groups with_hosts and selectHostGroups, older versions with the old keys", function()
		local function firstCall(version: string, method: string): any
			local c = ZabbixApi.calls(version, {}, env)
			ZabbixApi.run(function(): any
				return ZabbixApi.groups(c, "/.*/")
			end)
			for _, call in c.wanted do
				if call.method == method then
					return call.params
				end
			end
			return nil
		end
		local new = firstCall("7.0.25", "hostgroup.get")
		expect(new.with_hosts).toBe(true)
		local old = firstCall("5.0.0", "hostgroup.get")
		expect(old.with_hosts).toBeNil()
		expect(old.real_hosts).toBe(true)
	end)
end)

return nil
