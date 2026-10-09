--!strict
-- Shared setup for the dashboard specs: the pinned Grafana versions, an Env
-- with the test JSON codec, a config pointing at the dev stack, and
-- responses built from recorded fixtures.
local Fixtures = require("../../lib/fixtures")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")

local M = {}

M.VERSIONS = { "11.6.16", "12.4.12" }

-- 2026-10-09T20:31:47Z, the capture time of the Grafana fixtures.
M.NOW_MS = 1791577907000

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

function M.response(path: string, status: number?): any
	return { status = status or 200, headers = {}, body = Fixtures.read(path), timed_out = false }
end

function M.body(status: number, body: string): any
	return { status = status, headers = {}, body = body, timed_out = false }
end

function M.doc(path: string): any
	return json.decode(Fixtures.read(path))
end

function M.grafana(version: string, name: string): string
	return "grafana/" .. version .. "/" .. name
end

return M
