--!strict
-- Datasource modules inside the Dashboard block. A frontend datasource's
-- job runs its request rounds next to the panel's /api/ds/query request,
-- and the panel shows once every part answered, frames in target order; an
-- answer to a superseded query never lands. Query variables of a module run
-- the same way. Grafana Incident end to end: All goes out as `$__all`, a
-- specific selection as Grafana of that version sends it (a `severity`
-- variable fails on Grafana 12+ exactly as in Grafana). Datasource URLs and
-- settings (API keys) stay out of everything the block saves.
local Advance = require("../../../plugin/lib/dashboard/advance")
local DsRegistry = require("../../../plugin/lib/datasources/registry")
local Keys = require("../../lib/keys")
local Queries = require("../../../plugin/lib/dashboard/queries")
local S = require("./support")
local State = require("../../../plugin/lib/dashboard/state")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local PROXY = "test-proxy-datasource"

-- Two request rounds per target group, then one frame per target named by
-- the answers ("fail" as the second answer fails every target).
DsRegistry.register({
	types = { PROXY },
	start = function(targets: { any }, ctx: any, _env: any): any
		local refIds = {}
		for i, target in targets do
			refIds[i] = target.refId
		end
		return { ref_ids = refIds, base = DsRegistry.proxyPath(ctx.ds), round = 0, path = targets[1].path }
	end,
	step = function(job: any, answers: any, _env: any): (any, { any }, any)
		job.round += 1
		if job.round == 1 then
			return job, { { tag = "first", request = { method = "GET", path = job.base .. job.path } } }, nil
		elseif job.round == 2 then
			job.first = answers.first.body
			return job, { { tag = "second", request = { method = "GET", path = job.base .. "/more" } } }, nil
		end
		local second = answers.second.body
		if second == "fail" then
			local errors = {}
			for _, refId in job.ref_ids do
				table.insert(errors, refId .. ": the API said no")
			end
			return job, {}, { data = { frames = {}, errors = errors, warnings = {} } }
		end
		local frames = {}
		for _, refId in job.ref_ids do
			table.insert(frames, {
				name = job.first .. "+" .. second,
				refId = refId,
				fields = { { name = "v", type = "number", values = { 1 } } },
			})
		end
		return job, {}, { data = { frames = frames, errors = {}, warnings = {} } }
	end,
} :: any)

local function settingsBody(version: string): string
	return json.encode({
		defaultDatasource = "Metrics",
		datasources = {
			Metrics = {
				type = "prometheus",
				uid = "prom",
				name = "Metrics",
				isDefault = true,
				meta = { backend = true },
			},
			Weather = {
				type = PROXY,
				uid = "px",
				name = "Weather",
				url = "/api/datasources/proxy/uid/px",
				meta = { backend = false },
				jsonData = { queryParams = "lat=1&appid=SECRET" },
			},
		},
		buildInfo = { version = version },
	})
end

local DASH = json.encode({
	meta = { slug = "proxy" },
	dashboard = {
		uid = "proxy",
		title = "Proxy",
		time = { from = "now-1h", to = "now" },
		templating = { list = {} },
		panels = {
			{
				id = 1,
				type = "table",
				title = "Mixed",
				gridPos = { x = 0, y = 0, w = 12, h = 8 },
				datasource = { uid = "-- Mixed --" },
				targets = {
					{ refId = "A", datasource = { type = PROXY, uid = "px" }, path = "/a" } :: any,
					{ refId = "B", datasource = { type = "prometheus", uid = "prom" }, expr = "up" },
				},
			},
			{
				id = 2,
				type = "table",
				title = "Proxy only",
				gridPos = { x = 12, y = 0, w = 12, h = 8 },
				datasource = { type = PROXY, uid = "px" },
				targets = { { refId = "A", path = "/b" }, { refId = "C", path = "/b" } },
			},
		},
	},
})

local DS_QUERY_B = json.encode({
	results = {
		B = {
			status = 200,
			frames = {
				{
					schema = {
						name = "up",
						refId = "B",
						fields = { { name = "Time", type = "time" }, { name = "Value", type = "number" } },
					},
					data = { values = { { 1000 }, { 1 } } },
				},
			},
		},
	},
})

local function load(link: string, answers: (e: any) -> any): S.Harness
	local env = S.env()
	local s, effects = State.init({ link }, nil, env)
	local h = S.harness(s, env, answers)
	S.drive(h, effects)
	return h
end

