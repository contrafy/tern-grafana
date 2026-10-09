--!strict
-- Grafana's solo panel URLs: `/render/d-solo/<uid>/<slug>` (the image
-- renderer, ladder rung B) and `/d-solo/<uid>/<slug>` (the page, rung A).
-- Parameters as Grafana's own "share panel as image" link writes them:
-- orgId, panelId, width, height, from, to, tz, theme, then var-<name> per
-- value. Range ends are passed as written ("now-1h"), so Grafana resolves
-- them the same way it resolves the dashboard.

local Scheme = require("../links/scheme")
local TransportTypes = require("../transport/types")

type Request = TransportTypes.Request

local M = {}

-- Grafana's grid: 24 columns, 30 px rows with 8 px margins.
M.ROW_PX = 30
M.MARGIN_PX = 8
-- The dashboard width panels are rendered for (a typical desktop dashboard).
M.DESIGN_WIDTH = 1600
M.MIN_WIDTH = 320

export type Spec = {
	uid: string,
	slug: string,
	panel_id: number,
	org_id: number?,
	from: string,
	to: string,
	width: number?,
	height: number?,
	-- IANA zone or "UTC"; nil lets Grafana use its own.
	tz: string?,
	theme: string?,
	vars: { [string]: { string } },
}

-- The pixel size Grafana gives a panel of this grid size on a dashboard
-- `design_width` wide.
function M.size(w: number, h: number, design_width: number?): (number, number)
	local width = math.max(M.MIN_WIDTH, math.floor((design_width or M.DESIGN_WIDTH) * w / 24 + 0.5))
	local height = h * M.ROW_PX + math.max(0, h - 1) * M.MARGIN_PX
	return width, height
end

-- The render API's `tz` for a dashboard timezone: "utc" -> "UTC", an IANA
-- zone as is, "browser"/"" -> nil (the renderer has no browser to ask).
function M.tz(timezone: string): string?
	if timezone == "" or timezone == "browser" then
		return nil
	elseif string.lower(timezone) == "utc" then
		return "UTC"
	end
	return timezone
end

local function sortedNames(t: { [string]: any }): { string }
	local names = {}
	for k in t do
		table.insert(names, k)
	end
	table.sort(names)
	return names
end

local function int(n: number): string
	return string.format("%d", math.floor(n))
end

local function pairsFor(spec: Spec, render: boolean): { { string } }
	local out: { { string } } = {}
	if spec.org_id then
		table.insert(out, { "orgId", int(spec.org_id) })
	end
	table.insert(out, { "panelId", int(spec.panel_id) })
	if render and spec.width and spec.height then
		table.insert(out, { "width", int(spec.width) })
		table.insert(out, { "height", int(spec.height) })
	end
	table.insert(out, { "from", spec.from })
	table.insert(out, { "to", spec.to })
	if spec.tz then
		table.insert(out, { if render then "tz" else "timezone", spec.tz })
	end
	if spec.theme then
		table.insert(out, { "theme", spec.theme })
	end
	for _, name in sortedNames(spec.vars) do
		for _, v in spec.vars[name] do
			table.insert(out, { "var-" .. name, v })
		end
	end
	return out
end

local function path(prefix: string, spec: Spec): string
	return prefix .. Scheme.percentEncode(spec.uid) .. "/" .. Scheme.percentEncode(spec.slug)
end

-- The render API request (PNG body).
function M.request(spec: Spec): Request
	return { method = "GET", path = path("/render/d-solo/", spec), query = pairsFor(spec, true) }
end

-- The solo panel page under `base` (the Grafana browser URL) for the browser pane.
function M.soloUrl(base: string, spec: Spec): string
	local parts: { string } = {}
	for _, p in pairsFor(spec, false) do
		table.insert(parts, Scheme.percentEncode(p[1]) .. "=" .. Scheme.percentEncode(p[2]))
	end
	return base .. path("/d-solo/", spec) .. "?" .. table.concat(parts, "&")
end

-- Cache identity of a render: panel, range, size, theme and variables.
function M.cacheKey(spec: Spec): string
	local parts: { string } = { spec.uid, int(spec.panel_id) }
	for _, p in pairsFor(spec, true) do
		table.insert(parts, p[1] .. "=" .. p[2])
	end
	return table.concat(parts, "\31")
end

return M
