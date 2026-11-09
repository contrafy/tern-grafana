--!strict
-- Expanded time series panel, keyboard cursor moves: the dashboard re-runs
-- Registry.view with a new opts.cursor on every arrow key (its view memo
-- keys on the cursor). One tern-panels time series panel over 10 series x
-- 1000 synthetic points; `cursor_move` is one redraw at the next sample,
-- `full` a full render (a different width each time, as a resize does).

local Bench = require("../lib/bench")
local Fixtures = require("../../lib/fixtures")
local FrameGrafana = require("../../../plugin/lib/frame/grafana")
local Registry = require("../../../plugin/lib/panels/registry")
local S = require("../../unit/dashboard/support")
local Synth = require("../lib/synth")
local json = require("../../lib/json")

local VERSION = "12.4.12"
local SERIES, POINTS = 10, 1000
local FROM, TO = 1791577008000, 1791577908000

local M = {}

function M.run(opts: any): { any }
	local env: any = {
		now_ms = TO,
		null = json.null,
		decode = json.decode,
		encode = json.encode,
	}
	local doc = json.decode(Fixtures.read(S.grafana(VERSION, "dashboard_tern_panels.json")))
	local panel: any = nil
	for _, p in doc.dashboard.panels do
		if p.type == "timeseries" then
			panel = p
			break
		end
	end
	local body = "{" .. Synth.grafanaResult("A", SERIES, POINTS, FROM, TO, 7) .. "}"
	local frames = FrameGrafana.frames(json.decode(body).A.frames, env)
	local times = frames[1].fields[1].values
	local function view(cursor: number?, width: number)
		Registry.view(panel, frames, env, {
			key = "p",
			cursor = cursor,
			from_ms = FROM,
			to_ms = TO,
			width = width,
			height = 300,
			source = panel,
		})
	end
	local w = 960
	local full = Bench.sample(opts.warmup, opts.iters, function()
		w += 1
		return w
	end, function(width: number)
		view(nil, width)
	end)
	local i = 1
	view(times[i], 960)
	local move = Bench.sample(opts.warmup, opts.iters, function()
		i = i % #times + 1
		return times[i]
	end, function(cursor: number)
		view(cursor, 960)
	end)
	local metrics: { [string]: any } = {}
	Bench.put(metrics, "full", full)
	Bench.put(metrics, "cursor_move", move)
	return { { name = "panel_cursor timeseries 10x1000", metrics = metrics } }
end

return M
