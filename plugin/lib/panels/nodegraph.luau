--!strict
-- The node graph panel (public/app/plugins/panel/nodeGraph: utils.ts
-- getNodeGraphDataFrames/applyOptionsToFrames/processNodes/statToString,
-- layout.ts, NodeGraph.tsx):
-- - frames: the nodes frame (an `id` field) and the edges frame (a
--   `source` field, or named "edges"); field names match case-insensitively;
--   without a nodes frame, nodes come from the edges' ends;
-- - node fields: id, title, subtitle, mainstat, secondarystat, arc__*
--   (rim sections; colors from options.nodes.arcs as Grafana applies
--   them), nodeRadius, highlighted; edge fields: source, target,
--   thickness, strokeDasharray, highlighted;
-- - stats print as Grafana's statToString: numbers to fixed decimals
--   (the field's, else 2) and the unit id after a space
--   (options.nodes/edges.mainStatUnit, secondaryStatUnit), strings as is;
-- - layout: layered left to right (longest path layers, dummy nodes on
--   long edges, barycenter ordering, median alignment), grid in rows for
--   layoutAlgorithm "grid"; "force" draws the layered layout too (a
--   simulation's resting place is not reproducible);
-- - the legend lists the arc fields with colors, else the stat fields.
-- The first MAX_NODES nodes are drawn; the rest are counted in a note.

local Assets = require("../render/assets")
local Charts = require("./charts")
local Common = require("./common")
local Env = require("../env")
local Frame = require("../frame/types")
local Json = require("./json")
local SvgNodeGraph = require("../render/svg_nodegraph")
local Thresholds = require("../units/thresholds")
local ui = require("../ui")

type Env = Env.Env
type Frame = Frame.Frame
type Field = Frame.Field
type Node = ui.Node

local M = {}

M.types = { "nodeGraph" }

M.WIDTH = 960
M.HEIGHT = 300
M.MAX_NODES = 300
M.LAYER_X = 160
M.SPACING_Y = 100
M.GRID_X = 160
M.GRID_Y = 140

function M.supports(_: any, _: Env): (boolean, string?)
	return true, nil
end

local function find(frame: Frame, name: string): Field?
	for _, f in frame.fields do
		if string.lower(f.name) == name then
			return f
		end
	end
	return nil
end

local function str(v: any): string?
	if v == nil or v == Frame.NULL then
		return nil
	end
	return if type(v) == "string" then v else tostring(v)
end

-- statToString.
function M.stat(field: Field, value: any, unit: string?): string
	if type(value) == "string" then
		return value
	elseif type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return ""
	end
	local decimals = if field.config
			and field.config.decimals
			and field.config.decimals ~= 0
		then field.config.decimals :: number
		else 2
	local u = unit or (field.config and field.config.unit)
	return string.format("%." .. decimals .. "f", value) .. (if u and u ~= "" then " " .. u else "")
end

export type Graph = {
	nodes: { SvgNodeGraph.Node },
	edges: { SvgNodeGraph.Edge },
	legend: { { name: string, class: string } },
	stats: { string },
	hidden: number,
}

local function isEdges(frame: Frame): boolean
	return frame.name == "edges" or find(frame, "source") ~= nil
end

-- processNodes, before layout (positions 0).
function M.graph(panel: any, frames: { Frame }, env: Env): Graph?
	local o = Json.obj(env, panel.options)
	local nodeOpts, edgeOpts = Json.obj(env, o.nodes), Json.obj(env, o.edges)
	local nodesF: Frame?, edgesF: Frame? = nil, nil
	for _, f in frames do
		if isEdges(f) then
			edgesF = edgesF or f
		elseif find(f, "id") then
			nodesF = nodesF or f
		end
	end
	if nodesF == nil and edgesF == nil then
		return nil
	end
	local arcColors: { [string]: string } = {}
	local arcTones: { [string]: string } = {}
	for _, a in Json.list(env, nodeOpts.arcs) do
		local fieldName = Json.str(env, Json.path(env, a, "field"))
		local color = Json.str(env, Json.path(env, a, "color"))
		if fieldName and color then
			arcColors[string.lower(fieldName)] = Thresholds.color(color, nil)
			arcTones[string.lower(fieldName)] = Charts.toneClass(Thresholds.tone(color))
		end
	end
	local g: Graph = { nodes = {}, edges = {}, legend = {}, stats = {}, hidden = 0 }
	local byId: { [string]: SvgNodeGraph.Node } = {}
	if nodesF then
		local nf = nodesF :: Frame
		local id = find(nf, "id") :: Field
		local title, subtitle = find(nf, "title"), find(nf, "subtitle")
		local main, secondary = find(nf, "mainstat"), find(nf, "secondarystat")
		local radius, hi = find(nf, "noderadius"), find(nf, "highlighted")
		local arcs: { { field: Field, color: string } } = {}
		for _, f in nf.fields do
			local lname = string.lower(f.name)
			if string.sub(lname, 1, 5) == "arc__" then
				local color = arcColors[lname]
				table.insert(arcs, { field = f, color = color or "" })
				if color then
					table.insert(
						g.legend,
						{ name = (f.config and f.config.displayName) or f.name, class = arcTones[lname] }
					)
				end
			end
		end
		if main then
			table.insert(g.stats, main.name)
		end
		if secondary then
			table.insert(g.stats, secondary.name)
		end
		for i, raw in id.values do
			local key = str(raw)
			if key == nil or byId[key] then
				continue
			end
			local sections: { SvgNodeGraph.Arc } = {}
			for _, a in arcs do
				local v = a.field.values[i]
				if a.color ~= "" and type(v) == "number" and v == v then
					table.insert(sections, { value = v, color = a.color })
				end
			end
			local r = if radius then radius.values[i] else nil
			local n: SvgNodeGraph.Node = {
				id = key,
				x = 0,
				y = 0,
				radius = if type(r) == "number" and r > 0 then r else nil,
				title = if title then str(title.values[i]) else nil,
				subtitle = if subtitle then str(subtitle.values[i]) else nil,
				main = if main then M.stat(main, main.values[i], Json.str(env, nodeOpts.mainStatUnit)) else nil,
				secondary = if secondary
					then M.stat(secondary, secondary.values[i], Json.str(env, nodeOpts.secondaryStatUnit))
					else nil,
				arcs = sections,
				highlighted = if hi then hi.values[i] == true else nil,
			}
			byId[key] = n
			table.insert(g.nodes, n)
		end
	end
	if edgesF then
		local ef = edgesF :: Frame
		local source, target = find(ef, "source"), find(ef, "target")
		local thick, dash, hi = find(ef, "thickness"), find(ef, "strokedasharray"), find(ef, "highlighted")
		if source and target then
			for i, s in source.values do
				local a, b = str(s), str(target.values[i])
				if a == nil or b == nil then
					continue
				end
				for _, endId in { a, b } do
					if nodesF == nil and byId[endId] == nil then
						local n: SvgNodeGraph.Node = { id = endId, x = 0, y = 0, title = endId, arcs = {} }
						byId[endId] = n
						table.insert(g.nodes, n)
					end
				end
				if byId[a] and byId[b] then
					local th = if thick then thick.values[i] else nil
					table.insert(g.edges, {
						source = a,
						target = b,
						thickness = if type(th) == "number" and th > 0 then th else nil,
						dash = if dash then str(dash.values[i]) else nil,
						highlighted = if hi then hi.values[i] == true else nil,
					})
				end
			end
		end
	end
	local _ = edgeOpts
	if #g.nodes > M.MAX_NODES then
		g.hidden = #g.nodes - M.MAX_NODES
		local keep: { [string]: boolean } = {}
		local nodes: { SvgNodeGraph.Node } = table.create(M.MAX_NODES)
		for i = 1, M.MAX_NODES do
			nodes[i] = g.nodes[i]
			keep[g.nodes[i].id] = true
		end
		local edges: { SvgNodeGraph.Edge } = {}
		for _, e in g.edges do
			if keep[e.source] and keep[e.target] then
				table.insert(edges, e)
			end
		end
		g.nodes, g.edges = nodes, edges
	end
	return g
end

-- Layered layout -----------------------------------------------------------------

type Vertex = { id: string, layer: number, order: number, y: number, real: boolean }

-- Positions every node (x, y) left to right by layers.
function M.layered(g: Graph)
	local n = #g.nodes
	if n == 0 then
		return
	end
	local index: { [string]: number } = {}
	for i, node in g.nodes do
		index[node.id] = i
	end
	local out: { { number } } = table.create(n)
	local incoming: { number } = table.create(n, 0)
	for i = 1, n do
		out[i] = {}
	end
	for _, e in g.edges do
		local a, b = index[e.source], index[e.target]
		if a and b and a ~= b then
			table.insert(out[a], b)
			incoming[b] += 1
		end
	end
	-- Longest path layers from the roots, back edges ignored (DFS order).
	local layer: { number } = table.create(n, -1)
	local state: { number } = table.create(n, 0)
	local function visit(v: number, depth: number)
		if state[v] == 1 then
			return
		end
		if depth <= layer[v] then
			return
		end
		layer[v] = depth
		state[v] = 1
		for _, w in out[v] do
			visit(w, depth + 1)
		end
		state[v] = 0
	end
	for v = 1, n do
		if incoming[v] == 0 then
			visit(v, 0)
		end
	end
	for v = 1, n do
		if layer[v] < 0 then
			visit(v, 0)
		end
	end
	-- Vertices per layer, with dummies on long edges.
	local maxLayer = 0
	for v = 1, n do
		maxLayer = math.max(maxLayer, layer[v])
	end
	local layers: { { Vertex } } = {}
	for l = 0, maxLayer do
		layers[l + 1] = {}
	end
	local vertex: { Vertex } = table.create(n)
	for v = 1, n do
		local vx: Vertex = { id = g.nodes[v].id, layer = layer[v], order = 0, y = 0, real = true }
		vertex[v] = vx
		table.insert(layers[layer[v] + 1], vx)
	end
	local up: { [Vertex]: { Vertex } } = {}
	local down: { [Vertex]: { Vertex } } = {}
	local function link(a: Vertex, b: Vertex)
		down[a] = down[a] or {}
		up[b] = up[b] or {}
		table.insert(down[a], b)
		table.insert(up[b], a)
	end
	for v = 1, n do
		for _, w in out[v] do
			local a, b = vertex[v], vertex[w]
			if b.layer <= a.layer then
				continue
			end
			local prev = a
			for l = a.layer + 1, b.layer - 1 do
				local d: Vertex = { id = "", layer = l, order = 0, y = 0, real = false }
				table.insert(layers[l + 1], d)
				link(prev, d)
				prev = d
			end
			link(prev, b)
		end
	end
	for _, list in layers do
		for i, vx in list do
			vx.order = i
		end
	end
	-- Barycenter ordering sweeps.
	local function sweep(list: { Vertex }, nbrs: { [Vertex]: { Vertex } })
		local key: { [Vertex]: number } = {}
		for _, vx in list do
			local ns = nbrs[vx]
			if ns and #ns > 0 then
				local sum = 0
				for _, w in ns do
					sum += w.order
				end
				key[vx] = sum / #ns
			else
				key[vx] = vx.order
			end
		end
		table.sort(list, function(a, b)
			if key[a] ~= key[b] then
				return key[a] < key[b]
			end
			-- Ties: long edges (dummies) first, so they stay straight and
			-- the nodes step aside, as Grafana's layered layout draws them.
			if a.real ~= b.real then
				return not a.real
			end
			return a.order < b.order
		end)
		for i, vx in list do
			vx.order = i
		end
	end
	for _ = 1, 4 do
		for l = 2, #layers do
			sweep(layers[l], up)
		end
		for l = #layers - 1, 1, -1 do
			sweep(layers[l], down)
		end
	end
	-- Initial y by order, then median alignment keeping order and spacing.
	for _, list in layers do
		for i, vx in list do
			vx.y = (i - 1) * M.SPACING_Y
		end
	end
	local function align(list: { Vertex }, nbrs: { [Vertex]: { Vertex } })
		local want: { number } = {}
		for i, vx in list do
			local ns = nbrs[vx]
			if ns and #ns > 0 then
				local ys: { number } = {}
				for _, w in ns do
					table.insert(ys, w.y)
				end
				table.sort(ys)
				want[i] = ys[(#ys + 1) // 2]
			else
				want[i] = vx.y
			end
		end
		-- Place top to bottom at the wanted y or below the previous.
		for i, vx in list do
			local y = want[i]
			if i > 1 then
				y = math.max(y, list[i - 1].y + M.SPACING_Y)
			end
			vx.y = y
		end
	end
	for _ = 1, 4 do
		for l = 2, #layers do
			align(layers[l], up)
		end
		for l = #layers - 1, 1, -1 do
			align(layers[l], down)
		end
	end
	for v = 1, n do
		g.nodes[v].x = vertex[v].layer * M.LAYER_X
		g.nodes[v].y = vertex[v].y
	end
end

-- Grid layout: rows of ceil(sqrt(n)) nodes.
function M.grid(g: Graph)
	local cols = math.max(1, math.ceil(math.sqrt(#g.nodes)))
	for i, node in g.nodes do
		node.x = ((i - 1) % cols) * M.GRID_X
		node.y = ((i - 1) // cols) * M.GRID_Y
	end
end

function M.view(panel: any, frames: { Frame }, env: Env, opts: Common.Options): (Node, Assets.Assets?)
	if not Common.hasData(frames) then
		return Common.noData(panel, env, opts.key), {}
	end
	local maybe = M.graph(panel, frames, env)
	if maybe == nil then
		return Common.noData(panel, env, opts.key), {}
	end
	local g = maybe :: Graph
	local algo = Json.str(env, Json.path(env, panel, "options", "layoutAlgorithm"))
	if algo == "grid" then
		M.grid(g)
	else
		M.layered(g)
	end
	local W, H = Charts.size(opts, M.WIDTH, M.HEIGHT)
	local legendRows: { Charts.Row } = {}
	for _, l in g.legend do
		table.insert(legendRows, { class = l.class, name = l.name, values = {} })
	end
	if #legendRows == 0 then
		for _, s in g.stats do
			table.insert(legendRows, { class = "tgn-swatch", name = s, values = {} })
		end
	end
	local svgH = if #legendRows > 0 then math.max(60, H - 24) else H
	local svg = SvgNodeGraph.render({ width = W, height = svgH, nodes = g.nodes, edges = g.edges })
	local chart, assets =
		Charts.image(opts.key, svg, W, svgH, Charts.alt(panel, env, "Node graph"), "tern-grafana.nodegraph")
	local legend: Node? = if #legendRows > 0 then Charts.legend(opts.key .. ".legend", legendRows, {}, "list") else nil
	local notes: { string } = {}
	if g.hidden > 0 then
		table.insert(notes, string.format("%d more nodes not shown", g.hidden))
	end
	return Charts.compose(opts.key, chart, legend, "bottom", notes), assets
end

return M
