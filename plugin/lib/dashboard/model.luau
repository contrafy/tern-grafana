--!strict
-- The dashboard JSON model from `/api/dashboards/uid/<uid>` (Grafana 11 and
-- 12, schema v1) as sections of panels. Rows are flattened the way Grafana's
-- classic dashboard model lays them out: an open row owns the top-level
-- panels after it up to the next row; a collapsed row keeps its own panels in
-- `row.panels`, and top-level panels after a collapsed row are not part of it.
--
-- Panels keep their decoded JSON as is (`json`): the panel registry and the
-- query builder read Grafana's own option shapes. Library panels arrive as a
-- bare reference and are merged with the element's model once fetched
-- (`applyLibrary`), the way Grafana's LibraryPanelBehavior does: the model
-- wins except for the dashboard's id and gridPos.

local Env = require("../env")
local Response = require("../source/response")
local Scheme = require("../links/scheme")
local TransportTypes = require("../transport/types")

type Env = Env.Env
type QueryError = TransportTypes.QueryError
type Request = TransportTypes.Request
type Response = TransportTypes.Response

local M = {}

export type GridPos = { x: number, y: number, w: number, h: number }

export type Repeat = { var: string, direction: "h" | "v", max_per_row: number? }

export type Panel = {
	id: number,
	type: string,
	title: string,
	grid: GridPos,
	json: { [string]: any },
	repeat_by: Repeat?,
	-- Unresolved library panel reference; nil once merged.
	library_uid: string?,
}

export type Row = {
	id: number,
	title: string,
	grid: GridPos,
	collapsed: boolean,
	repeat_by: Repeat?,
}

export type Section = { row: Row?, panels: { Panel } }

export type Dashboard = {
	uid: string,
	title: string,
	slug: string,
	version: number?,
	folder_title: string?,
	tags: { string },
	time: { from: string, to: string },
	-- Auto-refresh interval as written ("30s"), nil or "" when off.
	refresh: string?,
	-- "browser", "utc", "" or an IANA zone.
	timezone: string,
	week_start: string?,
	templating: { any },
	links: { any },
	sections: { Section },
}

local function num(v: any, default: number): number
	return if type(v) == "number" and v == v then v else default
end

local function str(env: Env, v: any): string?
	v = Env.value(env, v)
	return if type(v) == "string" then v else nil
end

local function grid(env: Env, raw: any): GridPos
	local g = if type(raw) == "table" then raw else {}
	return {
		x = num(Env.value(env, g.x), 0),
		y = num(Env.value(env, g.y), 0),
		w = math.clamp(num(Env.value(env, g.w), 12), 1, 24),
		h = math.max(1, num(Env.value(env, g.h), 8)),
	}
end

local function repeatOf(env: Env, raw: any): Repeat?
	local name = str(env, raw["repeat"])
	if name == nil or name == "" then
		return nil
	end
	local dir = str(env, raw.repeatDirection)
	local per = Env.value(env, raw.maxPerRow)
	return {
		var = name,
		direction = if dir == "v" then "v" else "h",
		max_per_row = if type(per) == "number" and per > 0 then per else nil,
	}
end

local function panelOf(env: Env, raw: any): Panel?
	if type(raw) ~= "table" then
		return nil
	end
	local lib = Env.value(env, raw.libraryPanel)
	local libUid = if type(lib) == "table" then str(env, lib.uid) else nil
	-- A library reference carries only gridPos, id and the reference.
	local unresolved = libUid ~= nil and str(env, raw.type) == nil
	return {
		id = num(Env.value(env, raw.id), 0),
		type = str(env, raw.type) or (if unresolved then "library" else "unknown"),
		title = str(env, raw.title) or (if unresolved and type(lib) == "table" then str(env, lib.name) else nil) or "",
		grid = grid(env, Env.value(env, raw.gridPos)),
		json = raw,
		repeat_by = repeatOf(env, raw),
		library_uid = if unresolved then libUid else nil,
	}
end

local function rowOf(env: Env, raw: any): Row
	return {
		id = num(Env.value(env, raw.id), 0),
		title = str(env, raw.title) or "",
		grid = grid(env, Env.value(env, raw.gridPos)),
		collapsed = Env.value(env, raw.collapsed) == true,
		repeat_by = repeatOf(env, raw),
	}
end

local function list(env: Env, v: any): { any }
	v = Env.value(env, v)
	return if type(v) == "table" then v else {}
end

local function sections(env: Env, panels: { any }): { Section }
	local out: { Section } = {}
	local current: Section = { row = nil, panels = {} }
	local function close()
		if current.row or #current.panels > 0 then
			table.insert(out, current)
		end
	end
	for _, raw in panels do
		if type(raw) ~= "table" then
			continue
		end
		if str(env, raw.type) == "row" then
			close()
			local row = rowOf(env, raw)
			current = { row = row, panels = {} }
			if row.collapsed then
				for _, child in list(env, raw.panels) do
					local p = panelOf(env, child)
					if p then
						table.insert(current.panels, p)
					end
				end
				close()
				current = { row = nil, panels = {} }
			end
		else
			local p = panelOf(env, raw)
			if p then
				table.insert(current.panels, p)
			end
		end
	end
	close()
	return out
