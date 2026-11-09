--!strict
-- The datasource job engine: a frontend datasource port asks for requests in
-- steps, and each step must see every answer it asked for, once; answers it
-- did not ask for (superseded, repeated) must never reach it, a module that
-- stalls or loops must end with an error instead of a panel stuck loading,
-- and an error must show on every target of the job, as /api/ds/query
-- results do. Proxy URLs carry API keys in their query strings (JSON API's
-- jsonData.queryParams), so error texts lose them.
local Registry = require("../../../plugin/lib/datasources/registry")
local Support = require("../../lib/support")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local env = Support.env()

local function get(path: string): any
	return { method = "GET", path = path }
end

-- Lists label names, then asks for each name's count, then answers one
-- frame per name: the shape of a two-round proxy datasource.
local twoRounds: any = {
	types = { "test-two-rounds" },
	start = function(targets: { any }, ctx: any, _env: any): any
		return { ref = targets[1].refId, base = "/api/datasources/proxy/uid/" .. ctx.ds.uid, round = 0 }
	end,
	step = function(job: any, answers: any, _env: any): (any, { any }, any)
		job.round += 1
		if job.round == 1 then
			return job,
				{
					{ tag = "names", request = get(job.base .. "/names") },
					{ tag = "total", request = get(job.base .. "/total") },
				},
				nil
		elseif job.round == 2 then
			job.total = answers.total.body
			local reqs = {}
			for name in string.gmatch(answers.names.body, "[^,]+") do
				table.insert(reqs, { tag = "n:" .. name, request = get(job.base .. "/count/" .. name) })
			end
			return job, reqs, nil
		end
		local values = {}
		for tag, r in answers do
			values[string.sub(tag, 3)] = tonumber(r.body)
		end
		return job,
			{},
			{
				data = {
					frames = {
						{
							name = job.total,
							refId = job.ref,
							fields = {
								{ name = "a", type = "number", values = { values.a } },
								{ name = "b", type = "number", values = { values.b } },
							},
						},
					},
					errors = {},
					warnings = {},
				},
			}
	end,
}

local ctx: any = { ds = { uid = "card", type = "test-two-rounds", name = "Card", is_default = false } }

local function answer(body: string): any
	return Support.body(body)
end

describe("datasource job engine", function()
	it("runs the next step only when every request of a step is answered", function()
		local run, first = Registry.begin(twoRounds, twoRounds.start({ { refId = "A" } }, ctx, env), { "A" }, env)
		expect(#first).toBe(2)
		expect(first[1].request.path).toBe("/api/datasources/proxy/uid/card/names")
		local ok, more = Registry.answer(run, "total", answer("2 labels"), env)
		expect(ok).toBe(true)
		expect(#more).toBe(0)
		ok, more = Registry.answer(run, "names", answer("a,b"), env)
		expect(ok).toBe(true)
		expect(#more).toBe(2)
		expect(more[2].request.path).toBe("/api/datasources/proxy/uid/card/count/b")
		Registry.answer(run, "n:a", answer("3"), env)
		expect(run.outcome).toBeNil()
		Registry.answer(run, "n:b", answer("5"), env)
		local data = Registry.panelData(run)
		expect(data.frames[1].name).toBe("2 labels")
		expect(data.frames[1].fields[2].values).toEqual({ 5 })
	end)

	it("drops answers the step did not ask for, repeated ones, and any after the end", function()
		local run = Registry.begin(twoRounds, twoRounds.start({ { refId = "A" } }, ctx, env), { "A" }, env)
		expect((Registry.answer(run, "n:a", answer("1"), env))).toBe(false)
		expect((Registry.answer(run, "total", answer("t"), env))).toBe(true)
		expect((Registry.answer(run, "total", answer("t"), env))).toBe(false)
		expect(run.steps).toBe(1)
		run.outcome = { error = "ended" }
		expect((Registry.answer(run, "names", answer("a"), env))).toBe(false)
	end)

	it("shows a job's error on every target it answers", function()
		local failing: any = {
			types = { "test-failing" },
			step = function(job: any, _answers: any, _env: any): (any, { any }, any)
				return job, {}, { error = "No target data source has been selected." }
			end,
		}
		local run, first = Registry.begin(failing, {}, { "A", "B" }, env)
		expect(#first).toBe(0)
		expect(Registry.panelData(run)).toEqual({
			frames = {},
			errors = { "A: No target data source has been selected.", "B: No target data source has been selected." },
			warnings = {},
		})
	end)

	it("ends a job that asks for nothing, misnames a tag or never finishes", function()
		local function module(step: any): any
			return { types = { "test-bad" }, step = step }
		end
		local idle = Registry.begin(
			module(function(job: any): (any, { any }, any)
				return job, {}, nil
			end),
			{},
			{ "A" },
			env
		)
		expect(idle.outcome).toEqual({ error = "the datasource module asked for nothing" })
		local twice = Registry.begin(
			module(function(job: any): (any, { any }, any)
				return job, { { tag = "x", request = get("/a") }, { tag = "x", request = get("/b") } }, nil
			end),
			{},
			{ "A" },
			env
		)
		-- The answer's tag would be ambiguous (and a "/" would break the
		-- block's own request tags).
		expect(string.find((twice.outcome :: any).error, "bad request tag", 1, true) ~= nil).toBe(true)
		local slash = Registry.begin(
			module(function(job: any): (any, { any }, any)
				return job, { { tag = "a/b", request = get("/a") } }, nil
			end),
			{},
			{ "A" },
			env
		)
		expect(slash.outcome ~= nil).toBe(true)
		local loop = module(function(job: any): (any, { any }, any)
			return job, { { tag = "again", request = get("/again") } }, nil
		end)
		local run = Registry.begin(loop, {}, { "A" }, env)
		local rounds = 1
		while run.outcome == nil do
			Registry.answer(run, "again", answer("{}"), env)
			rounds += 1
		end
		expect(rounds).toBe(Registry.MAX_STEPS + 1)
		expect(string.find((run.outcome :: any).error, "more than", 1, true) ~= nil).toBe(true)
	end)
end)

describe("datasource module helpers", function()
	it("removes query strings from error texts, where proxy URLs carry API keys", function()
		local text = Registry.redact(
			'Get "https://grafana.example/api/datasources/proxy/uid/w1?lat=1&appid=SECRET": dial tcp: timeout'
		)
		expect((string.find(text, "SECRET", 1, true))).toBeNil()
		expect(string.find(text, "/api/datasources/proxy/uid/w1?...", 1, true) ~= nil).toBe(true)
		local _, err = Registry.json({
			status = 0,
			headers = {},
			body = "",
			timed_out = false,
			error = "error sending request for url (/api/datasources/proxy/uid/w1?appid=SECRET)",
		}, env, "JSON API")
		expect(err ~= nil).toBe(true)
		expect((string.find(err :: string, "SECRET", 1, true))).toBeNil()
	end)

	it("names the proxy path of a proxy-access instance and none for direct access", function()
		local ds: any =
			{ uid = "w 1", type = "x", name = "W", is_default = false, url = "/api/datasources/proxy/uid/w 1" }
		expect(Registry.proxyPath(ds)).toBe("/api/datasources/proxy/uid/w%201")
		ds.url = "https://api.example.invalid"
		expect(Registry.proxyPath(ds)).toBeNil()
	end)
end)

return nil
