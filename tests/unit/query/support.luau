--!strict
-- Shared setup for the Query block specs: a validated config with a direct
-- Prometheus context and a Grafana-only context, an Env pinned to the end of
-- the recorded fixture window, kv held in a table, and responses built from
-- recorded fixtures.
local Fixtures = require("../../lib/fixtures")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")

local M = {}

-- End of the window every Prometheus fixture was captured over
-- (start=1791576998, end=1791577898, MANIFEST.tsv).
M.NOW_MS = 1791577898000
M.WINDOW = "now-15m"

M.PROMETHEUS = { "2.53.5", "3.15.0" }
M.GRAFANA = { "11.6.16", "12.4.12" }

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
	local kv: { [string]: any } = {}
	return {
		now_ms = M.NOW_MS,
		decode = json.decode,
		encode = json.encode,
		null = json.null,
		config = config,
		kv = kv,
		kv_get = function(key: string): any
			return kv[key]
		end,
	}
end

-- A mixed-type list (strict mode infers literal arrays from their first item).
function M.list(...: any): { any }
	return { ... }
end

-- Applies kv_set effects the way the runner would.
function M.applyKv(env: any, effects: { any })
	for _, e in effects do
		if e.kind == "kv_set" then
			env.kv[e.key] = e.value
		end
	end
end

function M.response(path: string, status: number?): any
	return { status = status or 200, headers = {}, body = Fixtures.read(path), timed_out = false }
end

function M.find(effects: { any }, kind: string): any
	for _, e in effects do
		if e.kind == kind then
			return e
		end
	end
	return nil
end

function M.all(effects: { any }, kind: string): { any }
	local out = {}
	for _, e in effects do
		if e.kind == kind then
			table.insert(out, e)
		end
	end
	return out
end

function M.key(name: string, text: string?, mods: { [string]: boolean }?): any
	local m: { [string]: boolean } = mods or {}
	local t = text
	if t == nil and #name == 1 then
		t = name
	end
	return {
		name = name,
		text = t,
		ctrl = m.ctrl == true,
		alt = m.alt == true,
		shift = m.shift == true,
		meta = m.meta == true,
	}
end

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

-- Depth-first search of a view tree for nodes matching `pred`.
function M.nodes(node: any, pred: (any) -> boolean, out: { any }?): { any }
	local acc = out or {}
	if type(node) ~= "table" then
		return acc
	end
	if pred(node) then
		table.insert(acc, node)
	end
	if node.c then
		for _, child in node.c do
			M.nodes(child, pred, acc)
		end
	end
	return acc
end

function M.byKey(node: any, key: string): any
	return M.nodes(node, function(n)
		return n.p ~= nil and n.p.key == key
	end)[1]
end

return M