end

-- The decoded `/api/dashboards/uid/<uid>` body ({dashboard, meta}).
function M.parse(doc: any, env: Env): (Dashboard?, string?)
	if type(doc) ~= "table" then
		return nil, "not a dashboard response"
	end
	local d = Env.value(env, doc.dashboard)
	if type(d) ~= "table" then
		local message = str(env, doc.message)
		return nil, message or "the response has no dashboard"
	end
	local meta = Env.value(env, doc.meta)
	meta = if type(meta) == "table" then meta else {}
	local uid = str(env, d.uid)
	if uid == nil or uid == "" then
		return nil, "the dashboard has no uid"
	end
	local time = Env.value(env, d.time)
	time = if type(time) == "table" then time else {}
	local tags: { string } = {}
	for _, t in list(env, d.tags) do
		if type(t) == "string" then
			table.insert(tags, t)
		end
	end
	local refresh = Env.value(env, d.refresh)
	local templating = Env.value(env, d.templating)
	return {
		uid = uid,
		title = str(env, d.title) or uid,
		slug = str(env, meta.slug) or M.slug(str(env, d.title) or uid),
		version = Env.value(env, d.version),
		folder_title = str(env, meta.folderTitle),
		tags = tags,
		time = { from = str(env, time.from) or "now-6h", to = str(env, time.to) or "now" },
		refresh = if type(refresh) == "string" and refresh ~= "" then refresh else nil,
		timezone = str(env, d.timezone) or "",
		week_start = str(env, d.weekStart),
		templating = if type(templating) == "table" then list(env, templating.list) else {},
		links = list(env, d.links),
		sections = sections(env, list(env, d.panels)),
	},
		nil
end

-- Grafana's slugify (pkg/infra/slugify): lowercase, runs of anything but
-- letters and digits become one dash.
function M.slug(title: string): string
	local s = string.lower(title)
	s = string.gsub(s, "[^%w]+", "-")
	s = string.gsub(s, "^%-+", "")
	s = string.gsub(s, "%-+$", "")
	return s
end

function M.parseResponse(response: Response, env: Env): (Dashboard?, string?)
	local doc, err = Response.json(response, env, "dashboard")
	if err then
		if response.status == 404 then
			return nil, "dashboard not found"
		end
		return nil, err.message
	end
	return M.parse(doc, env)
end

function M.request(uid: string): Request
	return { method = "GET", path = "/api/dashboards/uid/" .. Scheme.percentEncode(uid) }
end

-- Every panel, row by row, in model order.
function M.panels(d: Dashboard): { Panel }
	local out: { Panel } = {}
	for _, s in d.sections do
		for _, p in s.panels do
			table.insert(out, p)
		end
	end
	return out
end

function M.findPanel(d: Dashboard, id: number): Panel?
	for _, s in d.sections do
		for _, p in s.panels do
			if p.id == id then
				return p
			end
		end
	end
	return nil
end

-- Library element uids still to fetch, without duplicates.
function M.libraryRefs(d: Dashboard): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for _, p in M.panels(d) do
		local uid = p.library_uid
		if uid and not seen[uid] then
			seen[uid] = true
			table.insert(out, uid)
		end
	end
	return out
end

function M.libraryRequest(uid: string): Request
	return { method = "GET", path = "/api/library-elements/" .. Scheme.percentEncode(uid) }
end

-- The element's panel model from `/api/library-elements/<uid>`.
function M.parseLibrary(response: Response, env: Env): ({ [string]: any }?, string?)
	local doc, err = Response.json(response, env, "library panel")
	if err then
		return nil, err.message
	end
	local result = Env.value(env, doc.result)
	local model = if type(result) == "table" then Env.value(env, result.model) else nil
	if type(model) ~= "table" then
		return nil, "the library element has no panel model"
	end
	return model, nil
end

-- Merges a fetched library model into every panel referencing `uid`, in
-- place. A failed fetch (`model` nil) leaves the reference with `reason`.
function M.applyLibrary(d: Dashboard, uid: string, model: { [string]: any }?, env: Env)
	for _, s in d.sections do
		for i, p in s.panels do
			if p.library_uid ~= uid then
				continue
			end
			if model == nil then
				p.library_uid = nil
				p.type = "library"
				continue
			end
			local merged: { [string]: any } = table.clone(model)
			merged.id = p.json.id
			merged.gridPos = p.json.gridPos
			merged.libraryPanel = p.json.libraryPanel
			local resolved = panelOf(env, merged)
			if resolved then
				s.panels[i] = resolved
			end
		end
	end
end

return M
