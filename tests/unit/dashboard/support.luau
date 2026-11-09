--!strict
-- Shared setup for the dashboard specs: the pinned Grafana versions, an Env
-- with the test JSON codec, a config pointing at the dev stack, responses
-- built from recorded fixtures, and the harness that drives a dashboard (or
-- panel) block through its loading requests.
local DashboardState = require("../../../plugin/lib/dashboard/state")
local Fixtures = require("../../lib/fixtures")
local Support = require("../../lib/support")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")

local M = {}

M.VERSIONS = { "11.6.16", "12.4.12", "13.3.0" }

-- 2026-10-09T20:31:47Z, the capture time of the Grafana fixtures.
M.NOW_MS = 1791577907000

-- Whether each stack's frontend settings report an image renderer.
M.RENDERER = { ["11.6.16"] = false, ["12.4.12"] = true, ["13.3.0"] = true } :: { [string]: boolean }

M.CONFIG = assert(
	Validate.parseFile(
		[[{"default_context": "lab", "contexts": {
	"lab": {"grafana": {"url": "http://localhost:3000", "org_id": 1, "datasources": {"prometheus": "prom3"}}}}}]],
		json.decode
	),
	"dashboard spec config must validate"
)

function M.env(config: any?): any
	return {
		now_ms = M.NOW_MS,
		decode = json.decode,
		encode = json.encode,
		null = json.null,
		config = if config == false then nil else (config or M.CONFIG),
	}
end

M.response = Support.response

function M.body(status: number, body: string): any
	return Support.body(body, status)
end

function M.doc(path: string): any
	return json.decode(Fixtures.read(path))
end

function M.grafana(version: string, name: string): string
	return "grafana/" .. version .. "/" .. name
end

-- A block under test: its state and Env, the requests (and with `timers`
-- the timers) not answered yet by tag, and the targets it opened.
-- `answer(e)` returns the response for an http effect the harness answers
-- right away (the loading requests), or nil to leave it pending.
export type Harness = {
	s: any,
	env: any,
	pending: { [string]: any },
	opened: { string },
	answer: (e: any) -> any,
	timers: boolean,
}

function M.harness(s: any, env: any, answer: (e: any) -> any, timers: boolean?): Harness
	return { s = s, env = env, pending = {}, opened = {}, answer = answer, timers = timers == true }
end

-- Applies effects the way the runner would: records opens, answers what
-- `h.answer` knows (recursively), keeps the rest pending.
function M.drive(h: Harness, effects: { any })
	for _, e in effects do
		if e.kind == "open" then
			table.insert(h.opened, e.target)
		elseif e.kind == "http" then
			local response = h.answer(e)
			if response then
				local _, more =
					DashboardState.update(h.s, { kind = "http_done", tag = e.tag, response = response }, h.env)
				M.drive(h, more)
			else
				h.pending[e.tag] = e
			end
		elseif e.kind == "timer" and h.timers then
			h.pending[e.tag] = e
		end
	end
end

return M
