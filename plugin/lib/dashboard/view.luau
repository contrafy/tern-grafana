--!strict
-- Views of the dashboard and panel blocks: a header (title, range, refresh),
-- variable chips, rows with their panels laid out by gridPos fractions, and
-- each panel on its ladder rung with the reason it left the native one.
-- Native panels come from lib/panels/registry; their rendered node and
-- assets are memoized per panel until its data, cursor or size changes, so a
-- focus move does not rebuild every SVG.

local Assets = require("../render/assets")
local Effect = require("../effect")
local Env = require("../env")
local Interpolate = require("./interpolate")
local Layout = require("./layout")
local Range = require("../time/range")
local Registry = require("../panels/registry")
local Repeat = require("./repeat")
local State = require("./state")
local Variables = require("./variables")
local ui = require("../ui")

type Env = Env.Env
type Node = ui.Node
type State = State.State

local M = {}

M.HINT =
	"arrows focus  enter expand  v variables  1-9 [ ] - + range  r refresh  a auto  l labels  o browser  p pin  / search"
-- Text lines per Grafana grid row (30 px rows, 8 px margins, about 15 px lines).
M.LINES_PER_ROW = 2.5

M.SOLO_HINT = "left/right cursor  1-9 [ ] - + range  r refresh  l labels  o browser  y copy URL"

local function title(s: State, inst: Repeat.Instance): string
	local t = inst.panel.title
	if t == "" then
		return "Panel " .. inst.panel.id
	end
	return Interpolate.replace(t, State.panelScope(s, inst), { format = Interpolate.text })
end

local function muted(text: string, key: string?): Node
	return ui.text({ ui.span(text, "muted") }, if key then { key = key } else nil)
end

local function errorText(text: string, key: string?): Node
	return ui.text({ ui.span(text, "error") }, if key then { key = key } else nil)
end

local function clickable(text: string, act: string, key: string): Node
	return {
		k = "el",
		p = { tag = "span", key = key, class = "tg-dash-link", actions = { click = act } },
		c = { ui.text({ ui.span(text, "accent") }) },
	}
end

-- The rendered native panel, memoized on its inputs.
local function nativeBody(
	s: State,
	inst: Repeat.Instance,
	ps: State.PanelState,
	env: Env,
	assets: Assets.Assets,
	single: boolean
): Node
	local data = ps.data
	if data == nil then
		if ps.status == "error" then
			return errorText(ps.error or "query failed", "err")
		end
		return muted("Loading", "loading")
	end
	local cursor = if single then s.cursor else nil
	local labels = s.labels[inst.key]
	-- Text panels interpolate variables into their content.
	local signature = Variables.signature(s.vars, s.range)
	local memo = s.memo[inst.key]
	if
		memo
		and memo.data == data
		and memo.cursor == cursor
		and memo.single == single
		and memo.labels == labels
		and memo.signature == signature
		and memo.json == inst.panel.json
		and memo.title == title(s, inst)
	then
		for k, a in memo.assets do
			assets[k] = a
		end
		return memo.node
	end
	local panelJson = table.clone(inst.panel.json)
	panelJson.title = title(s, inst)
	local r = s.range
	local scope = State.panelScope(s, inst)
	local ok, node, own = pcall(Registry.view, panelJson, data.frames, env, {
		key = inst.key,
		cursor = cursor,
		from_ms = if r then r.from_ms else nil,
		to_ms = if r then r.to_ms else nil,
		show_labels = labels,
		interpolate = function(text: string): string
			return Interpolate.replace(text, scope, { format = Interpolate.text })
		end,
	})
	local children: { Node } = {}
	local ownAssets: Assets.Assets = {}
	if ok then
		table.insert(children, node)
		ownAssets = own or {}
	else
		table.insert(children, errorText("panel could not be drawn: " .. tostring(node), "err"))
	end
	for i, e in data.errors do
		table.insert(children, errorText(e, "e" .. i))
	end
	for i, w in data.warnings do
		table.insert(children, muted(w, "w" .. i))
	end
	local body = ui.col(children, { key = "body", gap = "xs" })
	s.memo[inst.key] = {
		data = data,
		cursor = cursor,
		single = single,
		labels = labels,
		signature = signature,
		json = inst.panel.json,
		title = title(s, inst),
		node = body,
		assets = ownAssets,
	}
	for k, a in ownAssets do
		assets[k] = a
	end
	return body
