--!strict
-- Shared setup for the Query block specs: a validated config with a direct
-- Prometheus context and a Grafana-only context, an Env pinned to the end of
-- the recorded fixture window, kv held in a table, and responses built from
-- recorded fixtures.
local Keys = require("../../lib/keys")
local Support = require("../../lib/support")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")

local M = {}

-- End of the window every Prometheus fixture was captured over
-- (start=1791576998, end=1791577898, MANIFEST.tsv).
M.NOW_MS = 1791577898000
M.WINDOW = "now-15m"

M.PROMETHEUS = { "2.53.5", "3.15.0" }
M.GRAFANA = { "11.6.16", "12.4.12", "13.3.0" }

M.CONFIG_TEXT = [[{
	"version": 1,
	"default_context": "lab",
	"contexts": {
		"lab": {"prometheus": {"url": "http://localhost:9090"}},
		"graf": {"grafana": {"url": "http://localhost:3000", "datasources": {"prometheus": "prom3"}}},
		"both": {
			"grafana": {"url": "http://localhost:3011", "datasources": {"prometheus": "prom3"}},
			"prometheus": {"url": "http://localhost:9091"}
		}
	}
}]]

function M.config(text: string?, query: any?): any
	local raw = json.decode(text or M.CONFIG_TEXT)
	raw.query = query
	local cfg, problems = Validate.validate(raw)
	assert(cfg, problems[1] and Validate.format(problems[1]))
	return cfg
end

-- Typed `any` so specs can hand it to machines expecting an Env (it lacks
-- cols/rows, which the Query block never reads) and reach `kv` directly.
function M.env(config: any?): any
	return Support.env({ now_ms = M.NOW_MS, config = config })
end

-- A mixed-type list (strict mode infers literal arrays from their first item).
function M.list(...: any): { any }
	return { ... }
end

-- The shared helpers (tests/lib), under the names the Query specs use.
M.applyKv = Support.applyKv
M.response = Support.response
M.find = Support.find
M.all = Support.all
M.key = Keys.key
M.nodes = Support.nodes
M.byKey = Support.byKey

-- Types `s` one key per character.
function M.type(state: any, s: string, env: any, State: any): { any }
	local effects = {}
	for i = 1, #s do
		local ch = string.sub(s, i, i)
		local _, fx = State.key(state, M.key(if ch == " " then "space" else ch, ch), env)
		for _, e in fx do
			table.insert(effects, e)
		end
	end
	return effects
end

return M
