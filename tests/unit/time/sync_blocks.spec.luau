--!strict
-- The shared time range as every synced block lives it (`S`): off by default
-- a range key stays local; on, the block publishes its range unless others
-- already share one (then it joins theirs), polls for other blocks' newer
-- ranges and re-queries on them but never on its own echo, and comes back
-- synced after a restart. One scenario set, run against each block that
-- takes part: Query, Logs, Trace (search tab) and Dashboard.
local DS = require("../dashboard/support")
local Dashboard = require("../../../plugin/lib/dashboard/state")
local Keys = require("../../lib/keys")
local Logs = require("../../../plugin/lib/logs/state")
local Query = require("../../../plugin/lib/query/state")
local QS = require("../query/support")
local Scheme = require("../../../plugin/lib/links/scheme")
local Shared = require("../../../plugin/lib/time/shared")
local Support = require("../../lib/support")
local Trace: any = require("../../../plugin/lib/trace/state")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type Block = {
	name: string,
	-- A block of this kind with its first answer in, and its Env (kv in a table).
	open: () -> (any, any),
	-- The block restored from `saved` in `env`.
	restore: (saved: any, env: any) -> (any, { any }),
	key: (s: any, env: any, text: string) -> { any },
	update: (s: any, msg: any, env: any) -> (any, { any }),
	save: (s: any) -> any,
	-- How many of `effects` are this block's data queries.
	queries: (effects: { any }) -> number,
}

local function counter(pattern: string): (effects: { any }) -> number
	return function(effects: { any }): number
		local n = 0
		for _, e in effects do
			if e.kind == "http" and string.match(e.tag, pattern) then
				n += 1
			end
		end
		return n
	end
end

local function typed(text: string): any
	return Keys.key(text, text)
end

local QUERY_LINK = Scheme.encode({
	action = "query",
	params = { context = "lab", expr = "rate(node_cpu_seconds_total[1m])", from = QS.WINDOW, to = "now" },
	vars = {},
})

local LOGS_LINK = Scheme.encode({ action = "logs", params = { expr = '{job="loggen"}', from = QS.WINDOW }, vars = {} })
local LOGS_CONFIG = assert(
	Validate.validate(json.decode([[{
	"version": 1,
	"default_context": "lab",
	"contexts": {"lab": {"loki": {"url": "http://localhost:3100"}}}
}]])),
	"logs config must validate"
)

local TRACE_LINK = Scheme.encode({ action = "trace", params = { context = "lab" }, vars = {} })
local TRACE_CONFIG = assert(
	Validate.parseFile(
		[[{"default_context": "lab", "contexts": {"lab": {"tempo": {"url": "http://t:3200"}}}}]],
		json.decode
	),
	"trace config must validate"
)

local DASHBOARD_LINK = "tern-grafana://dashboard?context=lab&uid=tern-panels"
local GRAFANA = "12.4.12"

local function dashboardLoading(e: any): any
	local tag = e.tag
	if string.match(tag, "^dash/") then
		return Support.response(DS.grafana(GRAFANA, "dashboard_tern_panels.json"))
	elseif string.match(tag, "^fs/") then
		return Support.response(DS.grafana(GRAFANA, "frontend_settings.json"))
	elseif string.match(tag, "^user/") then
		return Support.response(DS.grafana(GRAFANA, "user.json"))
	elseif string.match(tag, "^lib/") then
		return Support.response(DS.grafana(GRAFANA, "library_element.json"))
	elseif string.match(tag, "^var/") then
		return Support.response(DS.grafana(GRAFANA, "ds_proxy_prom_label_values.json"))
	end
	return nil
end

local function block(name: string, State: any, key: (string) -> any, fields: any): Block
	return {
		name = name,
		open = fields.open,
		restore = fields.restore,
		key = function(s: any, env: any, text: string): { any }
			local _, effects = State.key(s, key(text), env)
			return effects
		end,
		update = function(s: any, msg: any, env: any): (any, { any })
			local _, effects = State.update(s, msg, env)
			return s, effects
		end,
		save = State.save,
		queries = fields.queries,
	}
end