local function proxyDashboard(): S.Harness
	return load("tern-grafana://dashboard?context=lab&uid=proxy", function(e: any): any
		if string.match(e.tag, "^dash/") then
			return S.body(200, DASH)
		elseif string.match(e.tag, "^fs/") then
			return S.body(200, settingsBody("13.3.1"))
		elseif string.match(e.tag, "^user/") then
			return S.response(S.grafana("13.3.1", "user.json"))
		end
		return nil
	end)
end

local function reply(h: S.Harness, tag: string, response: any): boolean
	local e = h.pending[tag]
	assert(e, "no pending request " .. tag)
	h.pending[tag] = nil
	local _, effects, changed = State.update(h.s, { kind = "http_done", tag = tag, response = response }, h.env)
	S.drive(h, effects)
	return changed == true
end

local function frameNames(data: any): { string }
	local out = {}
	for _, f in data.frames do
		table.insert(out, f.name or "?")
	end
	return out
end

describe("frontend datasource jobs in the dashboard block", function()
	it("runs a job's rounds beside /api/ds/query and shows every target in target order", function()
		local h = proxyDashboard()
		local ps = h.s.panels.p1
		expect(h.pending["q/1/1/p1"] ~= nil).toBe(true)
		expect(h.pending["ds/1/1/1/first/p1"].request.path).toBe("/api/datasources/proxy/uid/px/a")
		-- Only the prometheus target goes to /api/ds/query.
		local body = json.decode(h.pending["q/1/1/p1"].request.body)
		expect(#body.queries).toBe(1)
		expect(body.queries[1].refId).toBe("B")
		reply(h, "ds/1/1/1/first/p1", S.body(200, "one"))
		expect(h.pending["ds/1/1/1/second/p1"].request.path).toBe("/api/datasources/proxy/uid/px/more")
		reply(h, "q/1/1/p1", S.body(200, DS_QUERY_B))
		expect(ps.status).toBe("loading")
		reply(h, "ds/1/1/1/second/p1", S.body(200, "two"))
		expect(ps.status).toBe("ready")
		expect(frameNames(ps.data)).toEqual({ "one+two", "up" })
	end)

	it("runs one job for every target of a datasource instance", function()
		local h = proxyDashboard()
		expect(h.pending["q/1/1/p2"]).toBeNil()
		reply(h, "ds/1/1/1/first/p2", S.body(200, "x"))
		reply(h, "ds/1/1/1/second/p2", S.body(200, "y"))
		local data = h.s.panels.p2.data
		expect(#data.frames).toBe(2)
		expect(data.frames[2].refId).toBe("C")
	end)

	it("shows a job's error on its targets while the other targets show", function()
		local h = proxyDashboard()
		reply(h, "ds/1/1/1/first/p1", S.body(200, "one"))
		reply(h, "ds/1/1/1/second/p1", S.body(200, "fail"))
		reply(h, "q/1/1/p1", S.body(200, DS_QUERY_B))
		local ps = h.s.panels.p1
		expect(ps.status).toBe("ready")
		expect(ps.data.errors).toEqual({ "A: the API said no" })
		expect(frameNames(ps.data)).toEqual({ "up" })
		reply(h, "ds/1/1/1/first/p2", S.body(200, "x"))
		reply(h, "ds/1/1/1/second/p2", S.body(200, "fail"))
		expect(h.s.panels.p2.status).toBe("error")
		expect(h.s.panels.p2.error).toBe("A: the API said no; C: the API said no")
	end)

	it("keeps a frontend datasource's panel off the native rung when expressions read it", function()
		local env = S.env()
		local catalog = Queries.frontendDatasources(S.body(200, settingsBody("13.3.1")), env)
		local _, err = Queries.resolve({
			type = "table",
			datasource = { uid = "-- Mixed --" },
			targets = {
				{ refId = "A", datasource = { type = PROXY, uid = "px" }, path = "/a" } :: any,
				{
					refId = "B",
					datasource = { type = "__expr__", uid = "__expr__" },
					type = "math",
					expression = "$A*2",
				},
			},
		}, {}, catalog, env)
		expect(err).toBe("server-side expressions cannot read test-proxy-datasource queries (run in the browser)")
	end)

	it("keeps a job running across an advance that changes nothing", function()
		local h = proxyDashboard()
		reply(h, "ds/1/1/1/first/p2", S.body(200, "x"))
		local effects = {}
		Advance.advance(h.s, h.env, false, effects)
		for _, e in effects do
			expect(string.match((e :: any).tag or "", "^ds/") == nil).toBe(true)
		end
		reply(h, "ds/1/1/1/second/p2", S.body(200, "y"))
		expect(h.s.panels.p2.status).toBe("ready")
		expect(h.s.panels.p2.data.frames[1].name).toBe("x+y")
	end)

	it("drops a late answer to a superseded query", function()
		local h = proxyDashboard()
		reply(h, "ds/1/1/1/first/p2", S.body(200, "x"))
		local _, effects = State.key(h.s, Keys.char("r"), h.env)
		S.drive(h, effects)
		expect(h.pending["ds/1/2/1/first/p2"] ~= nil).toBe(true)
		local _, _, changed =
			State.update(h.s, { kind = "http_done", tag = "ds/1/1/1/second/p2", response = S.body(200, "y") }, h.env)
		expect(changed).toBe(false)
		expect(h.s.panels.p2.data == nil or #h.s.panels.p2.data.frames == 0).toBe(true)
		expect(h.s.panels.p2.status).toBe("loading")
	end)

	it("keeps datasource urls and settings in memory only", function()
		local h = proxyDashboard()
		local weather = assert(Queries.findDatasource(h.s.settings.datasources, "px"))
		expect(weather.url).toBe("/api/datasources/proxy/uid/px")
		expect((weather.json_data :: any).queryParams).toBe("lat=1&appid=SECRET")
		expect(h.s.settings.major).toBe(13)
		local saved = json.encode(State.save(h.s))
		expect((string.find(saved, "SECRET", 1, true))).toBeNil()
		expect((string.find(saved, "/api/datasources/proxy", 1, true))).toBeNil()
	end)
end)

-- Grafana Incident ------------------------------------------------------------

local function incidentDashboard(version: string): S.Harness
	local fs = S.doc("incident/frontend_settings.json")
	fs.buildInfo.version = version
	local settings = json.encode(fs)
	return load("tern-grafana://dashboard?context=lab&uid=incident-insights", function(e: any): any
		if string.match(e.tag, "^dash/") then
			return S.response("incident/dashboard.json")
		elseif string.match(e.tag, "^fs/") then
			return S.body(200, settings)
		elseif string.match(e.tag, "^user/") then
			return S.response(S.grafana("13.3.1", "user.json"))
		elseif string.match(e.tag, "^dsv/") then
			local qt = json.decode(e.request.body).queries[1].queryType
			return S.response("incident/var_" .. qt .. ".json")
		end
		return nil
	end)
end

-- The incidents table's query in flight.
local function pendingQuery(h: S.Harness): (string, any)
	local tag = "q/1/" .. h.s.panels.p29.gen .. "/p29"
	local e = assert(h.pending[tag], "no pending query " .. tag)
	return tag, json.decode(e.request.body).queries[1]
end

local function pick(h: S.Harness, name: string, values: { string })
	local effects = {}
	Advance.selectVariable(h.s, name, values, h.env, effects)
	S.drive(h, effects)
end

describe("Grafana Incident dashboards", function()
	it("lists variable options through /api/ds/query and sends All as $__all", function()
		local h = incidentDashboard("13.3.1")
		local labels = assert(h.s.vars[2], "the labels variable")
		expect(labels.name).toBe("labels")
		expect(labels.status).toBe("ready")
		expect(#labels.options).toBe(4)
		local _, q = pendingQuery(h)
		expect(q.datasource).toEqual({ uid = "inc", type = "grafana-incident-datasource" })
		expect(q.queryString).toBe("or($__all) or($__all) or(status:active status:resolved)")
		local tag = pendingQuery(h)
		reply(h, tag, S.response("incident/ds_query_incidents.json"))
		expect(h.s.panels.p29.status).toBe("ready")
		expect(#h.s.panels.p29.data.frames).toBe(1)
	end)

	it("sends label filters for picked labels", function()
		local h = incidentDashboard("13.3.1")
		pick(h, "labels", { "team:payments", "security" })
		local _, q = pendingQuery(h)
		expect(q.queryString).toBe(
			"or(label:'team:payments' label:'security') or($__all) or(status:active status:resolved)"
		)
	end)

	it("fails a picked `severity` on Grafana 13 with Grafana's own error", function()
		local h = incidentDashboard("13.3.1")
		pick(h, "severity", { "Critical" })
		local tag, q = pendingQuery(h)
		expect(q.queryString).toBe("or($__all) or(unsupported query name) or(status:active status:resolved)")
		reply(h, tag, S.response("incident/ds_query_invalid.json", 400))
		expect(h.s.panels.p29.status).toBe("error")
		expect(h.s.panels.p29.error).toBe("A: query incident: Invalid query string")
	end)

	it("filters a picked `severity` by its query type on Grafana 11", function()
		local h = incidentDashboard("11.6.16")
		pick(h, "severity", { "Critical" })
		local _, q = pendingQuery(h)
		expect(q.queryString).toBe("or($__all) or(severity:'Critical') or(status:active status:resolved)")
	end)
end)

return nil