end

local function pngBody(s: State, inst: Repeat.Instance, ps: State.PanelState, assets: Assets.Assets): Node
	local reason = ps.decision.reason or ""
	local children: { Node } = {}
	local bytes = if ps.png then s.pngs[ps.png] else nil
	if bytes then
		local spec = State.pngSpec(s, inst)
		local key = "png/" .. inst.key
		assets[key] = { mime = Assets.PNG, bytes = bytes }
		table.insert(children, {
			k = "image",
			p = {
				key = "img",
				asset = key,
				w = if spec then spec.width else nil,
				h = if spec then spec.height else nil,
				alt = "Grafana render of " .. title(s, inst),
			},
		})
	elseif State.pngError(s, ps) then
		table.insert(children, errorText(State.pngError(s, ps) :: string, "err"))
		table.insert(children, clickable("Open in browser (o)", "browser=" .. inst.key, "open"))
	else
		table.insert(children, muted("Rendering in Grafana...", "loading"))
	end
	table.insert(children, muted("Grafana render: " .. reason, "why"))
	return ui.col(children, { key = "body", gap = "xs" })
end

local function browserBody(inst: Repeat.Instance, ps: State.PanelState): Node
	return ui.col({
		muted(ps.decision.reason or "not drawn natively", "why"),
		clickable("Open in browser (o)", "browser=" .. inst.key, "open"),
	}, { key = "body", gap = "xs" })
end

local MODE_BADGE: { [string]: { string } } = {
	png = { "png", "info" },
	browser = { "browser", "neutral" },
}

local function panelCard(s: State, inst: Repeat.Instance, env: Env, assets: Assets.Assets, single: boolean): Node
	local ps = s.panels[inst.key]
	local head: { ui.SpanLike } = { ui.span(title(s, inst), "strong") }
	local body: Node
	if ps == nil then
		body = muted("Waiting", "wait")
	elseif ps.decision.mode == "native" then
		body = nativeBody(s, inst, ps, env, assets, single)
		if ps.status == "loading" and ps.data then
			table.insert(head, ui.span("  refreshing", "muted"))
		end
	elseif ps.decision.mode == "png" then
		body = pngBody(s, inst, ps, assets)
	else
		body = browserBody(inst, ps)
	end
	local badge = if ps then MODE_BADGE[ps.decision.mode] else nil
	if badge then
		table.insert(head, ui.span("  " .. badge[1], "muted"))
	end
	return ui.card(head, { body }, {
		key = inst.key,
		selected = s.focus == inst.key and not single,
		actions = { click = "focus=" .. inst.key, dblclick = "expand=" .. inst.key },
	})
end

