--!strict
-- The geomap panel, natively for markers layers
-- (public/app/plugins/panel/geomap: GeomapPanel.tsx initMapView/
-- initViewExtent, view.ts centerPointRegistry, layers/data/markersLayer.tsx,
-- style/markers.ts, style/utils.ts; public/app/features/geo/utils/
-- location.ts; public/app/features/dimensions/scale.ts):
-- - the basemap: Grafana draws raster map tiles (CARTO by default) that
--   Tern cannot fetch and composite into one image, so every basemap is
--   drawn as the bundled Natural Earth country outlines
--   (lib/render/world_outline) in the same Web Mercator projection;
-- - the view: zero, coords (lat/lon), the named regions and fit (the
--   markers' extent with padding, zoom capped at view.zoom or 15); the
--   world is at least the panel's width wide, as Grafana's render shows it;
-- - markers layers: location auto (lat/latitude, lon/lng/longitude,
--   geohash fields), coords and geohash modes; style color (fixed or a
--   field's display color: thresholds, mappings), opacity, size (fixed or
--   a field scaled linearly from its range into min..max), symbol (circle,
--   square, triangle, star, cross, x from the marker icon name), text
--   (fixed or field) with textConfig; the layer legend with the color
--   field's threshold steps;
-- - other layer types (heatmap, geojson, route, photos, network, last
--   point, day/night, XYZ tile overlays) and gazetteer lookup locations
--   keep the panel on the PNG/browser ladder.

local Assets = require("../render/assets")
local Charts = require("./charts")
local Common = require("./common")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Frame = require("../frame/types")
local Json = require("./json")
local StateTimeline = require("./statetimeline")
local SvgGeomap = require("../render/svg_geomap")
local Thresholds = require("../units/thresholds")
local ui = require("../ui")

type Env = Env.Env
type Frame = Frame.Frame
type Field = Frame.Field
type Item = FieldConfig.Item
type Node = ui.Node

local M = {}

M.types = { "geomap" }

M.WIDTH = 960
M.HEIGHT = 300
M.TILE = 256

-- centerPointRegistry entries with a fixed center.
M.CENTERS = {
	zero = { lat = 0, lon = 0 },
	["north-america"] = { lat = 40, lon = -100 },
	["south-america"] = { lat = -20, lon = -60 },
	europe = { lat = 46, lon = 14 },
	africa = { lat = 0, lon = 30 },
	["west-asia"] = { lat = 26, lon = 53 },
	["s-asia"] = { lat = 19.5, lon = 80 },
	["se-asia"] = { lat = 10, lon = 106 },
	["e-asia"] = { lat = 33, lon = 120 },
	australia = { lat = -25, lon = 135 },
	oceania = { lat = -10, lon = -140 },
} :: { [string]: { lat: number, lon: number } }

local function layers(panel: any, env: Env): { any }
	local list = Json.list(env, Json.path(env, panel, "options", "layers"))
	if #list == 0 then
		-- Grafana's default data layer.
		return { { type = "markers", config = {} } }
	end
	return list
end

function M.supports(panel: any, env: Env): (boolean, string?)
	for _, l in layers(panel, env) do
		local kind = Json.str(env, Json.path(env, l, "type")) or "markers"
		if kind ~= "markers" then
			return false, string.format("geomap %s layers are not drawn natively", kind)
		end
		local mode = Json.str(env, Json.path(env, l, "location", "mode")) or "auto"
		if mode ~= "auto" and mode ~= "coords" and mode ~= "geohash" then
			return false, string.format("geomap %s locations are not drawn natively", mode)
		end
	end
	return true, nil
end

local BASE32 = "0123456789bcdefghjkmnpqrstuvwxyz"

-- A geohash's cell center, or nil.
function M.geohash(s: string): (number?, number?)
	local latLo, latHi, lonLo, lonHi = -90, 90, -180, 180
	local even = true
	for i = 1, #s do
		local idx = string.find(BASE32, string.lower(string.sub(s, i, i)), 1, true)
		if idx == nil then
			return nil, nil
		end
		local bits = idx - 1
		for b = 4, 0, -1 do
			local bit = bit32.band(bit32.rshift(bits, b), 1)
			if even then
				local mid = (lonLo + lonHi) / 2
				if bit == 1 then
					lonLo = mid
				else
					lonHi = mid
				end
			else
				local mid = (latLo + latHi) / 2
				if bit == 1 then
					latLo = mid
				else
					latHi = mid
				end
			end
			even = not even
		end
	end
	return (latLo + latHi) / 2, (lonLo + lonHi) / 2
end

local function itemNamed(items: { Item }, frame: Frame, name: string?): Item?
	if name == nil or name == "" then
		return nil
	end
	for _, it in items do
		if it.frame == frame and (it.field.name == name or it.name == name) then
			return it
		end
	end
	return nil
end

local function itemMatching(items: { Item }, frame: Frame, names: { [string]: boolean }): Item?
	for _, it in items do
		if it.frame == frame and names[string.lower(it.field.name)] then
			return it
		end
	end
	return nil
end

local LAT = { latitude = true, lat = true }
local LON = { longitude = true, lon = true, lng = true }
local GEOHASH = { geohash = true }

local function symbolOf(raw: string?): string
	local name = if raw then string.match(raw, "([%w%-_]+)%.svg$") else nil
	if name == "square" or name == "triangle" or name == "star" or name == "cross" or name == "x" then
		return name
	end
	return "circle"
end

local function hexColor(name: string, theme: Thresholds.Theme?): string
	return Thresholds.color(name, theme)
end

local function finite(v: any): number?
	return Frame.finite(v)
end

-- The markers of one layer over every frame, and its legend.
local function markers(
	layer: any,
	frames: { Frame },
	items: { Item },
	env: Env,
	opts: Common.Options
): ({ SvgGeomap.Marker }, Item?)
	local cfg = Json.obj(env, Json.path(env, layer, "config"))
	local style = Json.obj(env, cfg.style)
	local loc = Json.obj(env, layer.location)
	local mode = Json.str(env, loc.mode) or "auto"
	local colorCfg = Json.obj(env, style.color)
	local sizeCfg = Json.obj(env, style.size)
	local textCfg = Json.obj(env, style.text)
	local tc = Json.obj(env, style.textConfig)
	local opacity = Json.num(env, style.opacity) or 0.4
	local fixedColor = hexColor(Json.str(env, colorCfg.fixed) or "dark-green", opts.theme)
	local fixedSize = Json.num(env, sizeCfg.fixed) or 5
	local sizeMin, sizeMax = Json.num(env, sizeCfg.min) or 2, Json.num(env, sizeCfg.max) or 15
	local symbol = symbolOf(Json.str(env, Json.path(env, style, "symbol", "fixed")))
	local out: { SvgGeomap.Marker } = {}
	local colorItem: Item? = nil
	for _, frame in frames do
		local latI: Item?, lonI: Item?, hashI: Item? = nil, nil, nil
		if mode == "coords" then
			latI = itemNamed(items, frame, Json.str(env, loc.latitude))
			lonI = itemNamed(items, frame, Json.str(env, loc.longitude))
		elseif mode == "geohash" then
			hashI = itemNamed(items, frame, Json.str(env, loc.geohash))
		else
			latI, lonI = itemMatching(items, frame, LAT), itemMatching(items, frame, LON)
			if latI == nil or lonI == nil then
				hashI = itemMatching(items, frame, GEOHASH)
			end
		end
		if (latI == nil or lonI == nil) and hashI == nil then
			continue
		end
		local cItem = itemNamed(items, frame, Json.str(env, colorCfg.field))
		colorItem = colorItem or cItem
		local sItem = itemNamed(items, frame, Json.str(env, sizeCfg.field))
		local tItem = itemNamed(items, frame, Json.str(env, textCfg.field))
		local sLo, sHi = math.huge, -math.huge
		if sItem then
			local si = sItem :: Item
			sLo = si.config.min or math.huge
			sHi = si.config.max or -math.huge
			if si.config.min == nil or si.config.max == nil then
				for _, v in si.field.values do
					local n = finite(v)
					if n then
						if si.config.min == nil then
							sLo = math.min(sLo, n)
						end
						if si.config.max == nil then
							sHi = math.max(sHi, n)
						end
					end
				end
			end
		end
		local rows = #frame.fields[1].values
		local seen: { [string]: boolean } = {}
		for i = 1, rows do
			local lat: number?, lon: number? = nil, nil
			if latI and lonI then
				lat, lon = finite((latI :: Item).field.values[i]), finite((lonI :: Item).field.values[i])
			elseif hashI then
				local h = (hashI :: Item).field.values[i]
				if type(h) == "string" then
					lat, lon = M.geohash(h)
				end
			end
			if lat == nil or lon == nil then
				continue
			end
			local color = fixedColor
			if cItem then
				local d = FieldConfig.display(cItem :: Item, (cItem :: Item).field.values[i], { theme = opts.theme })
				color = if d.color ~= "" then d.color else fixedColor
			end
			local radius = fixedSize
			if sItem then
				local delta = sHi - sLo
				local v = finite((sItem :: Item).field.values[i])
				if sizeMax - sizeMin <= 0 or delta <= 0 or v == nil then
					radius = sizeMin
				else
					radius = sizeMin + math.clamp(((v :: number) - sLo) / delta, 0, 1) * (sizeMax - sizeMin)
				end
			end
			local text: string? = Json.str(env, textCfg.fixed)
			if tItem then
				text = FieldConfig.joined(FieldConfig.display(tItem :: Item, (tItem :: Item).field.values[i], {}))
			end
			local key = string.format("%g,%g|%s|%g|%s", lat :: number, lon :: number, color, radius, text or "")
			if seen[key] then
				continue
			end
			seen[key] = true
			table.insert(out, {
				lon = lon :: number,
				lat = lat :: number,
				radius = radius,
				color = color,
				opacity = opacity,
				symbol = symbol,
				text = text,
				text_size = Json.num(env, tc.fontSize),
				offset_x = Json.num(env, tc.offsetX),
				offset_y = Json.num(env, tc.offsetY),
				text_align = Json.str(env, tc.textAlign),
				text_baseline = Json.str(env, tc.textBaseline),
			})
		end
	end
	return out, colorItem
end

-- The view center and world width in px (initViewExtent).
function M.viewOf(panel: any, env: Env, all: { SvgGeomap.Marker }, w: number, h: number): (number, number, number)
	local view = Json.obj(env, Json.path(env, panel, "options", "view"))
	local id = Json.str(env, view.id) or "zero"
	local zoom = Json.num(env, view.zoom)
	local lon, lat = 0, 0
	local world = M.TILE * 2 ^ (zoom or 1)
	if id == "coords" then
		lat, lon = Json.num(env, view.lat) or 0, Json.num(env, view.lon) or 0
	elseif id == "fit" and #all > 0 then
		local x0, x1, y0, y1 = math.huge, -math.huge, math.huge, -math.huge
		for _, m in all do
			local x, y = SvgGeomap.project(m.lon, m.lat)
			x0, x1, y0, y1 = math.min(x0, x), math.max(x1, x), math.min(y0, y), math.max(y1, y)
		end
		local maxWorld = M.TILE * 2 ^ (zoom or Json.num(env, view.maxZoom) or 15)
		local fit = math.min(if x1 > x0 then w / (x1 - x0) else math.huge, if y1 > y0 then h / (y1 - y0) else math.huge)
		local padding = Json.num(env, view.padding) or 5
		world = math.min(maxWorld, fit / (1 + padding / 100))
		-- Center of the extent, back to lon/lat.
		local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
		lon = cx * 360 - 180
		lat = math.deg(math.atan(math.sinh(math.pi * (1 - 2 * cy))))
	else
		local c = M.CENTERS[id]
		if c then
			lat, lon = c.lat, c.lon
		end
	end
	return lon, lat, math.max(world, w)
end

function M.view(panel: any, frames: { Frame }, env: Env, opts: Common.Options): (Node, Assets.Assets?)
	local items = FieldConfig.resolve(panel, frames, env)
	local all: { SvgGeomap.Marker } = {}
	local legendRows: { Charts.Row } = {}
	for _, layer in layers(panel, env) do
		local ms, colorItem = markers(layer, frames, items, env, opts)
		for _, m in ms do
			table.insert(all, m)
		end
		local showLegend = Json.bool(env, Json.path(env, layer, "config", "showLegend")) ~= false
		if showLegend and colorItem then
			local ci = colorItem :: Item
			if ci.config.color_mode == "thresholds" then
				local labels = StateTimeline.thresholdLabels(ci.config)
				for k, step in ci.config.thresholds.steps do
					table.insert(
						legendRows,
						{ class = Charts.toneClass(Thresholds.tone(step.color)), name = labels[k], values = {} }
					)
				end
			end
		end
	end
	local W, H = Charts.size(opts, M.WIDTH, M.HEIGHT)
	local svgH = if #legendRows > 0 then math.max(60, H - 24) else H
	local lon, lat, world = M.viewOf(panel, env, all, W, svgH)
	local basemap = Json.tbl(env, Json.path(env, panel, "options", "basemap"))
	local svg = SvgGeomap.render({
		width = W,
		height = svgH,
		center_lon = lon,
		center_lat = lat,
		world_px = world,
		markers = all,
		basemap = basemap == nil or Json.str(env, basemap.type) ~= "none",
	})
	local chart, assets = Charts.image(opts.key, svg, W, svgH, Charts.alt(panel, env, "Geomap"), "tern-grafana.geomap")
	local legend: Node? = if #legendRows > 0 then Charts.legend(opts.key .. ".legend", legendRows, {}, "list") else nil
	return Charts.compose(opts.key, chart, legend, "bottom"), assets
end

return M
