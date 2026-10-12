--!strict
-- A geomap as SVG: Web Mercator (EPSG:3857, OpenLayers' default view, as
-- Grafana's geomap uses) over the bundled country outlines
-- (lib/render/world_outline), with markers and their labels
-- (public/app/plugins/panel/geomap/layers/data/markersLayer.tsx,
-- style/markers.ts):
-- - the view is a center (lon, lat) and a world width in px; the world
--   repeats left and right as OpenLayers' does;
-- - markers: circle, square, triangle, star, cross and x symbols with the
--   given radius, fill at the layer opacity, outline at full color;
--   labels with their font size, offset, alignment and baseline.
-- Land and borders are theme classes (tgm-*: panels2.css); marker colors
-- are Grafana's fixed colors as literal attributes; no <title>.

local Kit = require("./svg_kit")
local World = require("./world_outline")

local M = {}

local fmt = string.format

export type Marker = {
	lon: number,
	lat: number,
	radius: number,
	color: string,
	opacity: number,
	symbol: string?,
	text: string?,
	text_size: number?,
	offset_x: number?,
	offset_y: number?,
	text_align: string?,
	text_baseline: string?,
}

export type Options = {
	width: number,
	height: number,
	center_lon: number,
	center_lat: number,
	-- The world's width in px (256 * 2^zoom).
	world_px: number,
	markers: { Marker },
	basemap: boolean?,
}

-- Web Mercator: lon/lat to world units 0..1 (x east, y south).
function M.project(lon: number, lat: number): (number, number)
	local clamped = math.clamp(lat, -85.05112878, 85.05112878)
	local s = math.sin(math.rad(clamped))
	local x = (lon + 180) / 360
	local y = 0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)
	return x, y
end

local rings: { { number } }? = nil

-- Outline rings as projected world units (x, y pairs), parsed once.
local function outline(): { { number } }
	if rings then
		return rings :: { { number } }
	end
	local out: { { number } } = {}
	for _, s in World :: { string } do
		local ring: { number } = {}
		for lon, lat in string.gmatch(s, "(-?%d+),(-?%d+)") do
			local x, y = M.project((tonumber(lon) :: number) / 10, (tonumber(lat) :: number) / 10)
			table.insert(ring, x)
			table.insert(ring, y)
		end
		table.insert(out, ring)
	end
	rings = out
	return out
end

local function symbolPath(symbol: string, x: number, y: number, r: number): string?
	if symbol == "square" then
		return fmt("M%.1f %.1fh%.1fv%.1fh%.1fZ", x - r, y - r, 2 * r, 2 * r, -2 * r)
	elseif symbol == "triangle" then
		return fmt("M%.1f %.1fL%.1f %.1fL%.1f %.1fZ", x, y - r, x + r * 0.866, y + r / 2, x - r * 0.866, y + r / 2)
	elseif symbol == "star" then
		local parts: { string } = {}
		for i = 0, 9 do
			local rr = if i % 2 == 0 then r else r * 0.4
			local a = math.pi * i / 5 - math.pi / 2
			table.insert(
				parts,
				fmt("%s%.1f %.1f", if i == 0 then "M" else "L", x + rr * math.cos(a), y + rr * math.sin(a))
			)
		end
		return table.concat(parts) .. "Z"
	elseif symbol == "cross" then
		return fmt("M%.1f %.1fV%.1fM%.1f %.1fH%.1f", x, y - r, y + r, x - r, y, x + r)
	elseif symbol == "x" then
		local d = r * 0.707
		return fmt("M%.1f %.1fL%.1f %.1fM%.1f %.1fL%.1f %.1f", x - d, y - d, x + d, y + d, x - d, y + d, x + d, y - d)
	end
	return nil
end

function M.render(opts: Options): string
	local W, H = math.max(80, opts.width), math.max(60, opts.height)
	local world = opts.world_px
	local cx, cy = M.project(opts.center_lon, opts.center_lat)
	local function px(x: number, y: number): (number, number)
		return W / 2 + (x - cx) * world, H / 2 + (y - cy) * world
	end
	-- World copies that may show.
	local copies: { number } = {}
	local k0 = math.floor((-W / 2) / world + cx) - 1
	for k = k0, k0 + math.ceil(W / world) + 2 do
		local left = W / 2 + (k - cx) * world
		if left < W and left + world > 0 then
			table.insert(copies, k)
		end
	end
	local out: { string } = { Kit.open(W, H), fmt('<rect class="tgm-sea" x="0" y="0" width="%d" height="%d"/>', W, H) }
	if opts.basemap ~= false then
		local paths: { string } = {}
		for _, ring in outline() do
			for _, k in copies do
				local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
				local pts: { string } = table.create(#ring // 2)
				for i = 1, #ring, 2 do
					local x, y = px(ring[i] + k, ring[i + 1])
					minX, maxX = math.min(minX, x), math.max(maxX, x)
					minY, maxY = math.min(minY, y), math.max(maxY, y)
					table.insert(pts, fmt("%d %d", math.floor(x + 0.5), math.floor(y + 0.5)))
				end
				if maxX >= 0 and minX <= W and maxY >= 0 and minY <= H then
					table.insert(paths, "M" .. table.concat(pts, "L") .. "Z")
				end
			end
		end
		table.insert(
			out,
			'<path class="tgm-land" stroke-width="0.6" stroke-linejoin="round" d="' .. table.concat(paths) .. '"/>'
		)
	end
	local texts: { string } = {}
	for _, m in opts.markers do
		local wx, wy = M.project(m.lon, m.lat)
		for _, k in copies do
			local x, y = px(wx + k, wy)
			if x < -m.radius or x > W + m.radius or y < -m.radius or y > H + m.radius then
				continue
			end
			local symbol = m.symbol or "circle"
			local d = symbolPath(symbol, x, y, m.radius)
			if d then
				local open = symbol == "cross" or symbol == "x"
				table.insert(
					out,
					fmt(
						'<path d="%s" fill="%s" fill-opacity="%.2f" stroke="%s" stroke-opacity="%.2f" stroke-width="1"/>',
						d,
						if open then "none" else m.color,
						m.opacity,
						m.color,
						m.opacity
					)
				)
			else
				table.insert(
					out,
					fmt(
						'<circle cx="%.1f" cy="%.1f" r="%.1f" fill="%s" fill-opacity="%.2f" stroke="%s" stroke-opacity="%.2f" stroke-width="1"/>',
						x,
						y,
						m.radius,
						m.color,
						m.opacity,
						m.color,
						m.opacity
					)
				)
			end
			if m.text and m.text ~= "" then
				local align = m.text_align or "center"
				local anchor = if align == "left" or align == "start"
					then "start"
					elseif align == "right" or align == "end" then "end"
					else "middle"
				local base = m.text_baseline or "middle"
				local dom = if base == "top" then "hanging" elseif base == "bottom" then "text-after-edge" else "central"
				table.insert(
					texts,
					Kit.text(x + (m.offset_x or 0), y + (m.offset_y or 0), m.text :: string, {
						anchor = anchor :: any,
						size = m.text_size or 12,
						class = "tgm-text",
						attrs = fmt('dominant-baseline="%s" fill="%s"', dom, m.color),
					})
				)
			end
		end
	end
	for _, t in texts do
		table.insert(out, t)
	end
	return Kit.finish(out, "geomap")
end

return M