-- `parent` is the view id of the node this one goes in: Tern names every
-- node `<parent id>.<key>`, and the state reveals cards by these ids.
local function layoutNode(
	n: Layout.Node,
	byKey: { [string]: Repeat.Instance },
	s: State,
	env: Env,
	assets: Assets.Assets,
	idx: number,
	parent: string
): Node
	if n.kind == "gap" then
		return { k = "el", p = { tag = "div", key = "g" .. idx, basis = n.basis, grow = 0, shrink = 0 } }
	elseif n.kind == "panel" then
		local card = panelCard(s, byKey[n.key], env, assets, false)
		local p = card.p :: { [string]: any }
		p.basis, p.grow, p.shrink = n.basis, 0, 1
		-- Grafana's panel height: a long logs panel or legend is cut here and
		-- shown whole when the panel is expanded.
		p.max = { h = string.format("%dlines", math.max(4, math.floor(n.h * M.LINES_PER_ROW + 0.5))) }
		s.card_ids[n.key] = parent .. "." .. n.key
		return card
	end
	local key = n.kind .. idx
	local children: { Node } = {}
	local kids: { Layout.Node } = (n :: any).children
	for i, c in kids do
		table.insert(children, layoutNode(c, byKey, s, env, assets, i, parent .. "." .. key))
	end
	local props = { key = key, basis = n.basis, grow = if n.kind == "col" then 0 else 1, shrink = 1 }
	if n.kind == "row" then
		props.align = "start"
		return ui.row(children, props)
	end
	return ui.col(children, props)
end

local function varChips(s: State): Node?
	local chips: { Node } = {}
	for _, v in s.vars do
		if v.hide >= 2 or v.kind == "constant" then
			continue
		end
		local value = Variables.display(v)
		local style = "strong"
		if v.status == "loading" or v.status == "pending" then
			value, style = "...", "muted"
		elseif v.status == "error" then
			value, style = v.error or "error", "error"
		elseif v.kind == "unsupported" then
			value, style = v.type_name .. " (not supported)", "muted"
		end
		local spans: { ui.SpanLike } = {}
		if v.hide == 0 then
			table.insert(spans, ui.span((v.label or v.name) .. " ", "muted"))
		end
		table.insert(spans, ui.span(value, style))
		table.insert(chips, {
			k = "el",
			p = { tag = "span", key = "v." .. v.name, class = "tg-dash-var", actions = { click = "var=" .. v.name } },
			c = { ui.text(spans) },
		})
	end
	if #chips == 0 then
		return nil
	end
	return ui.row(chips, { key = "vars", wrap = true })
end

local function header(s: State): Node
	local d = s.dashboard
	local spans: { ui.SpanLike } = {}
	if d then
		table.insert(spans, ui.span(d.title, "strong"))
		if d.folder_title then
			table.insert(spans, ui.span("  " .. d.folder_title, "muted"))
		end
	end
	if s.from and s.to then
		table.insert(spans, ui.span("  " .. Range.describe(s.from :: string, s.to :: string), "accent"))
	end
	if s.refresh_ms then
		local secs = math.floor((s.refresh_ms :: number) / 1000)
		table.insert(
			spans,
			ui.span(if s.auto then string.format("  every %ds", secs) else "  auto-refresh paused", "muted")
		)
	end
	if s.context then
		table.insert(spans, ui.span("  " .. (s.context :: string), "muted"))
	end
	local children: { Node } = { ui.text(spans, { key = "title" }) }
	local chips = varChips(s)
	if chips and not s.solo then
		table.insert(children, chips)
	end
	return ui.col(children, { key = "head", gap = "xs" })
end

local function rowHeader(s: State, sec: Repeat.SectionInstance, collapsed: boolean): Node
	local row = sec.row :: any
	local text = Interpolate.replace(row.title, Interpolate.merge(Variables.scope(s.vars), sec.scoped), {
		format = Interpolate.text,
	})
	local count = #sec.panels
	return {
		k = "el",
		p = { tag = "div", key = "rh." .. sec.key, class = "tg-dash-row", actions = { click = "row=" .. sec.key } },
		c = {
			ui.text({
				ui.span(if collapsed then "+ " else "- ", "muted"),
				ui.span(if text == "" then "Row" else text, "strong"),
				ui.span(if collapsed then string.format("  (%d panels)", count) else "", "muted"),
			}),
		},
	}
end

