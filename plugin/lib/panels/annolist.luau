--!strict
-- The annotation list panel (public/app/plugins/panel/annolist at v12.4.0:
-- AnnoListPanel.tsx doSearch / onAnnoClick / _timeOffset,
-- AnnotationListItem.tsx, panelcfg.cue defaults; tag colors from
-- packages/grafana-ui/src/utils/tags.ts getTagColorsFromName).
--
-- One `/api/annotations` request with the panel's tags, limit and
-- type=annotation, the dashboard's uid when onlyFromThisDashboard and the
-- panel's time range when onlyInTimeRange. Each annotation shows its text
-- (HTML reduced to text), its time (and end) in the dashboard's timezone,
-- the author's login (Grafana shows the avatar) and its tags in Grafana's
-- hashed tag colors. The text opens the dashboard the annotation belongs to
-- (this one for organization-wide annotations) from navigateBefore before
-- to navigateAfter after it, on the annotation's panel when
-- navigateToPanel, as onAnnoClick does.
--
-- Not native: tags written with dashboard variables (a panel request cannot
-- interpolate them). Clicking a tag or an avatar to filter the list is not
-- offered (the panel view holds no state).

local Assets = require("../render/assets")
local Clock = require("./clock")
local Common = require("./common")
local Env = require("../env")
local Frame = require("../frame/types")
local Json = require("./json")
local Range = require("../time/range")
local Response = require("../source/response")
local Scheme = require("../links/scheme")
local Text = require("./text")
local TransportTypes = require("../transport/types")
local ui = require("../ui")

type Env = Env.Env
type Node = ui.Node

local M = {}

M.types = { "annolist" }

local TAG_PREFIX = "annotations:"

export type Options = {
	onlyFromThisDashboard: boolean,
	onlyInTimeRange: boolean,
	tags: { string },
	limit: number,
	showUser: boolean,
	showTime: boolean,
	showTags: boolean,
	navigateToPanel: boolean,
	navigateBefore: string,
	navigateAfter: string,
}

export type Annotation = {
	id: number?,
	dashboard_uid: string?,
	panel_id: number?,
	time: number?,
	time_end: number?,
	text: string,
	tags: { string },
	login: string?,
	email: string?,
}

-- panelcfg.cue defaults.
function M.options(panel: any, env: Env): Options
	local o = Json.obj(env, Json.path(env, panel, "options"))
	local function flag(name: string, default: boolean): boolean
		local v = Json.bool(env, o[name])
		if v == nil then
			return default
		end
		return v
	end
	local tags: { string } = {}
	for _, t in Json.list(env, o.tags) do
		local s = Json.str(env, t)
		if s then
			table.insert(tags, s)
		end
	end
	return {
		onlyFromThisDashboard = flag("onlyFromThisDashboard", false),
		onlyInTimeRange = flag("onlyInTimeRange", false),
		tags = tags,
		limit = Json.num(env, o.limit) or 10,
		showUser = flag("showUser", true),
		showTime = flag("showTime", true),
		showTags = flag("showTags", true),
		navigateToPanel = flag("navigateToPanel", true),
		navigateBefore = Json.str(env, o.navigateBefore) or "10m",
		navigateAfter = Json.str(env, o.navigateAfter) or "10m",
	}
end

function M.supports(panel: any, env: Env): (boolean, string?)
	for _, t in M.options(panel, env).tags do
		if string.find(t, "$", 1, true) then
			return false, "annotation list tags with dashboard variables are not interpolated natively"
		end
	end
	return true, nil
end

function M.queries(_: any): boolean
	return false
end

-- doSearch. The tag carries the dashboard uid: organization-wide
-- annotations open this dashboard.
function M.requests(panel: any, ctx: Common.RequestContext, env: Env): { Common.PanelRequest }
	local o = M.options(panel, env)
	local q: { { string } } = {}
	for _, t in o.tags do
		table.insert(q, { "tags", t })
	end
	table.insert(q, { "limit", tostring(math.floor(o.limit)) })
	table.insert(q, { "type", "annotation" })
	if o.onlyFromThisDashboard and ctx.dashboard_uid then
		table.insert(q, { "dashboardUID", ctx.dashboard_uid :: string })
	end
	if o.onlyInTimeRange then
		table.insert(q, { "from", string.format("%d", ctx.time.from_ms) })
		table.insert(q, { "to", string.format("%d", ctx.time.to_ms) })
	end
	return {
		{
			tag = TAG_PREFIX .. (ctx.dashboard_uid or ""),
			signal = "annotations",
			request = { method = "GET", path = "/api/annotations", query = q },
		},
	}
