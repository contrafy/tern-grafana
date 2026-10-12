--!strict
-- The canvas panel (public/app/plugins/panel/canvas, public/app/features/
-- canvas/runtime/element.tsx applyLayoutStylesToDiv, frame.tsx, the
-- elements under public/app/features/canvas/elements and the dimension
-- suppliers in public/app/features/dimensions):
-- - options.root is a frame of elements; each element is placed by its
--   constraint against its parent frame (left/right/leftright/center/scale
--   horizontally, top/bottom/topbottom/center/scale vertically, px or
--   percent for scale, center offsets from the middle) and rotated by
--   placement.rotation; nested frames place their children inside them;
-- - element types rectangle, ellipse, triangle, text and metric-value:
--   background color, border (width, color, radius), and a text line with
--   config.text (fixed, a field's last value through its display
--   processor, or a template through dashboard variables), config.color
--   (fixed or the field's display color), size, align and valign;
-- - connections drawn straight from source to target anchor with their
--   color, size and an arrow head;
-- - other element types (icons, buttons, server, wind turbine, drones,
--   cloud, parallelogram), background images and curved connections keep
--   the panel on the PNG/browser ladder.

local Assets = require("../render/assets")
local Charts = require("./charts")
local Common = require("./common")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Frame = require("../frame/types")
local Json = require("./json")
local SvgCanvas = require("../render/svg_canvas")
local Thresholds = require("../units/thresholds")
local ui = require("../ui")

type Env = Env.Env
type Frame = Frame.Frame
type Item = FieldConfig.Item
type Node = ui.Node

local M = {}

M.types = { "canvas" }

M.WIDTH = 960
M.HEIGHT = 300

local KINDS: { [string]: "rect" | "ellipse" | "triangle" | "none" } = {
	rectangle = "rect",
	ellipse = "ellipse",
	triangle = "triangle",
	text = "rect",
	["metric-value"] = "rect",
	frame = "rect",
}

-- Default text size per element type (the elements' defaultConfig).
local TEXT_SIZE: { [string]: number } = {
	rectangle = 16,
	ellipse = 16,
	triangle = 16,
	text = 16,
	["metric-value"] = 20,
}

local function unsupportedIn(el: any, env: Env): string?
	local kind = Json.str(env, el.type) or ""
	if KINDS[kind] == nil then
		return string.format("canvas element type %s is not drawn natively", kind)
	end
	local image = Json.path(env, el, "background", "image")
	if Json.tbl(env, image) and (Json.str(env, image.fixed) or Json.str(env, image.field)) then
		return "canvas background images are not drawn natively"
	end
	for _, c in Json.list(env, el.connections) do
		local path = Json.str(env, Json.path(env, c, "path"))
		if path and path ~= "straight" then
			return string.format("canvas %s connections are not drawn natively", path)
		end
	end
	for _, child in Json.list(env, el.elements) do
		local why = unsupportedIn(child, env)
		if why then
			return why
		end
	end
	return nil
end

function M.supports(panel: any, env: Env): (boolean, string?)
	local root = Json.tbl(env, Json.path(env, panel, "options", "root"))
	if root == nil then
		return true, nil
	end
	local why = unsupportedIn(root, env)
	return why == nil, why
end

export type Box = { x: number, y: number, w: number, h: number }

-- The element's box in its parent (applyLayoutStylesToDiv).
function M.place(el: any, parent: Box, env: Env): Box
	local p = Json.obj(env, el.placement)
	local c = Json.obj(env, el.constraint)
	local horizontal = Json.str(env, c.horizontal) or "left"
	local vertical = Json.str(env, c.vertical) or "top"
	local function n(v: any, default: number): number
		return Json.num(env, v) or default
	end
	local x: number, w: number
	if horizontal == "right" then
		w = n(p.width, 100)
		x = parent.w - n(p.right, 0) - w
	elseif horizontal == "leftright" then
		x = n(p.left, 0)
		w = parent.w - x - n(p.right, 0)
	elseif horizontal == "center" then
		w = n(p.width, 100)
		x = parent.w / 2 - n(p.left, 0) - w / 2
	elseif horizontal == "scale" then
		x = parent.w * n(p.left, 0) / 100
		w = parent.w - x - parent.w * n(p.right, 0) / 100
	else
		x = n(p.left, 0)
		w = n(p.width, 100)
	end
	local y: number, h: number
	if vertical == "bottom" then
		h = n(p.height, 100)
		y = parent.h - n(p.bottom, 0) - h
	elseif vertical == "topbottom" then
		y = n(p.top, 0)
		h = parent.h - y - n(p.bottom, 0)
	elseif vertical == "center" then
		h = n(p.height, 100)
		y = parent.h / 2 - n(p.top, 0) - h / 2
	elseif vertical == "scale" then
		y = parent.h * n(p.top, 0) / 100
		h = parent.h - y - parent.h * n(p.bottom, 0) / 100
	else
		y = n(p.top, 0)
		h = n(p.height, 100)
	end
	-- Minimum element size is 10x10.
	return { x = parent.x + x, y = parent.y + y, w = math.max(10, w), h = math.max(10, h) }
end

local function itemNamed(items: { Item }, name: string?): Item?
	if name == nil or name == "" then
		return nil
	end
	for _, it in items do
		if it.field.name == name or it.name == name then
			return it
		end
	end
	return nil
end

local function lastValue(item: Item): any
	local vs = item.field.values
	for i = #vs, 1, -1 do
		if not Frame.isNull(vs[i]) then
			return vs[i]
		end
	end
	return nil
end

type Ctx = { items: { Item }, env: Env, opts: Common.Options }

local function color(dim: any, ctx: Ctx, fallback: string?): string?
	local d = Json.obj(ctx.env, dim)
	local it = itemNamed(ctx.items, Json.str(ctx.env, d.field))
	if it then
		local disp = FieldConfig.display(it :: Item, lastValue(it :: Item), { theme = ctx.opts.theme })
		if disp.color ~= "" then
			return disp.color
		end
	end
	local fixed = Json.str(ctx.env, d.fixed)
	if fixed then
		return Thresholds.color(fixed, ctx.opts.theme)
	end
	return fallback
end

local function text(dim: any, ctx: Ctx): string?
	local d = Json.obj(ctx.env, dim)
	local mode = Json.str(ctx.env, d.mode) or "fixed"
	if mode == "field" then
		local it = itemNamed(ctx.items, Json.str(ctx.env, d.field))
		if it == nil then
			return nil
		end
		local disp = FieldConfig.display(it :: Item, lastValue(it :: Item), { offset_min = ctx.opts.offset_min })
		return FieldConfig.joined(disp)
	end
	local fixed = Json.str(ctx.env, d.fixed)
	if mode == "template" and fixed and ctx.opts.interpolate then
		return (ctx.opts.interpolate :: (string) -> string)(fixed)
	end
	return fixed
end

type Placed = { name: string, box: Box }

local function collect(
	el: any,
	parent: Box,
	ctx: Ctx,
	shapes: { SvgCanvas.Shape },
	placed: { Placed },
	pending: { { el: any, box: Box } },
	isRoot: boolean
)
	local env = ctx.env
	local kind = Json.str(env, el.type) or "rectangle"
	local box = if isRoot then parent else M.place(el, parent, env)
	local cfg = Json.obj(env, el.config)
	local border = Json.obj(env, el.border)
	local textColorDefault = Thresholds.color("text", ctx.opts.theme)
	table.insert(shapes, {
		kind = if kind == "frame" then "rect" else KINDS[kind] or "rect",
		x = box.x,
		y = box.y,
		w = box.w,
		h = box.h,
		rotation = Json.num(env, Json.path(env, el, "placement", "rotation")),
		fill = color(Json.path(env, el, "background", "color"), ctx, nil),
		stroke = color(border.color, ctx, nil),
		stroke_width = Json.num(env, border.width) or 0,
		radius = Json.num(env, border.radius),
		text = if kind ~= "frame" then text(cfg.text, ctx) else nil,
		text_color = color(cfg.color, ctx, textColorDefault),
		text_size = Json.num(env, cfg.size) or TEXT_SIZE[kind],
		align = Json.str(env, cfg.align),
		valign = Json.str(env, cfg.valign),
	})
	table.insert(placed, { name = Json.str(env, el.name) or "", box = box })
	if #Json.list(env, el.connections) > 0 then
		table.insert(pending, { el = el, box = box })
	end
	if kind == "frame" then
		for _, child in Json.list(env, el.elements) do
			collect(child, box, ctx, shapes, placed, pending, false)
		end
	end
end

-- A connection anchor: x, y in -1..1 from the box center (y up).
local function anchor(box: Box, pt: any, env: Env): (number, number)
	local x = Json.num(env, Json.path(env, pt, "x")) or 0
	local y = Json.num(env, Json.path(env, pt, "y")) or 0
	return box.x + box.w / 2 + x * box.w / 2, box.y + box.h / 2 - y * box.h / 2
end

function M.layout(
	panel: any,
	frames: { Frame },
	env: Env,
	opts: Common.Options,
	w: number,
	h: number
): SvgCanvas.Options
	local ctx: Ctx = { items = FieldConfig.resolve(panel, frames, env), env = env, opts = opts }
	local shapes: { SvgCanvas.Shape } = {}
	local placed: { Placed } = {}
	local pending: { { el: any, box: Box } } = {}
	local rootBox: Box = { x = 0, y = 0, w = w, h = h }
	local root = Json.tbl(env, Json.path(env, panel, "options", "root"))
	if root then
		collect(root, rootBox, ctx, shapes, placed, pending, true)
	end
	local lines: { SvgCanvas.Line } = {}
	for _, p in pending do
		for _, c in Json.list(env, p.el.connections) do
			local x1, y1 = anchor(p.box, Json.path(env, c, "source"), env)
			local targetName = Json.str(env, Json.path(env, c, "targetName"))
			local targetBox = rootBox
			if targetName then
				for _, pl in placed do
					if pl.name == targetName then
						targetBox = pl.box
						break
					end
				end
			end
			local x2, y2 = anchor(targetBox, Json.path(env, c, "target"), env)
			table.insert(lines, {
				x1 = x1,
				y1 = y1,
				x2 = x2,
				y2 = y2,
				color = color(Json.path(env, c, "color"), ctx, Thresholds.color("text", opts.theme)) :: string,
				width = Json.num(env, Json.path(env, c, "size", "fixed")) or 2,
				arrow = Json.str(env, Json.path(env, c, "direction")) ~= "none",
			})
		end
	end
	return { width = w, height = h, shapes = shapes, lines = lines }
end

function M.view(panel: any, frames: { Frame }, env: Env, opts: Common.Options): (Node, Assets.Assets?)
	local W, H = Charts.size(opts, M.WIDTH, M.HEIGHT)
	local svg = SvgCanvas.render(M.layout(panel, frames, env, opts, W, H))
	local chart, assets = Charts.image(opts.key, svg, W, H, Charts.alt(panel, env, "Canvas"), "tern-grafana.canvas")
	return Charts.compose(opts.key, chart, nil, "bottom"), assets
end

return M