local function grid(s: State, env: Env, assets: Assets.Assets): { Node }
	table.clear(s.card_ids)
	local out: { Node } = {}
	for _, sec in s.sections do
		local collapsed = s.collapsed[sec.key]
		if collapsed == nil then
			collapsed = sec.row ~= nil and sec.row.collapsed
		end
		local children: { Node } = {}
		if sec.row then
			table.insert(children, rowHeader(s, sec, collapsed))
		end
		if not collapsed then
			local items: { Layout.Item } = {}
			local byKey: { [string]: Repeat.Instance } = {}
			for _, inst in sec.panels do
				table.insert(items, { key = inst.key, grid = inst.panel.grid })
				byKey[inst.key] = inst
			end
			for i, band in Layout.arrange(items) do
				table.insert(children, layoutNode(band, byKey, s, env, assets, i, "main.sec." .. sec.key))
			end
		end
		table.insert(out, ui.col(children, { key = "sec." .. sec.key }))
	end
	return out
end

local function pickerNode(s: State): Node?
	local p = s.picker
	if p == nil then
		return nil
	end
	local items = State.pickerItems(s)
	local list = table.create(#items)
	for i, it in items do
		list[i] = { id = it.id, label = it.label, detail = it.detail }
	end
	local props: { [string]: any } = {
		key = "pk",
		size = "md",
		query = p.query,
		items = list,
		selected = p.selected or (if items[1] then items[1].id else nil),
		empty = "No matches",
	}
	if p.kind == "search" then
		props.title = "Open a Grafana dashboard"
		props.placeholder = "Search dashboards"
		props.noun = "dashboards"
		props.state = if s.search.status == "loading"
			then "loading"
			elseif s.search.status == "error" then "error"
			else "ready"
		props.message = s.search.error
	elseif p.kind == "vars" then
		props.title = "Variables"
		props.placeholder = "Filter variables"
	else
		local v = Variables.find(s.vars, p.name or "")
		props.title = if v then (v.label or v.name) else p.name
		if v and v.kind == "textbox" then
			props.placeholder = "Type a value, enter to apply"
		elseif v and v.multi then
			props.placeholder = "Filter; space toggles, enter applies"
			props.current = p.chosen
		else
			props.placeholder = "Filter values"
			props.current = if v then v.values else nil
		end
	end
	return { k = "picker", p = props }
end

function M.view(s: State, env: Env): (Effect.View, Assets.Assets)
	local assets: Assets.Assets = {}
	local main: { Node } = {}
	if s.phase == "error" then
		table.insert(main, errorText(s.error or "error", "error"))
		if s.uid then
			table.insert(main, clickable("Retry (r)", "retry=1", "retry"))
		end
	elseif s.phase == "search" then
		table.insert(main, muted("Pick a dashboard to open; / searches again later.", "search"))
	elseif s.phase == "loading" or s.dashboard == nil then
		table.insert(main, muted("Loading dashboard", "loading"))
	else
		table.insert(main, header(s))
		if s.vars_error then
			table.insert(main, errorText(s.vars_error :: string, "verr"))
		end
		if s.settings.status == "error" then
			table.insert(main, muted("Grafana settings: " .. (s.settings.error or "unavailable"), "serr"))
		end
		local single = s.solo ~= nil or s.expanded
		if not Variables.settled(s.vars) and #s.order == 0 then
			table.insert(main, muted("Resolving variables", "vwait"))
		elseif single then
			local inst = if s.focus then Repeat.find(s.sections, s.focus :: string) else nil
			if inst then
				table.insert(main, panelCard(s, inst, env, assets, true))
			else
				table.insert(main, muted("Panel not found on this dashboard", "missing"))
			end
		else
			for _, n in grid(s, env, assets) do
				table.insert(main, n)
			end
		end
		table.insert(main, muted(if s.solo then M.SOLO_HINT else M.HINT, "hint"))
	end
	local picker = pickerNode(s)
	return {
		main = ui.col(main, { key = "main", role = "tern-grafana.dashboard" }),
		layer = if picker then ui.col({ picker }, { key = "layer" }) else nil,
	},
		assets
end

return M