end

function M.parse(_: any, _tag: string, response: TransportTypes.Response, env: Env): any
	local doc, err = Response.json(response, env, "annotations")
	if err then
		return { error = err.message }
	end
	local out: { Annotation } = {}
	for _, a in Json.list(env, doc) do
		if Json.tbl(env, a) == nil then
			continue
		end
		local tags: { string } = {}
		for _, t in Json.list(env, a.tags) do
			local s = Json.str(env, t)
			if s then
				table.insert(tags, s)
			end
		end
		local uid = Json.str(env, a.dashboardUID)
		local panelId = Json.num(env, a.panelId)
		table.insert(out, {
			id = Json.num(env, a.id),
			dashboard_uid = if uid and uid ~= "" then uid else nil,
			panel_id = if panelId and panelId ~= 0 then panelId else nil,
			time = Json.num(env, a.time),
			time_end = Json.num(env, a.timeEnd),
			text = Json.str(env, a.text) or "",
			tags = tags,
			login = Json.str(env, a.login),
			email = Json.str(env, a.email),
		})
	end
	return { annotations = out }
end

-- Time ----------------------------------------------------------------------------------

local function daysFromCivil(y: number, m: number, d: number): number
	y = if m <= 2 then y - 1 else y
	local era = y // 400
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

local function civilFromDays(z: number): (number, number, number)
	z += 719468
	local era = z // 146097
	local doe = z - era * 146097
	local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	local y = yoe + era * 400
	local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	local mp = (5 * doy + 2) // 153
	local d = doy - (153 * mp + 2) // 5 + 1
	local m = if mp < 10 then mp + 3 else mp - 9
	return if m <= 2 then y + 1 else y, m, d
end

local DAY = 86400000
local FIXED: { [string]: number } = { s = 1000, m = 60000, h = 3600000, d = DAY, w = 7 * DAY }

-- moment's add(n, "M"): the day clamped to the target month's length.
local function addMonths(ms: number, n: number): number
	local days = ms // DAY
	local rest = ms - days * DAY
	local y, m, d = civilFromDays(days)
	local total = (m - 1) + n
	local ty = y + total // 12
	local tm = total % 12 + 1
	local ny, nm = if tm == 12 then ty + 1 else ty, if tm == 12 then 1 else tm + 1
	local _, _, last = civilFromDays(daysFromCivil(ny, nm, 1) - 1)
	return daysFromCivil(ty, tm, math.min(d, last)) * DAY + rest
end

-- _timeOffset: `<n><unit>` (default 5m) moved before or after `time`; a
-- unit dateMath does not know is the epoch (0), as in Grafana.
function M.timeOffset(time: number, offset: string, subtract: boolean): number
	local incr, unit = 5, "m"
	local n, u = string.match(offset, "^(%d+)([%w_])")
	if n and u then
		incr, unit = tonumber(n) :: number, u :: string
	end
	if subtract then
		incr = -incr
	end
	local fixed = FIXED[unit]
	if fixed then
		return time + incr * fixed
	elseif unit == "M" then
		return addMonths(time, incr)
	elseif unit == "Q" then
		return addMonths(time, incr * 3)
	elseif unit == "y" then
		return addMonths(time, incr * 12)
	end
	return 0
end

-- The dashboard timezone's offset at `ms` (dashboard.formatDate).
local function offsetAt(opts: Common.Options, env: Env, ms: number): number
	local localMin = opts.local_offset_min or env.local_offset_min or opts.offset_min or 0
	local tz = opts.timezone or ""
	if tz == "browser" then
		tz = ""
	end
	local zone = Clock.zone(tz, localMin, opts.timezone, opts.offset_min)
	local offset = Clock.zoneAt(zone, ms)
	return offset
end

-- Tag colors ------------------------------------------------------------------------------

M.TAG_COLORS = 29

local function toInt32(x: number): number
	local v = x % 4294967296
	return if v >= 2147483648 then v - 4294967296 else v
end