local BLOCKS: { Block } = {
	block("Query", Query, typed, {
		open = function(): (any, any)
			local env = QS.env(QS.config())
			local s = Query.init({ QUERY_LINK }, nil, env)
			return s, env
		end,
		restore = function(saved: any, env: any): (any, { any })
			return Query.init({}, saved, env)
		end,
		queries = counter("^q:"),
	}),
	block("Logs", Logs, typed, {
		open = function(): (any, any)
			local env = QS.env(LOGS_CONFIG)
			local s, effects = Logs.init({ LOGS_LINK }, nil, env)
			for _, e in effects do
				if e.kind == "http" and string.sub(e.tag, 1, #Logs.QUERY_TAG) == Logs.QUERY_TAG then
					Logs.update(s, {
						kind = "http_done",
						tag = e.tag,
						response = Support.response("loki/3.7.8/query_range_streams_forward.json"),
					}, env)
					break
				end
			end
			return s, env
		end,
		restore = function(saved: any, env: any): (any, { any })
			return Logs.init({ LOGS_LINK }, saved, env)
		end,
		queries = function(effects: { any }): number
			local n = 0
			for _, e in effects do
				if e.kind == "http" and string.sub(e.tag, 1, #Logs.QUERY_TAG) == Logs.QUERY_TAG then
					n += 1
				end
			end
			return n
		end,
	}),
	block("Trace search", Trace, typed, {
		open = function(): (any, any)
			local env = Support.env({ now_ms = 1791577900000, config = TRACE_CONFIG })
			local s, effects = Trace.init({ TRACE_LINK }, nil, env)
			for _, e in effects do
				if e.kind == "http" and string.match(e.tag, "^search:") then
					Trace.update(
						s,
						{ kind = "http_done", tag = e.tag, response = Support.response("tempo/2.10.8/search.json") },
						env
					)
					break
				end
			end
			return s, env
		end,
		restore = function(saved: any, env: any): (any, { any })
			return Trace.init({ TRACE_LINK }, saved, env)
		end,
		queries = counter("^search:"),
	}),
	block("Dashboard", Dashboard, Keys.char, {
		open = function(): (any, any)
			local env = Support.env({ now_ms = DS.NOW_MS, config = DS.CONFIG })
			local s, effects = Dashboard.init({ DASHBOARD_LINK }, nil, env)
			DS.drive(DS.harness(s, env, dashboardLoading), effects)
			return s, env
		end,
		restore = function(saved: any, env: any): (any, { any })
			return Dashboard.init({}, saved, env)
		end,
		queries = counter("^q/"),
	}),
}

for _, b in BLOCKS do
	describe(b.name .. " block time sync", function()
		it("keeps range keys local while sync is off", function()
			local s, env = b.open()
			expect(Support.find(b.key(s, env, "3"), "kv_set")).toBeNil()
			expect(s.sync.on).toBe(false)
		end)

		it("publishes on S and on every range change, polls, and persists until S turns it off", function()
			local s, env = b.open()
			local from = s.from
			local effects = b.key(s, env, "S")
			Support.applyKv(env, effects)
			local rec = env.kv[Shared.KEY]
			expect(rec ~= nil).toBe(true)
			expect(rec.from).toBe(from)
			expect(rec.origin).toBe(s.sync.origin)
			expect(Support.find(effects, "timer").tag).toBe(Shared.TAG .. s.sync.gen)

			Support.applyKv(env, b.key(s, env, "3"))
			expect(env.kv[Shared.KEY].from).toBe(s.from)
			expect(env.kv[Shared.KEY].seq).toBe(rec.seq + 1)

			local again, restored = b.restore(b.save(s), env)
			expect(again.sync.on).toBe(true)
			expect(Support.find(restored, "timer").tag).toBe(Shared.TAG .. again.sync.gen)

			-- S again turns it off, for this session and the next.
			b.key(s, env, "S")
			expect(s.sync.on).toBe(false)
			expect((b.restore(b.save(s), env)).sync.on).toBe(false)
		end)

		it("adopts another block's newer range on its poll tick and never re-queries on its own echo", function()
			local s, env = b.open()
			Support.applyKv(env, b.key(s, env, "S"))
			local tick = Shared.TAG .. s.sync.gen
			local _, effects = b.update(s, { kind = "tick", tag = tick }, env)
			expect(b.queries(effects)).toBe(0)
			expect(Support.find(effects, "timer").tag).toBe(tick)

			env.kv[Shared.KEY] = Shared.publish({ from = "now-6h", to = "now" }, nil, "other-1-2", env.kv[Shared.KEY])
			_, effects = b.update(s, { kind = "tick", tag = tick }, env)
			expect(s.from).toBe("now-6h")
			expect(b.queries(effects) > 0).toBe(true)
			-- The same record polled again is not news.
			_, effects = b.update(s, { kind = "tick", tag = tick }, env)
			expect(b.queries(effects)).toBe(0)
		end)

		it("joins the range others already share instead of overwriting it", function()
			local s, env = b.open()
			env.kv[Shared.KEY] = Shared.publish({ from = "now-24h", to = "now" }, nil, "other-1-2", nil)
			local effects = b.key(s, env, "S")
			expect(Support.find(effects, "kv_set")).toBeNil()
			expect(s.from).toBe("now-24h")
			expect(b.queries(effects) > 0).toBe(true)
		end)
	end)
end

return nil
