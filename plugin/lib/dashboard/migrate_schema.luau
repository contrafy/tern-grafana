--!strict
-- Grafana's dashboard schema migration: a dashboard saved by an older
-- Grafana (schemaVersion below 42, or none at all) reads the way Grafana
-- shows it. Ported from v12.4.0 public/app/features/dashboard/state/
-- DashboardMigrator.ts (updateSchema: the dashboard steps in order, then the
-- panel steps over every panel and every collapsed row's panel) and the
-- DashboardModel constructor around it (unique panel ids, panels sorted by
-- gridPos, a refId for every target: PanelModel). Grafana 12 and 13 load
-- dashboards through the app platform API, whose backend runs the same steps
-- (apps/dashboard/pkg/migration: migrate.go and schemaversion; its v1beta1
-- answer is the specs' oracle) and answers
-- the result as a save model, without the copies of repeated panels a saved
-- dashboard may still hold; where the backend and the browser differ this
-- follows the backend: the legacy rows' panels get unique ids too, mapping
-- lists already in the new format stay as they are (V30) and a minSpan
-- wider than the grid sets maxPerRow 1 (V17).
--
-- Steps that change what Tern reads:
--   2  services.filter becomes the time range and the variables
--   6  annotation pulldowns become annotations; untyped and "filter"
--      variables are query variables
--   10 table styles with three or more thresholds drop the first
--   12 boolean variable refresh; hideVariable/hideLabel become hide
--   16 top-level `rows` become row panels and panels with gridPos
--   17 minSpan becomes maxPerRow
--   19 panel links by dashboard, dashUri, keepTime, includeVars, params
--   22 table styles align auto
--   24 table panels with styles are table-old, which lib/panels/migrate
--      turns into a table as Grafana's auto-migration does
--   26 text2 is text
--   27 leftover copies of repeated panels go; constants shown in the
--      variable bar become textboxes
--   30 old value mappings; tooltipOptions of timeseries and xychart
--   31 a merge after each labelsToFields
--   35 a timeseries with hidden axes keeps its time axis
--   42 hideFrom.viz hides from the tooltip too
-- The rest change nothing Tern reads: 7 and 41 (timepicker), 8 (InfluxQL
-- runs in the browser), 14 (graphTooltip), 18 (the 6.0 gauge's options),
-- 20 and 21 (graph dataLinks and fieldOptions, which the panel migrations
-- drop), 23, 28 and 29 (a variable's current shape, tags, saved options
-- and refresh: lib/dashboard/variables reads either shape and fetches query
-- variables on load), 33 and 36 (datasource names and null:
-- lib/dashboard/queries resolves them as getInstanceSettings does), 34
-- (CloudWatch), 37 (both ways of hiding a legend read the same), 38
-- (lib/panels/table reads a legacy displayMode), 39 (timeSeriesTable is not
-- drawn natively) and 40 (a refresh that is no string is off).
--
-- Decoded JSON is never changed: the result, its lists and every table a
-- step edits are copies. A dashboard at the latest version keeps its panel
-- tables, which the panel registry caches by identity.

local Env = require("../env")
local Json = require("../panels/json")
local Migrate = require("../panels/migrate")
local Tbl = require("../tbl")

type Env = Env.Env
type Obj = { [any]: any }

local M = {}

-- DASHBOARD_SCHEMA_VERSION, the last v1 schema.
M.LATEST = 42

-- app/core/constants.
local GRID_COLUMN_COUNT = 24
local GRID_CELL_HEIGHT = 30
local GRID_CELL_VMARGIN = 8
local MIN_PANEL_HEIGHT = GRID_CELL_HEIGHT * 3
local DEFAULT_ROW_HEIGHT = 250
local DEFAULT_PANEL_SPAN = 4
-- getFactors(GRID_COLUMN_COUNT), ascending.
local FACTORS = { 1, 2, 3, 4, 6, 8, 12, 24 }

local truthy = Migrate.truthy

-- `l` tagged as a JSON array, so an empty one still encodes as `[]`.
local function array(env: Env, l: { any }): { any }
	return if env.array then env.array(l) else l
end

local function copyList(env: Env, l: { any }): { any }
	return array(env, Tbl.copy(l))
end

-- Dashboard steps ---------------------------------------------------------------

-- V2, V6, V12 and V27 on the variables.
local function migrateVariables(env: Env, version: number, out: Obj)
	local templating = Json.tbl(env, out.templating)
	local vars = if templating then Json.tbl(env, templating.list) else nil
	if templating == nil or vars == nil then
		return
	end
	local list = array(env, {})
	for _, raw in vars do
		local v = Json.tbl(env, raw)
		if v == nil then
			table.insert(list, raw)
			continue
		end
		local c: Obj = Tbl.copy(v)
		if version < 6 and (c.type == nil or c.type == "filter") then
			c.type = "query"
		end
		if version < 12 then
			if c.refresh ~= nil then
				c.refresh = if truthy(env, c.refresh) then 1 else 0
			end
			if truthy(env, c.hideVariable) then
				c.hide = 2
			elseif truthy(env, c.hideLabel) then
				c.hide = 1
			end
		end
		if version < 27 and c.type == "constant" then
			local query = if Env.value(env, c.query) ~= nil then c.query else ""
			local current = { selected = true, text = query, value = query }
			c.current = current
			c.options = array(env, { current })
			local hide = Env.value(env, c.hide)
			if hide == 0 or hide == 1 then
				c.type = "textbox"
			end
		end
		table.insert(list, c)
	end
	local t: Obj = Tbl.copy(templating)
	t.list = list
	out.templating = t
end

-- RowArea: the height every grid column of the current line is filled to.
type Area = { cells: { number }, y: number, height: number }

local function addPanel(a: Area, x: number, y: number, w: number, h: number)
	for i = math.max(x, 0) + 1, math.min(x + w, GRID_COLUMN_COUNT) do
		a.cells[i] = math.max(a.cells[i], y + h - a.y)
	end
end

-- RowArea.getPanelPosition: the free run at the right end of the line, else
-- the start of the next line; nil when even that is too narrow.
local function position(a: Area, w: number, once: boolean): (number?, number?)
	local first: number?, last: number? = nil, nil
	for i = GRID_COLUMN_COUNT, 1, -1 do
		if a.height - a.cells[i] <= 0 then
			break
		end
		if last == nil then
			last = i
		elseif i < GRID_COLUMN_COUNT and a.cells[i] <= a.cells[i + 1] then
			first = i
		else
			break
		end
	end
	if first and last and last - first >= w - 1 then
		local y = 0
		for i = first, GRID_COLUMN_COUNT do
			y = math.max(y, a.cells[i])
		end
		return first - 1, y
	elseif once then
		return nil, nil
	end
	a.y += a.height
	for i = 1, GRID_COLUMN_COUNT do
		a.cells[i] = 0
	end
	return position(a, w, true)
end

-- A height in px as saved (a number or "250px"); nil when it is no number.
local function heightPx(v: any): number?
	if type(v) == "number" then
		return if v == v then v else nil
	elseif type(v) == "string" then
		local digits = string.match((string.gsub(v, "px", "", 1)), "^%s*([+-]?%d+)")
		return if digits then tonumber(digits) else nil
	end
	return nil
end

local function gridHeight(px: number): number
	return math.ceil(math.max(px, MIN_PANEL_HEIGHT) / (GRID_CELL_HEIGHT + GRID_CELL_VMARGIN))
end

-- A legacy top-level row with copies of its panels.
type LegacyRow = { row: Obj, panels: { Obj } }

-- V16 upgradeToGridLayout: each row's panels flow left to right in rows of
-- the row's height (span 1-12 doubled to the 24-column grid), under a row
-- panel when any row is collapsed, repeated or shows its title. Panels of a
-- collapsed row move into its row panel. Appends to `panels`.
local function gridLayout(env: Env, rows: { LegacyRow }, panels: { any })
	local maxId = 0
	local function seen(p: any)
		local id = Json.number(Json.path(env, p, "id"))
		if id and id > maxId then
			maxId = id
		end
	end
	for _, p in panels do
		seen(p)
	end
	local showRows = false
	for _, r in rows do
		for _, p in r.panels do
			seen(p)
		end
		local row = r.row
		showRows = showRows or truthy(env, row.collapse) or truthy(env, row.showTitle) or truthy(env, row["repeat"])
	end
	local nextId = maxId + 1
	local y = 0
	for _, r in rows do
		local row = r.row
		if truthy(env, row.repeatIteration) then
			continue
		end
		local rowPx = if truthy(env, row.height) then heightPx(row.height) else nil
		local rowHeight = gridHeight(rowPx or DEFAULT_ROW_HEIGHT)
		local collapsed = truthy(env, row.collapse)
		local rowPanel: Obj? = nil
		if showRows then
			rowPanel = {
				id = nextId,
				type = "row",
				title = row.title,
				collapsed = row.collapse,
				["repeat"] = row["repeat"],
				panels = array(env, {}),
				gridPos = { x = 0, y = y, w = GRID_COLUMN_COUNT, h = rowHeight },
			}
			nextId += 1
			y += 1
		end
		local area: Area = { cells = table.create(GRID_COLUMN_COUNT, 0), y = y, height = rowHeight }
		for _, p in r.panels do
			local span = if truthy(env, p.span)
				then Migrate.jsNumber(env, p.span) or DEFAULT_PANEL_SPAN
				else DEFAULT_PANEL_SPAN
			if truthy(env, p.minSpan) then
				local minSpan = Migrate.jsNumber(env, p.minSpan)
				if minSpan then
					p.minSpan = math.min(GRID_COLUMN_COUNT, GRID_COLUMN_COUNT / 12 * minSpan)
				end
			end
			local w = math.floor(span) * (GRID_COLUMN_COUNT / 12)
			local h = rowHeight
			if truthy(env, p.height) then
				local px = heightPx(p.height)
				if px then
					h = gridHeight(px)
				end
			end
			local x, dy = position(area, w, false)
			y = area.y
			-- Grafana fails on a panel wider than the grid; it starts a line here.
			local pos = { x = x or 0, y = y + (dy or 0), w = w, h = h }
			p.gridPos = pos
			addPanel(area, pos.x, pos.y, w, h)
			p.span = nil
			if rowPanel and collapsed then
				table.insert(rowPanel.panels, p)
			else
				table.insert(panels, p)
			end
		end
		if rowPanel then
			table.insert(panels, rowPanel)
		end
		if not (rowPanel and collapsed) then
			y += rowHeight
		end
	end
end

-- V27 removeRepeatedPanels: copies a repeat left in the saved model.
local function removeRepeated(env: Env, panels: { any }): { any }
	local out = array(env, {})
	for _, p in panels do
		if truthy(env, Json.path(env, p, "repeatPanelId")) or truthy(env, Json.path(env, p, "repeatByRow")) then
			continue
		end
		local kids = Json.tbl(env, Json.path(env, p, "panels"))
		if Json.path(env, p, "type") == "row" and kids then
			local keep = array(env, {})
			for _, k in kids do
				if not truthy(env, Json.path(env, k, "repeatPanelId")) then
					table.insert(keep, k)
				end
			end
			p.panels = keep
		end
		table.insert(out, p)
	end
	return out
end

-- Panel steps -------------------------------------------------------------------

-- kbn.slugifyForUrl.
local function slugifyForUrl(s: string): string
	local out = string.gsub(string.lower(s), "[^%w_ ]+", "")
	out = string.gsub(out, " +", "-")
	return out
end

-- urlUtil.appendQueryToUrl.
local function appendQuery(url: string, query: string): string
	if query == "" then
		return url
	end
	local q = string.find(url, "?", 1, true)
	if q == nil then
		url ..= "?"
	elseif #url > q then
		url ..= "&"
	end
	return url .. query
end

-- V19 upgradePanelLink.
local function upgradeLink(env: Env, link: Obj): Obj
	local url = Json.str(env, link.url) or ""
	if url == "" then
		local dash, uri = Json.str(env, link.dashboard) or "", Json.str(env, link.dashUri) or ""
		url = if dash ~= ""
			then "dashboard/db/" .. slugifyForUrl(dash)
			elseif uri ~= "" then "dashboard/" .. uri
			else "/"
	end
	if truthy(env, link.keepTime) then
		url = appendQuery(url, "$__url_time_range")
	end
	if truthy(env, link.includeVars) then
		url = appendQuery(url, "$__all_variables")
	end
	url = appendQuery(url, Json.str(env, link.params) or "")
	local out: Obj = { url = url, title = Json.str(env, link.title) or "" }
	if link.targetBlank == true then
		out.targetBlank = true
	end
	return out
end

-- getActiveThreshold's color for `value` (a null step value is the base).
local function thresholdColor(env: Env, value: number, thresholds: Obj?): any
	local active: Obj? = nil
	for _, raw in Json.list(env, if thresholds then thresholds.steps else nil) do
		local step = Json.tbl(env, raw)
		local v = if step then step.value else nil
		if step == nil or v == nil then
			continue
		elseif v == env.null then
			active = step
		elseif type(v) == "number" then
			if value < v then
				break
			end
			active = step
		end
	end
	return if active then Env.value(env, (active :: Obj).color) else nil
end

-- Go's strconv.ParseFloat of the backend's stringifyValue, 0 when it fails.
local function parseFloat0(v: any): number
	local n = if type(v) == "number" then v elseif type(v) == "string" then tonumber(v) else nil
	return if n and n == n then n else 0
end

local function isNewMapping(m: Obj): boolean
	return type(m.type) == "string" and m.type ~= ""
end

-- V30 upgradeValueMappings: legacy `type` 1 (value) and 2 (range) entries
-- to the current shapes, value-to-text ones merged into a first value map
-- and colored by the threshold their text reads as; nil when every entry is
-- in the new format already (the list stays as it is).
local function upgradeMappings(env: Env, mappings: { any }, thresholds: Obj?): { any }?
	local legacy = false
	for _, raw in mappings do
		local m = Json.tbl(env, raw)
		if m and not isNewMapping(m) then
			legacy = true
			break
		end
	end
	if not legacy then
		return nil
	end
	local values: Obj = {}
	local hasValues = false
	local out = array(env, {})
	for _, raw in mappings do
		local m = Json.tbl(env, raw)
		if m == nil then
			continue
		elseif isNewMapping(m) then
			if m.type ~= "value" then
				table.insert(out, m)
			else
				for k, v in Json.obj(env, m.options) do
					values[k] = v
					hasValues = true
				end
			end
			continue
		end
		local n = if type(m.text) == "string" then tonumber(m.text) else nil
		local result: Obj = { text = m.text, color = if n then thresholdColor(env, n, thresholds) else nil }
		if m.type == 1 then
			local v = Env.value(env, m.value)
			if v == "null" then
				table.insert(out, { type = "special", options = { match = "null", result = result } })
			elseif v ~= nil then
				values[if type(v) == "string" then v else Migrate.jsString(v)] = result
				hasValues = true
			end
		elseif m.type == 2 then
			table.insert(
				out,
				{ type = "range", options = { from = parseFloat0(m.from), to = parseFloat0(m.to), result = result } }
			)
		end
	end
	if hasValues then
		table.insert(out, 1, { type = "value", options = values })
	end
	return out
end

-- Replaces each override property `edit` returns a replacement for, copying
-- the field config, its overrides and every override it edits.
local function editProperties(env: Env, p: Obj, edit: (prop: Obj) -> Obj?)
	local fc = Json.tbl(env, p.fieldConfig)
	local overrides = if fc then Json.tbl(env, fc.overrides) else nil
	if fc == nil or overrides == nil then
		return
	end
	local newOverrides: { any }? = nil
	for i, raw in overrides do
		local o = Json.tbl(env, raw)
		local props = if o then Json.tbl(env, o.properties) else nil
		if o == nil or props == nil then
			continue
		end
		local newProps: { any }? = nil
		for j, rawProp in props do
			local prop = Json.tbl(env, rawProp)
			local replacement = if prop then edit(prop) else nil
			if replacement then
				local list = newProps or copyList(env, props)
				list[j] = replacement
				newProps = list
			end
		end
		if newProps then
			local list = newOverrides or copyList(env, overrides)
			local oc: Obj = Tbl.copy(o)
			oc.properties = newProps
			list[i] = oc
			newOverrides = list
		end
	end
	if newOverrides then
		local copy: Obj = Tbl.copy(fc)
		copy.overrides = newOverrides
		p.fieldConfig = copy
	end
end

-- V30 upgradeValueMappingsForPanel.
local function upgradePanelMappings(env: Env, p: Obj)
	local fc = Json.tbl(env, p.fieldConfig)
	local defaults = if fc then Json.tbl(env, fc.defaults) else nil
	local mappings = if defaults then Json.tbl(env, defaults.mappings) else nil
	local upgraded = if defaults and mappings
		then upgradeMappings(env, mappings, Json.tbl(env, defaults.thresholds))
		else nil
	if fc and defaults and upgraded then
		local d: Obj = Tbl.copy(defaults)
		d.mappings = upgraded
		local copy: Obj = Tbl.copy(fc)
		copy.defaults = d
		p.fieldConfig = copy
	end
	editProperties(env, p, function(prop: Obj): Obj?
		local list = Json.tbl(env, prop.value)
		local new = if prop.id == "mappings" and list then upgradeMappings(env, list, nil) else nil
		if new == nil then
			return nil
		end
		local c: Obj = Tbl.copy(prop)
		c.value = new
		return c
	end)
end

-- V42 migrateHideFromFunctionality.
local function hideFromTooltip(env: Env, prop: Obj): Obj?
	local value = Json.tbl(env, prop.value)
	if prop.id ~= "custom.hideFrom" or value == nil or value.viz ~= true then
		return nil
	end
	local v: Obj = Tbl.copy(value)
	v.tooltip = true
	local c: Obj = Tbl.copy(prop)
	c.value = v
	return c
end

-- The panel steps for a dashboard at `version`, on `p` (a copy).
local function upgradePanel(env: Env, version: number, p: Obj)
	if version < 22 and p.type == "table" then
		-- V10 and V22.
		local styles = Json.tbl(env, p.styles)
		if styles then
			local list = copyList(env, styles)
			for i, raw in list do
				local style = Json.tbl(env, raw)
				if style then
					local s: Obj = Tbl.copy(style)
					local th = Json.tbl(env, s.thresholds)
					if version < 10 and th and #th >= 3 then
						local rest = array(env, {})
						for k = 2, #th do
							table.insert(rest, th[k])
						end
						s.thresholds = rest
					end
					s.align = "auto"
					list[i] = s
				end
			end
			p.styles = list
		end
	end
	if version < 17 then
		local minSpan = Migrate.jsNumber(env, p.minSpan)
		if minSpan and minSpan > 0 then
			local max = GRID_COLUMN_COUNT / minSpan
			for i, f in FACTORS do
				if f > max then
					p.maxPerRow = if i > 1 then FACTORS[i - 1] else 1
					break
				end
			end
		end
		p.minSpan = nil
	end
	if version < 19 then
		local links = Json.tbl(env, p.links)
		if links then
			local out = array(env, {})
			for _, raw in links do
				local link = Json.tbl(env, raw)
				if link then
					table.insert(out, upgradeLink(env, link))
				end
			end
			p.links = out
		end
	end
	if version < 24 and p.type == "table" and truthy(env, p.styles) and p.table ~= "table2" then
		p.type = "table-old"
	end
	if version < 26 and p.type == "text2" then
		p.type = "text"
		local options = Json.tbl(env, p.options)
		if options and options.angular ~= nil then
			local o: Obj = Tbl.copy(options)
			o.angular = nil
			p.options = o
		end
	end
	if version < 30 then
		upgradePanelMappings(env, p)
		local options = Json.tbl(env, p.options)
		local kind = p.type
		if
			(kind == "timeseries" or kind == "xychart" or kind == "xychart2")
			and options
			and truthy(env, options.tooltipOptions)
		then
			local o: Obj = Tbl.copy(options)
			o.tooltip = options.tooltipOptions
			o.tooltipOptions = nil
			p.options = o
		end
	end
	if version < 31 then
		local ts = Json.tbl(env, p.transformations)
		local labels = false
		for _, t in Json.list(env, ts) do
			labels = labels or Json.path(env, t, "id") == "labelsToFields"
		end
		if ts and labels then
			local out = array(env, {})
			for _, t in ts do
				table.insert(out, t)
				if Json.path(env, t, "id") == "labelsToFields" then
					table.insert(out, { id = "merge", options = {} })
				end
			end
			p.transformations = out
		end
	end
	if
		version < 35
		and p.type == "timeseries"
		and Json.path(env, p, "fieldConfig", "defaults", "custom", "axisPlacement") == "hidden"
	then
		local fc: Obj = Tbl.copy(Json.obj(env, p.fieldConfig))
		local overrides = copyList(env, Json.list(env, fc.overrides))
		table.insert(overrides, {
			matcher = { id = "byType", options = "time" },
			properties = array(env, { { id = "custom.axisPlacement", value = "auto" } }),
		})
		fc.overrides = overrides
		p.fieldConfig = fc
	end
	-- V42 (every panel step runs below the latest version only).
	editProperties(env, p, function(prop: Obj): Obj?
		return hideFromTooltip(env, prop)
	end)
end

-- DashboardModel ----------------------------------------------------------------

-- EnsurePanelsHaveUniqueIds, before the steps as the backend runs it: in
-- panelIterator order (each panel, then its own panels), then the legacy
-- rows' panels, an id that is no positive number or that an earlier panel
-- has becomes the next free one. Panels (and lists) whose id changes are
-- replaced by copies; the legacy rows' panels are copies already.
local function uniqueIds(env: Env, panels: { any }, rows: { LegacyRow })
	local maxId = 0
	local function see(p: any)
		local id = Json.number(Json.path(env, p, "id"))
		if id and id > maxId then
			maxId = id
		end
	end
	for _, p in panels do
		see(p)
		for _, k in Json.list(env, Json.path(env, p, "panels")) do
			see(k)
		end
	end
	for _, r in rows do
		for _, p in r.panels do
			see(p)
		end
	end
	local nextId = maxId + 1
	local ids: { [number]: boolean } = {}
	-- The panel's new id, nil when it keeps its own.
	local function newId(p: Obj): number?
		local id = Json.number(p.id)
		if id and id > 0 and not ids[id] then
			ids[id] = true
			return nil
		end
		local n = nextId
		nextId += 1
		return n
	end
	for i, p in panels do
		local id = newId(p)
		local own: Obj? = nil
		if id then
			local c: Obj = Tbl.copy(p)
			c.id = id
			own = c
		end
		local kids = Json.tbl(env, p.panels)
		local newKids: { any }? = nil
		for j, k in Json.list(env, kids) do
			local kp = Json.tbl(env, k)
			local kid = if kp then newId(kp) else nil
			if kp and kid then
				local list = newKids or copyList(env, kids :: { any })
				local c: Obj = Tbl.copy(kp)
				c.id = kid
				list[j] = c
				newKids = list
			end
		end
		if newKids then
			local c: Obj = own or Tbl.copy(p)
			c.panels = newKids
			own = c
		end
		if own then
			panels[i] = own
		end
	end
	for _, r in rows do
		for _, p in r.panels do
			p.id = newId(p) or p.id
		end
	end
end

type Keyed = { p: any, y: number, x: number, i: number }

-- sortPanelsByGridPos (a stable sort, as JavaScript's); a panel without a
-- gridPos is at 0, 0 (PanelModel's defaults).
local function sortByGridPos(env: Env, panels: { any })
	local function at(p: any): (number, number)
		local g = Json.path(env, p, "gridPos")
		return Json.number(Json.path(env, g, "y")) or 0, Json.number(Json.path(env, g, "x")) or 0
	end
	local sorted = true
	local py, px = -math.huge, -math.huge
	for _, p in panels do
		local y, x = at(p)
		if y < py or (y == py and x < px) then
			sorted = false
			break
		end
		py, px = y, x
	end
	if sorted then
		return
	end
	local keyed: { Keyed } = {}
	for i, p in panels do
		local y, x = at(p)
		keyed[i] = { p = p, y = y, x = x, i = i }
	end
	table.sort(keyed, function(a: Keyed, b: Keyed): boolean
		if a.y ~= b.y then
			return a.y < b.y
		elseif a.x ~= b.x then
			return a.x < b.x
		end
		return a.i < b.i
	end)
	for i, k in keyed do
		panels[i] = k.p
	end
end

-- getRefId: A to Z, then AA, AB, ...
local function refIdOf(num: number): string
	if num < 26 then
		return string.char(65 + num)
	end
	return refIdOf(num // 26 - 1) .. string.char(65 + num % 26)
end

-- PanelModel.restoreModel: defaultsDeep with `targets: [{ refId: "A" }]`
-- names a first target without the key "A", then ensureQueryIds gives each
-- target whose refId is falsy getNextRefId's first id no target has. The
-- panel itself, or a copy with copied targets when an id was added.
function M.ensureQueryIds(env: Env, p: Obj): Obj
	local targets = Json.tbl(env, p.targets)
	if targets == nil then
		return p
	end
	local taken: { [any]: boolean } = {}
	local missing = false
	for i, raw in targets do
		local t = Json.tbl(env, raw)
		if t == nil then
			continue
		elseif i == 1 and t.refId == nil then
			taken.A = true
			missing = true
		elseif truthy(env, t.refId) then
			taken[t.refId] = true
		else
			missing = true
		end
	end
	if not missing then
		return p
	end
	local list = copyList(env, targets)
	local num = 0
	for i, raw in list do
		local t = Json.tbl(env, raw)
		if t == nil or (truthy(env, t.refId) and not (i == 1 and t.refId == nil)) then
			continue
		end
		local c: Obj = Tbl.copy(t)
		if i == 1 and t.refId == nil then
			c.refId = "A"
		else
			while taken[refIdOf(num)] do
				num += 1
			end
			c.refId = refIdOf(num)
			taken[c.refId] = true
		end
		list[i] = c
	end
	local out: Obj = Tbl.copy(p)
	out.targets = list
	return out
end

-- The dashboard JSON (`dashboard` of `/api/dashboards/uid/<uid>`) as
-- Grafana 12 and 13 load it: panel ids unique, migrated to the latest
-- schema, copies of repeated panels left in the saved model dropped (the
-- save model the backend answers) and the top-level panels in gridPos order.
function M.migrate(d: Obj, env: Env): Obj
	local version = Json.num(env, d.schemaVersion) or 0
	local out: Obj = Tbl.copy(d)
	local panels: { Obj } = array(env, {})
	for _, raw in Json.list(env, d.panels) do
		local p = Json.tbl(env, raw)
		if p == nil then
			continue
		elseif version >= M.LATEST then
			table.insert(panels, p)
			continue
		end
		local c: Obj = Tbl.copy(p)
		local kids = Json.tbl(env, c.panels)
		if kids then
			local list = array(env, {})
			for _, k in kids do
				local kp = Json.tbl(env, k)
				if kp then
					table.insert(list, Tbl.copy(kp))
				end
			end
			c.panels = list
		end
		table.insert(panels, c)
	end
	local legacy: { LegacyRow } = {}
	if version < 16 then
		for _, raw in Json.list(env, d.rows) do
			local row = Json.tbl(env, raw)
			if row then
				local copies: { Obj } = {}
				for _, p in Json.list(env, row.panels) do
					local t = Json.tbl(env, p)
					if t then
						table.insert(copies, Tbl.copy(t))
					end
				end
				table.insert(legacy, { row = row, panels = copies })
			end
		end
	end
	uniqueIds(env, panels, legacy)
	if version < 2 then
		local filter = Json.tbl(env, Json.path(env, d, "services", "filter"))
		if filter then
			out.time = filter.time
			local t: Obj = Tbl.copy(Json.obj(env, d.templating))
			t.list = if truthy(env, filter.list) then filter.list else array(env, {})
			out.templating = t
		end
	end
	if version < 6 then
		for _, raw in Json.list(env, d.pulldowns) do
			local pulldown = Json.tbl(env, raw)
			if pulldown and pulldown.type == "annotations" then
				local list = if truthy(env, pulldown.annotations) then pulldown.annotations else array(env, {})
				out.annotations = { list = list }
				break
			end
		end
	end
	if version < 27 then
		migrateVariables(env, version, out)
	end
	if version < 16 then
		gridLayout(env, legacy, panels)
		out.rows = nil
	end
	if version < 27 then
		panels = removeRepeated(env, panels)
	end
	if version < M.LATEST then
		for _, p in panels do
			upgradePanel(env, version, p)
			for _, k in Json.list(env, p.panels) do
				upgradePanel(env, version, k)
			end
		end
		out.schemaVersion = M.LATEST
	end
	local kept: { Obj } = array(env, {})
	for _, p in panels do
		if p.repeatPanelId == nil and p.repeatedByRow == nil then
			local own = M.ensureQueryIds(env, p)
			local kids = Json.tbl(env, own.panels)
			local newKids: { any }? = nil
			for j, k in Json.list(env, kids) do
				local kp = Json.tbl(env, k)
				local ensured = if kp then M.ensureQueryIds(env, kp) else nil
				if ensured and ensured ~= kp then
					local list = newKids or copyList(env, kids :: { any })
					list[j] = ensured
					newKids = list
				end
			end
			if newKids then
				own = if own == p then Tbl.copy(p) else own
				own.panels = newKids
			end
			table.insert(kept, own)
		end
	end
	sortByGridPos(env, kept)
	out.panels = kept
	return out
end

return M
