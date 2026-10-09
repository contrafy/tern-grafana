--!strict
-- Native panel rendering, rung C of the ladder (docs/architecture.md):
-- `supports` says whether Tern can draw a panel the way Grafana would (and
-- why not), `view` draws it from the panel's frames. The dashboard asks
-- `supports` before querying; anything unsupported goes to the PNG or
-- browser rung with the reason shown.
--
-- `panel` is the decoded panel JSON (library panels merged, repeats
-- expanded); `frames` are the panel's query results through the frame
-- converters, every refId together.

local Assets = require("../render/assets")
local Common = require("./common")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Frame = require("../frame/types")
local Gauge = require("./gauge")
local Json = require("./json")
local Logs = require("./logs")
local Stat = require("./stat")
local Table = require("./table")
local Text = require("./text")
local Timeseries = require("./timeseries")
local Transform = require("./transform")
local Values = require("./values")
local ui = require("../ui")

type Env = Env.Env
type Frame = Frame.Frame
type Node = ui.Node

export type Options = Common.Options

local M = {}

M.TYPES = { "timeseries", "stat", "gauge", "bargauge", "table", "text", "logs" }

local NATIVE: { [string]: boolean } = {}
for _, t in M.TYPES do
	NATIVE[t] = true
end

-- Panel types with a known reason for not being native.
local REASONS: { [string]: string } = {
	heatmap = "heatmap panels are not rendered natively yet",
	["state-timeline"] = "state-timeline panels are not rendered natively yet",
	graph = "the legacy graph panel (Grafana migrates it to time series in the browser) is not rendered natively",
	singlestat = "the legacy singlestat panel is not rendered natively",
	row = "a row is a layout element, not a panel",
}

-- Table cell types whose text fallback would misrepresent the data.
local UNSUPPORTED_CELLS: { [string]: boolean } = { sparkline = true, image = true }

-- Without an env (no JSON null sentinel known) JSON nulls only read as empty.
local NO_ENV: Env = {
	now_ms = 0,
	decode = function(_: string): any
		return nil
	end,
	encode = function(_: any): string
		return ""
	end,
	null = newproxy(false),
}

local function cellTypes(panel: any, env: Env): { string }
	local out: { string } = {}
	local t = Json.str(env, Json.path(env, panel, "fieldConfig", "defaults", "custom", "cellOptions", "type"))
	if t then
		table.insert(out, t)
	end
	for _, o in Json.list(env, Json.path(env, panel, "fieldConfig", "overrides")) do
		for _, p in Json.list(env, Json.path(env, o, "properties")) do
			if Json.str(env, Json.path(env, p, "id")) == "custom.cellOptions" then
				local pt = Json.str(env, Json.path(env, p, "value", "type"))
				if pt then
					table.insert(out, pt)
				end
			end
		end
	end
	return out
end

function M.supports(panel: any, envArg: Env?): (boolean, string?)
	local env = envArg or NO_ENV
	if Json.tbl(env, panel) == nil then
		return false, "the panel is not an object"
	end
	local kind = Json.str(env, panel.type)
	if kind == nil then
		if Json.tbl(env, panel.libraryPanel) then
			return false, "the library panel is not resolved"
		end
		return false, "the panel has no type"
	end
	if not NATIVE[kind] then
		return false, REASONS[kind] or string.format("panel type %s is not rendered natively", kind)
	end
	local why = Transform.unsupported(panel, env) or FieldConfig.unsupported(panel, env)
	if why then
		return false, why
	end
	if kind == "timeseries" then
		why = Timeseries.unsupported(panel, env)
	elseif kind == "stat" or kind == "gauge" or kind == "bargauge" then
		why = Values.unsupported(panel, env)
	elseif kind == "table" then
		for _, t in cellTypes(panel, env) do
			if UNSUPPORTED_CELLS[t] then
				why = string.format("table cell type %s is not supported", t)
				break
			end
		end
	end
	if why then
		return false, why
	end
	return true, nil
end

local function render(panel: any, frames: { Frame }, env: Env, opts: Options): (Node, Assets.Assets)
	local kind = Json.str(env, panel.type)
	if kind == "text" then
		return Text.view(panel, env, opts), {}
	end
	local data = Transform.prepare(panel, frames, env)
	if kind == "timeseries" then
		return Timeseries.view(panel, data, env, opts)
	end
	if #data == 0 then
		return ui.muted("No data", { key = opts.key }), {}
	end
	if kind == "stat" then
		return Stat.view(panel, data, env, opts), {}
	elseif kind == "gauge" then
		return Gauge.view(panel, data, env, opts, false), {}
	elseif kind == "bargauge" then
		return Gauge.view(panel, data, env, opts, true), {}
	elseif kind == "table" then
		return Table.view(panel, data, env, opts), {}
	elseif kind == "logs" then
		return Logs.view(panel, data, env, opts), {}
	end
	local _, reason = M.supports(panel, env)
	return ui.muted(reason or "Not supported", { key = opts.key }), {}
end

-- The panel as a view plus the assets it references (time series SVGs, keyed
-- under opts.key). A renderer failure shows as an error line in the panel
-- instead of taking the whole dashboard down.
function M.view(panel: any, frames: { Frame }, env: Env, opts: Options): (Node, Assets.Assets)
	local ok, node, assets = pcall(render, panel, frames, env, opts)
	if not ok then
		return ui.text({ ui.span("Panel failed to render: " .. tostring(node), "error") }, { key = opts.key }), {}
	end
	return node, assets
end

return M