-- UTF-16 code units of a UTF-8 string (charCodeAt).
local function codeUnits(s: string): { number }
	local out: { number } = {}
	local ok = pcall(function()
		for _, c in utf8.codes(s) do
			if c >= 0x10000 then
				local v = c - 0x10000
				table.insert(out, 0xD800 + v // 0x400)
				table.insert(out, 0xDC00 + v % 0x400)
			else
				table.insert(out, c)
			end
		end
	end)
	if not ok then
		out = {}
		for i = 1, #s do
			table.insert(out, string.byte(s, i))
		end
	end
	return out
end

-- getTagColorIndexFromName: djb2 over the lower-cased name in JavaScript
-- number semantics (`<<` works on int32), then |hash % 29|.
function M.tagColor(name: string): number
	local hash = 5381
	for _, c in codeUnits(string.lower(name)) do
		local shifted = toInt32(toInt32(hash) * 32)
		hash = shifted + hash + c
	end
	-- JavaScript % keeps the dividend's sign.
	local r = math.fmod(hash, M.TAG_COLORS)
	return math.abs(r)
end

-- View ----------------------------------------------------------------------------------

-- onAnnoClick: this dashboard (with the annotation's panel) or the one the
-- annotation belongs to, around the annotation.
function M.link(a: Annotation, o: Options, dashboardUid: string?): string?
	if a.time == nil then
		return nil
	end
	local uid = a.dashboard_uid or dashboardUid
	if uid == nil then
		return nil
	end
	local params: { [string]: string } = {
		uid = uid :: string,
		from = string.format("%d", M.timeOffset(a.time :: number, o.navigateBefore, true)),
		to = string.format("%d", M.timeOffset(a.time_end or a.time :: number, o.navigateAfter, false)),
	}
	if uid == dashboardUid and o.navigateToPanel and a.panel_id then
		params.panel = string.format("%d", a.panel_id :: number)
	end
	local ok, link = pcall(Scheme.encode, { action = "dashboard", params = params, vars = {} })
	return if ok then link else nil
end

local function el(class: string, key: string, children: { Node }, props: { [string]: any }?): Node
	local p: { [string]: any } = { tag = "div", class = class, key = key }
	if props then
		for k, v in props do
			p[k] = v
		end
	end
	return { k = "el", p = p, c = children }
end

local function tagChips(tags: { string }, key: string): Node
	local chips: { Node } = {}
	for i, t in tags do
		table.insert(
			chips,
			el("tgl-tag tgl-tag-" .. M.tagColor(t), "t" .. i, { ui.text({ ui.span(t) }) }, { tag = "span" })
		)
	end
	return el("tgl-tags", key, chips)
end

local function itemNode(
	a: Annotation,
	o: Options,
	opts: Common.Options,
	env: Env,
	dashboardUid: string?,
	i: number
): Node
	local link = M.link(a, o, dashboardUid)
	local text = Text.htmlToText(a.text)
	local head: ui.Span = { t = text, href = link }
	local children: { Node } = { ui.text({ head }, { key = "x" }) }
	if o.showTime and a.time and a.time ~= 0 then
		local t = a.time :: number
		local spans = { ui.span(Range.formatMs(t, offsetAt(opts, env, t)), "muted") }
		local e = a.time_end
		if e and e ~= 0 and e ~= t then
			table.insert(spans, ui.span("  -  ", "muted"))
			table.insert(spans, ui.span(Range.formatMs(e, offsetAt(opts, env, e)), "muted"))
		end
		table.insert(children, ui.text(spans, { key = "tm" }))
	end
	if o.showUser and a.login and a.login ~= "" then
		table.insert(
			children,
			ui.text({ ui.span(a.login :: string, "muted") }, { key = "u", title = "Created by: " .. (a.email or "") })
		)
	end
	if o.showTags and #a.tags > 0 then
		table.insert(children, tagChips(a.tags, "tg"))
	end
	return el("tgl-item tgl-anno", "a" .. i, children)
end

local function answerOf(opts: Common.Options): (any?, string?)
	if opts.extra == nil then
		return nil, nil
	end
	for tag, v in opts.extra :: { [string]: any } do
		if string.sub(tag, 1, #TAG_PREFIX) == TAG_PREFIX then
			local uid = string.sub(tag, #TAG_PREFIX + 1)
			return v, if uid ~= "" then uid else nil
		end
	end
	return nil, nil
end

function M.view(panel: any, _: { Frame.Frame }, env: Env, opts: Common.Options): (Node, Assets.Assets?)
	local answer, dashboardUid = answerOf(opts)
	if answer == nil then
		return ui.muted("Loading...", { key = opts.key }), nil
	end
	if answer.error then
		return ui.text({ ui.span(tostring(answer.error), "error") }, { key = opts.key }), nil
	end
	local o = M.options(panel, env)
	local list: { Annotation } = answer.annotations
	local children: { Node } = {}
	if #list < 1 then
		table.insert(children, ui.muted("No annotations found", { key = "none" }))
	end
	for i, a in list do
		table.insert(children, itemNode(a, o, opts, env, dashboardUid, i))
	end
	return el("tgl-list", opts.key, children, { role = "tern-grafana.annolist" }), nil
end

return M
