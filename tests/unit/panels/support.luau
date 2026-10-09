--!strict
-- Panel spec fixtures: the provisioned tern-panels dashboard and the
-- /api/ds/query captures of both Grafana versions, converted to frames by
-- the plugin's own converter (lib/frame/grafana), exactly as the dashboard
-- block will feed panels.
local Env = require("../../../plugin/lib/env")
local Fixtures = require("../../lib/fixtures")
local Frame = require("../../../plugin/lib/frame/types")
local Grafana = require("../../../plugin/lib/frame/grafana")
local Json = require("../../lib/json")

local M = {}

M.VERSIONS = { "11.6.16", "12.4.12" }

M.env = {
	now_ms = 1791577908000,
	decode = Json.decode,
	encode = Json.encode,
	null = Json.null,
} :: Env.Env

function M.decode(path: string): any
	return Json.decode(Fixtures.read(path))
end

-- Inline JSON, decoded the way Tern decodes it (nulls as the sentinel).
function M.json(text: string): any
	return Json.decode(text)
end

function M.dashboard(version: string): any
	return M.decode("grafana/" .. version .. "/dashboard_tern_panels.json").dashboard
end

-- A panel by id, including panels inside collapsed rows.
function M.panel(version: string, id: number): any
	local function search(list: any): any
		for _, p in list do
			if p.id == id then
				return p
			end
			if type(p.panels) == "table" then
				local found = search(p.panels)
				if found then
					return found
				end
			end
		end
		return nil
	end
	local found = search(M.dashboard(version).panels)
	assert(found, "no panel " .. tostring(id))
	return found
end

-- The library panel model as the dashboard merges it into panel 18.
function M.libraryPanel(version: string): any
	return M.decode("grafana/" .. version .. "/library_element.json").result.model
end

-- Every frame of every successful refId of a ds_query capture, refIds in
-- sorted order.
function M.frames(version: string, name: string): { Frame.Frame }
	local doc = M.decode("grafana/" .. version .. "/ds_query_" .. name .. ".json")
	local results = Grafana.parseResults(doc, M.env)
	local refs: { string } = {}
	for ref in results do
		table.insert(refs, ref)
	end
	table.sort(refs)
	local out: { Frame.Frame } = {}
	for _, ref in refs do
		local r = results[ref]
		if r.ok then
			for _, f in r.frames do
				table.insert(out, f)
			end
		end
	end
	return out
end

-- Frames of one refId only.
function M.refFrames(version: string, name: string, ref: string): { Frame.Frame }
	local out: { Frame.Frame } = {}
	for _, f in M.frames(version, name) do
		if f.refId == ref then
			table.insert(out, f)
		end
	end
	return out
end

-- A deep copy of a decoded JSON value, for specs that edit a panel.
function M.clone(v: any): any
	if type(v) ~= "table" or v == Json.null then
		return v
	end
	local out = {}
	for k, x in v do
		out[k] = M.clone(x)
	end
	return out
end

-- Depth-first search of a view tree.
function M.find(node: any, pred: (any) -> boolean): any
	if type(node) ~= "table" then
		return nil
	end
	if pred(node) then
		return node
	end
	if type(node.c) == "table" then
		for _, child in node.c do
			local hit = M.find(child, pred)
			if hit then
				return hit
			end
		end
	end
	return nil
end

function M.findAll(node: any, pred: (any) -> boolean, out: { any }?): { any }
	local acc = out or {}
	if type(node) ~= "table" then
		return acc
	end
	if pred(node) then
		table.insert(acc, node)
	end
	if type(node.c) == "table" then
		for _, child in node.c do
			M.findAll(child, pred, acc)
		end
	end
	return acc
end

-- The concatenated text of a node tree's spans.
function M.text(node: any): string
	local parts: { string } = {}
	local function walk(n: any)
		if type(n) ~= "table" then
			return
		end
		local p = n.p
		if type(p) == "table" then
			if type(p.spans) == "table" then
				for _, s in p.spans do
					table.insert(parts, if type(s) == "string" then s else s.t)
				end
			elseif type(p.text) == "string" and n.k ~= "md" then
				table.insert(parts, p.text)
			end
		end
		if type(n.c) == "table" then
			for _, c in n.c do
				walk(c)
			end
		end
	end
	walk(node)
	return table.concat(parts)
end

return M
