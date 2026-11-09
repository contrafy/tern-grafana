--!strict
-- The settings block on a large config (30 contexts, 4 endpoints each): the
-- first paint after the file is read, then keyboard work the way the runner
-- does it (key, then view and save after every key that changed something):
-- `list` walks the context/endpoint list, `form` moves through the fields of
-- an endpoint form and types into one.

local Bench = require("../lib/bench")
local Paint = require("../lib/paint")
local Probes = require("../lib/probes")
local State = require("../../../plugin/lib/settings/state")
local View = require("../../../plugin/lib/settings/view")
local json = require("../../lib/json")

local CONTEXTS = 30
local PATH = "/home/u/.config/tern-grafana/config.json"

local function configText(): string
	local contexts: { [string]: any } = {}
	for i = 1, CONTEXTS do
		local host = string.format("ctx%02d.example.com", i)
		contexts[string.format("ctx%02d", i)] = {
			grafana = {
				url = "https://" .. host,
				auth = { type = "bearer", token_env = string.format("GRAFANA_TOKEN_%02d", i) },
				headers = { ["X-Scope-OrgID"] = "tenant" .. i },
				datasources = { prometheus = "prom" .. i, loki = "loki" .. i },
			},
			prometheus = { url = "https://prom." .. host, timeout_ms = 30000 },
			alertmanager = { url = "https://am." .. host },
			loki = { url = "https://loki." .. host, tls = { insecure = false } },
		}
	end
	return json.encode({ version = 1, default_context = "ctx01", contexts = contexts })
end

type Harness = { s: any, env: any, p: Paint.Painter }

local function key(ch: string): any
	local named = ({ ["\n"] = "enter" })[ch]
	return {
		name = named or ch,
		text = if named then nil else ch,
		ctrl = false,
		alt = false,
		shift = false,
		meta = false,
	}
end

local function paint(h: Harness)
	Paint.paint(h.p, View.view(h.s, h.env), nil)
	State.save(h.s)
end

-- `render` false times the machine alone (key and save, no view).
local function press(h: Harness, keys: string, render: boolean?)
	for i = 1, #keys do
		local s, _, changed = State.key(h.s, key(string.sub(keys, i, i)), h.env)
		h.s = s
		if changed and render == false then
			State.save(h.s)
		elseif changed then
			paint(h)
		end
	end
end

local function loaded(env: any, text: string): Harness
	local s = State.init({}, nil, env)
	s = State.update(s, { kind = "config_file", path = PATH, text = text, exists = true }, env)
	local h: Harness = { s = s, env = env, p = Paint.new() }
	paint(h)
	return h
end

local M = {}

function M.run(opts: any): { any }
	local out: { any } = {}
	local env: any = { now_ms = 0, decode = Probes.decoder(json.decode), encode = json.encode, null = json.null }
	local text = configText()
	-- 20 down, 20 up: 40 list moves.
	local walk = string.rep("j", 20) .. string.rep("k", 20)
	-- Into the second context's prometheus form, through its fields, then an
	-- edit of 20 typed characters (32 keys timed).
	local open = string.rep("j", 7) .. "\n"
	local form = "jjjjjkkkkk\n" .. string.rep("x", 20) .. "\n"

	if opts.match("settings/list") then
		local h0 = loaded(env, text)
		local metrics: { [string]: any } = { contexts = CONTEXTS, rows = #State.rows(h0.s) }
		Bench.put(
			metrics,
			"load",
			Bench.sample(opts.warmup, opts.iters, function()
				return nil
			end, function()
				loaded(env, text)
			end)
		)
		local h = loaded(env, text)
		for _, pass in { { name = "keys40", render = true }, { name = "keys40_state", render = false } } do
			Bench.put(
				metrics,
				pass.name,
				Bench.sample(opts.warmup, opts.iters, function()
					Bench.liveKb()
					return h
				end, function(x: Harness)
					press(x, walk, pass.render)
				end)
			)
		end
		local _, nodes = Paint.sizes(h.p)
		metrics.view_nodes = nodes
		table.insert(out, { name = "settings/list", metrics = metrics })
	end

	if opts.match("settings/form") then
		local metrics: { [string]: any } = {}
		for _, pass in { { name = "keys32", render = true }, { name = "keys32_state", render = false } } do
			Bench.put(
				metrics,
				pass.name,
				Bench.sample(opts.warmup, opts.iters, function()
					local h = loaded(env, text)
					press(h, open)
					assert(h.s.page == "form", "the form did not open")
					-- The load's garbage is not the form's: collect it first.
					Bench.liveKb()
					return h
				end, function(h: Harness)
					press(h, form, pass.render)
				end)
			)
		end
		table.insert(out, { name = "settings/form", metrics = metrics })
	end
	return out
end

return M
