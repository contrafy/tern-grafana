--!strict
-- Views of the dashboard and panel blocks: a header (title, range, refresh),
-- variable chips, rows with their panels laid out by gridPos fractions, and
-- each panel on its ladder rung with the reason it left the native one.
-- Native panels come from lib/panels/registry; their rendered node and
-- assets are memoized per panel until its data, extra answers, live tick,
-- range, cursor or size changes, so a focus move does not rebuild every SVG.
-- Panel metadata as Grafana's panel chrome shows it: the time override info
-- ("Last 1 hour timeshift -1h") in the header, and the header's title
-- items: a query error icon (its message on hover, in the body of the
-- focused card), the description behind an info marker (hover title; in
-- full in the expanded view) and the panel links behind a link icon (a
-- menu for several); transparent panels without card chrome; annotation
-- layer switches next to the variables.

local AlertStates = require("./alert_states")
local Assets = require("../render/assets")
local ClockZone = require("../panels/clock_zone")
local Common = require("../panels/common")
local Core = require("./core")
local Effect = require("../effect")
local Env = require("../env")
local Interpolate = require("./interpolate")
local Layers = require("./layers")
local Layout = require("./layout")
local Range = require("../time/range")
local Registry = require("../panels/registry")
local RenderPng = require("./render_png")
local Repeat = require("./repeat")
local State = require("./state")
local Variables = require("./variables")
local ui = require("../ui")
local Tbl = require("../tbl")

type Env = Env.Env
type Node = ui.Node
type State = State.State

local M = {}

M.HINT = "arrows focus  enter expand  v variables  1-9 [ ] - + range  r refresh  a auto  l labels  L logs  S sync  "
	.. "o browser  p pin  I investigate  / search"
-- Tern's text line in px: card heights are given in lines.
M.LINE_PX = 16
-- Card chrome in px: the head line with the card's top and bottom padding
-- (a card without a head, an untitled panel's, has the padding only); a
-- panel with a description or links has a chip line under the head.
M.CARD_CHROME_PX = 40
M.CHIP_LINE_PX = 24
-- A card head's px (Tern's sf-card-head: a line and 12 px padding).
M.CARD_HEAD_PX = 28
-- Grafana's panel border, above and below.
M.BORDER_PX = 2
-- A transparent panel's chrome (panels2.css tgp2-plain): 4 px padding and a
-- 1 px border above and below; its head and chip lines are each a line
-- with the 4 px gap under it.
M.PLAIN_CHROME_PX = 10
M.PLAIN_GAP_PX = 4
M.PLAIN_PAD_PX = 4

-- A panel's Grafana height (gridPos h rows of 30 px with 8 px margins,
-- lib/dashboard/render_png size) in Tern lines, never above it.
function M.heightLines(h: number): number
	local _, px = RenderPng.size(1, h)
	return math.max(4, math.floor(px / M.LINE_PX))
end

-- The card body's height in px under the card's height cap (heightLines),
-- below the head and the chip line when the card has them. `flush`: a
-- panel whose plugin calls PanelPlugin.setNoPadding() (PanelChrome padding
-- none): the box less the border and the head and chip lines only
-- (dashboard.css tg-flush pulls the body over the card's padding).
function M.cardHeight(h: number, chips: boolean, head: boolean, transparent: boolean?, flush: boolean?): number
	local chrome: number
	if transparent then
		local line = M.LINE_PX + M.PLAIN_GAP_PX
		local lines = (if head then line else 0) + (if chips then line else 0)
		chrome = if flush
			then M.BORDER_PX + (if lines > 0 then M.PLAIN_PAD_PX else 0) + lines
			else M.PLAIN_CHROME_PX + lines
	elseif flush then
		chrome = M.BORDER_PX + (if head then M.CARD_HEAD_PX else 0) + (if chips then M.CHIP_LINE_PX else 0)
	else
		chrome = M.CARD_CHROME_PX - (if head then 0 else M.LINE_PX) + (if chips then M.CHIP_LINE_PX else 0)
	end
	return math.max(M.heightLines(h) * M.LINE_PX - chrome, 0)
end

M.SOLO_HINT = "left/right cursor  x exemplar  enter trace  1-9 [ ] - + range  r refresh  l labels  L logs  S sync  "
	.. "o browser  y copy URL  I investigate"

-- The panel's title with its variables, kept in the scope memo per instance;
-- "" for an untitled panel, which Grafana draws without a header.
local function title(s: State, inst: Repeat.Instance): string
	local t = inst.panel.title
	if t == "" then
		return ""
	end
	local titles = Core.memo(s).titles
	local text = titles[inst]
	if text == nil then
		text = Interpolate.replace(t, State.panelScope(s, inst), { format = Interpolate.text })
		titles[inst] = text
	end
	return text :: string
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

-- The query errors of a panel (PanelChrome's statusMessage): its data's
-- errors, or the failed query's message.
local function panelErrors(ps: State.PanelState?): { string }
	if ps == nil or ps.decision.mode ~= "native" then
		return {}
	elseif ps.data then
		return (ps.data :: any).errors
	elseif ps.status == "error" then
		return { ps.error or "query failed" }
	end
	return {}
end

-- The body role: dashboard.css grows it to the fixed-height card's bottom;
-- a flush body is also pulled over the card's padding.
local BODY_ROLE = "tern-grafana.panel-body"
local FLUSH_ROLE = "tern-grafana.panel-body-flush"

-- The rendered native panel, memoized on its inputs; `chips` and `head`
-- when the card draws a chip line (metaRow) and a head line above it.
-- Query errors are a head icon (metaRow); their text shows in the body
-- of the focused card and the expanded panel (`focused`, `single`).
local function nativeBody(
	s: State,
	inst: Repeat.Instance,
	ps: State.PanelState,
	env: Env,
	assets: Assets.Assets,
	single: boolean,
	chips: boolean,
	head: boolean,
	flush: boolean,
	focused: boolean
): Node
	local data = ps.data
	local role = if flush then FLUSH_ROLE else BODY_ROLE
	if data == nil then
		if ps.status == "error" then
			-- PanelDataErrorView over the empty data a failed query leaves.
			local children: { Node } = {}
			if single or focused then
				table.insert(children, errorText(ps.error or "query failed", "err"))
			end
			table.insert(children, Common.noData(inst.panel.json, env, "nodata"))
			return ui.col(children, { key = "body", gap = "xs", role = role })
		end
		return muted("Loading", "loading")
	end
	local showErrors = (single or focused) and #data.errors > 0
	local cursor = if single then s.cursor else nil
	local exemplar = if single then s.exemplar else nil
	local labels = s.labels[inst.key]
	local page = s.pages[inst.key]
	local frame = s.frames[inst.key]
	-- Text panels interpolate variables into their content.
	local signature = Core.signature(s)
	local memo = s.memo[inst.key]
	-- Snapped to the query interval: a refresh with the same answer is a memo hit.
	local pr = State.drawRange(s, ps)
	local live = if ps.live_ms then s.live_tick else nil
	local annotations = Layers.marks(s, inst.panel.id)
	local design = Core.designWidth(env)
	if
		memo
		and memo.data == data
		and memo.cursor == cursor
		and memo.exemplar == exemplar
		and memo.show_errors == showErrors
		and memo.flush == flush
		and memo.single == single
		and memo.labels == labels
		and memo.page == page
		and memo.frame == frame
		and memo.signature == signature
		and memo.json == inst.panel.json
		and memo.title == title(s, inst)
		and memo.extra_gen == ps.extra_gen
		and memo.live == live
		and memo.features == s.settings.features
		and memo.annotations == annotations
		and memo.from_ms == (if pr then pr.from_ms else nil)
		and memo.to_ms == (if pr then pr.to_ms else nil)
		and memo.design == design
	then
		for k, a in memo.assets do
			assets[k] = a
		end
		return memo.node
	end
	local panelJson = Tbl.copy(inst.panel.json)
	panelJson.title = title(s, inst)
	local scope = State.panelScope(s, inst)
	local pw, ph = RenderPng.gridSize(if single then 24 else inst.panel.grid.w, inst.panel.grid.h, design)
	local json = inst.panel.json
	-- An expanded panel is not height-capped.
	local cardH = if single
		then nil
		else M.cardHeight(inst.panel.grid.h, chips, head, inst.panel.json.transparent == true, flush)
	local d = s.dashboard
	local ok, node, own = pcall(Registry.view, panelJson, data.frames, env, {
		key = inst.key,
		cursor = cursor,
		exemplars = data.exemplars,
		exemplar = exemplar,
		from_ms = if pr then pr.from_ms else nil,
		to_ms = if pr then pr.to_ms else nil,
		time = if pr then { from_ms = pr.from_ms, to_ms = pr.to_ms } else nil,
		size = { w = pw, h = ph },
		card_height = cardH,
		page = page,
		frame = frame,
		extra = ps.extra,
		timezone = if d then d.timezone else nil,
		local_offset_min = env.local_offset_min,
		offset_min = ClockZone.dashboardOffset(
			if d then d.timezone else nil,
			env.local_offset_min or 0,
			env.local_offset_at
		),
		base_url = Core.browserBase(s),
		features = s.settings.features,
		annotations = annotations,
		show_labels = labels,
		-- The panel JSON before the title was replaced: the registry's
		-- migration cache key.
		source = json,
		interpolate = function(text: string): string
			return Interpolate.replace(text, scope, { format = Interpolate.content })
		end,
		replace = function(text: string): string
			return Interpolate.replace(text, scope)
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
	if showErrors then
		for i, e in data.errors do
			table.insert(children, errorText(e, "e" .. i))
		end
	end
	for i, w in data.warnings do
		table.insert(children, muted(w, "w" .. i))
	end
	local body = ui.col(children, { key = "body", gap = "xs", role = role })
	s.memo[inst.key] = {
		data = data,
		cursor = cursor,
		exemplar = exemplar,
		single = single,
		show_errors = showErrors,
		flush = flush,
		labels = labels,
		page = page,
		frame = frame,
		signature = signature,
		json = inst.panel.json,
		title = title(s, inst),
		extra_gen = ps.extra_gen,
		live = live,
		features = s.settings.features,
		annotations = annotations,
		from_ms = if pr then pr.from_ms else nil,
		to_ms = if pr then pr.to_ms else nil,
		design = design,
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
				alt = "Grafana render of "
					.. (if inst.panel.title ~= "" then title(s, inst) else "panel " .. inst.panel.id),
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

-- The panel description (Markdown in Grafana), interpolated with the
-- default format as VizPanel.getDescription does; kept in the scope memo
-- per instance.
local function description(s: State, inst: Repeat.Instance): string?
	local raw = inst.panel.json.description
	if type(raw) ~= "string" then
		return nil
	end
	local descriptions = Core.memo(s).descriptions
	local cached: string | false | nil = descriptions[inst]
	if cached == nil then
		local text = string.match(Interpolate.replace(raw, State.panelScope(s, inst)), "^%s*(.-)%s*$")
		local found: string | false = if text and text ~= "" then text else false
		descriptions[inst] = found
		cached = found
	end
	return if cached then cached else nil
end

-- Grafana's header glyphs (Nerd Font, Material Design): PanelStatus's
-- warning and VizPanelLinks' external-link-alt.
M.ERROR_GLYPH = utf8.char(0xF0026)
M.LINK_GLYPH = utf8.char(0xF03CC)
-- An annotation layer's switch in the variable bar (toggle-switch and
-- toggle-switch-off-outline).
M.SWITCH_ON = utf8.char(0xF0521)
M.SWITCH_OFF = utf8.char(0xF0A19)

-- The head's title items; nil when the panel has none: the query error
-- (PanelChrome's PanelStatus, its message on hover), the info marker
-- (description on hover) and the panel links (VizPanelLinks: one link
-- opens on click, several open a menu). The expanded panel lists the links
-- in full and shows the description and errors in its body instead.
local function metaRow(s: State, inst: Repeat.Instance, env: Env, single: boolean): Node?
	local chips: { Node } = {}
	local errors = panelErrors(s.panels[inst.key])
	if #errors > 0 then
		table.insert(chips, {
			k = "el",
			p = { tag = "span", key = "err", class = "tgp2-err", title = table.concat(errors, "\n") },
			c = { ui.text({ ui.span(M.ERROR_GLYPH, "icon error") }) },
		})
	end
	local desc = description(s, inst)
	if desc and not single then
		table.insert(chips, {
			k = "el",
			p = { tag = "span", key = "info", class = "tgp2-info", title = desc },
			c = { ui.text({ ui.span("i", "muted") }) },
		})
	end
	local links = State.panelLinks(s, inst, env)
	if single then
		for i, l in links do
			table.insert(chips, {
				k = "el",
				p = {
					tag = "span",
					key = "l" .. i,
					class = "tgp2-link",
					title = l.url,
					actions = { click = "plink=" .. i .. ":" .. inst.key },
				},
				c = { ui.text({ ui.span(l.title, "accent") }) },
			})
		end
	elseif #links > 0 then
		table.insert(chips, {
			k = "el",
			p = {
				tag = "span",
				key = "links",
				class = "tgp2-links",
				title = if #links == 1 then links[1].title else "Panel links",
				actions = { click = if #links == 1 then "plink=1:" .. inst.key else "plinks=" .. inst.key },
			},
			c = { ui.text({ ui.span(M.LINK_GLYPH, "icon muted") }) },
		})
	end
	if #chips == 0 then
		return nil
	end
	return ui.row(chips, { key = "meta", gap = "xs", wrap = single, align = "center" })
end

-- `id` is the card's view id in a dashboard grid (nil for the expanded
-- panel): the head's `end` names its chip row by id.
local function panelCard(
	s: State,
	inst: Repeat.Instance,
	env: Env,
	assets: Assets.Assets,
	single: boolean,
	id: string?
): Node
	local ps = s.panels[inst.key]
	-- Empty for an untitled panel without time info or a ladder badge: no
	-- header line, as in Grafana.
	local head: { ui.SpanLike } = {}
	local function addHead(text: string, style: string)
		table.insert(head, ui.span(if #head > 0 then "  " .. text else text, style))
	end
	local name = title(s, inst)
	if name ~= "" then
		addHead(name, "strong")
	end
	-- Grafana's alert state title item (VizPanelRenderer): a heart in the
	-- state's color after the title.
	local alert = Layers.alertState(s, inst.panel.id)
	if alert then
		local glyph, style = AlertStates.icon(alert)
		if #head > 0 then
			table.insert(head, ui.span(" "))
		end
		table.insert(head, ui.span(glyph, style))
	end
	local info = if ps and ps.time then ps.time.info else ""
	-- Built before the body: a capped body's height counts its chip and head
	-- lines. A capped card draws the chips at its head's end, the way
	-- Grafana's panel header holds the info icon and links next to the title.
	local meta = metaRow(s, inst, env, single)
	local transparent = inst.panel.json.transparent == true
	local metaInHead = meta ~= nil and id ~= nil and not single and not transparent
	local hasHead = name ~= "" or info ~= "" or metaInHead or alert ~= nil
	local flush = ps ~= nil and ps.decision.mode == "native" and Registry.noPadding(inst.panel.json, env)
	local body: Node
	if ps == nil then
		body = muted("Waiting", "wait")
	elseif ps.decision.mode == "native" then
		body = nativeBody(
			s,
			inst,
			ps,
			env,
			assets,
			single,
			meta ~= nil and not metaInHead,
			hasHead,
			flush,
			s.focus == inst.key
		)
		-- Not on an untitled panel: a head line coming and going would shift it.
		if ps.status == "loading" and ps.data and name ~= "" then
			addHead("refreshing", "muted")
		end
	elseif ps.decision.mode == "png" then
		body = pngBody(s, inst, ps, assets)
	else
		body = browserBody(inst, ps)
	end
	if info ~= "" then
		addHead(info, "info")
	end
	local badge = if ps then MODE_BADGE[ps.decision.mode] else nil
	if badge then
		addHead(badge[1], "muted")
	end
	local children: { Node } = {}
	if meta then
		table.insert(children, meta)
	end
	local desc = if single then description(s, inst) else nil
	if desc then
		table.insert(children, { k = "md", p = { key = "desc", text = desc } })
	end
	table.insert(children, body)
	local actions = { click = "focus=" .. inst.key, dblclick = "expand=" .. inst.key }
	local selected = s.focus == inst.key and not single
	if transparent then
		-- Grafana's transparent panels have no background or border.
		if #head > 0 then
			table.insert(children, 1, ui.text(head, { key = "head", truncate = "end" }))
		end
		local class = "tgp2-plain"
		if flush and #children == 1 then
			-- A flush body with nothing above it also takes the top padding.
			class ..= " tgp2-flush-top"
		end
		return {
			k = "el",
			p = {
				tag = "div",
				key = inst.key,
				class = if selected then class .. " tgp2-sel" else class,
				actions = actions,
			},
			c = children,
		}
	end
	local props: { [string]: any } = {
		key = inst.key,
		selected = selected,
		actions = actions,
		["end"] = if metaInHead then (id :: string) .. ".meta" else nil,
	}
	return ui.card(head, children, props)
end

-- A grid node's flex shrink. Grafana gives a w-column panel f(W + m) - m
-- px (f its share of the grid's W, m the margin): every node loses
-- (1 - f)m. A row's bases sum to 1 and its n nodes overflow it by its
-- (n - 1) gaps, which flexbox takes from each node by shrink x basis;
-- shrink (1 - f) / f makes that loss (1 - f) x gap for every node, so a
-- half-empty last row of repeats is as wide per panel as a full one.
local function shrinkOf(f: number): number
	return if f > 0 and f < 1 then (1 - f) / f else 1
end

-- `parent` is the view id of the node this one goes in: Tern names every
-- node `<parent id>.<key>`, and the state reveals cards by these ids.
-- `stacked`: below Grafana's md breakpoint every panel takes the full width;
-- otherwise a node's width is its gridPos share of its parent less its share
-- of the gaps (shrinkOf) and a band never wraps.
local function layoutNode(
	n: Layout.Node,
	byKey: { [string]: Repeat.Instance },
	s: State,
	env: Env,
	assets: Assets.Assets,
	idx: number,
	parent: string,
	stacked: boolean
): Node
	local basis = if stacked then 1 else n.basis
	local shrink = shrinkOf(basis)
	if n.kind == "gap" then
		return {
			k = "el",
			p = { tag = "div", key = "g" .. idx, basis = if stacked then 0 else basis, grow = 0, shrink = shrink },
		}
	elseif n.kind == "panel" then
		local id = parent .. "." .. n.key
		local card = panelCard(s, byKey[n.key], env, assets, false, id)
		local p = card.p :: { [string]: any }
		p.basis, p.grow, p.shrink = basis, 0, shrink
		-- Every panel type is exactly Grafana's panel height, as in its grid:
		-- short content leaves the card's room below it, content past it (a
		-- long logs panel, a legend, a wrapped clock) is clipped here and
		-- shown whole when the panel is expanded.
		local lines = string.format("%dlines", M.heightLines(n.h))
		p.min = { w = 0, h = lines }
		p.max = { h = lines }
		s.card_ids[n.key] = id
		return card
	end
	local key = n.kind .. idx
	local children: { Node } = {}
	local kids: { Layout.Node } = (n :: any).children
	for i, c in kids do
		table.insert(children, layoutNode(c, byKey, s, env, assets, i, parent .. "." .. key, stacked))
	end
	local props: { [string]: any } = { key = key, basis = basis, grow = 0, shrink = shrink, min = { w = 0 } }
	if n.kind == "row" then
		props.align = "start"
		props.wrap = stacked
		return ui.row(children, props)
	end
	return ui.col(children, props)
end

-- A dropdown chip's caret (Grafana's angle-down).
M.CARET = "▾"

-- DashboardLinksControls after the variables: a "link" is a button, a
-- "dashboards" link a dropdown of its dashboards or a button per dashboard.
local function linkChips(s: State, env: Env, chips: { Node })
	local function chip(key: string, text: string, tooltip: string?, action: string)
		table.insert(chips, {
			k = "el",
			p = { tag = "span", key = key, class = "tg-dash-var", title = tooltip, actions = { click = action } },
			c = { ui.text({ ui.span(text, "strong") }) },
		})
	end
	for i, l in State.dashboardLinks(s, env) do
		if l.kind == "link" then
			chip("dl." .. i, if l.title == "" then l.url else l.title, l.tooltip, "dl=" .. i)
		elseif l.dropdown then
			chip(
				"dl." .. i,
				(if l.title == "" then "Dashboards" else l.title) .. " " .. M.CARET,
				l.tooltip,
				"dls=" .. i
			)
		else
			local hits = s.dash_hits[i]
			if hits then
				for n, h in hits do
					chip(string.format("dl.%d.%d", i, n), h.title, l.tooltip, string.format("dl=%d:%d", i, n))
				end
			end
		end
	end
end

local function varChips(s: State, env: Env): Node?
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
	-- DashboardDataLayerControls: a switch per annotation layer that is not
	-- hidden, its error after the name (DataLayerControl's ControlsLabel).
	for _, t in s.layers.toggles do
		local err: string? = nil
		for _, l in s.layers.annotations do
			if l.def.name == t.name and l.error then
				err = l.error
			end
		end
		local spans: { ui.SpanLike } = { ui.span(t.name .. " ", "muted") }
		if err then
			table.insert(spans, ui.span(M.ERROR_GLYPH .. " ", "icon error"))
		end
		table.insert(
			spans,
			ui.span(if t.on then M.SWITCH_ON else M.SWITCH_OFF, if t.on then "icon accent" else "icon muted")
		)
		table.insert(chips, {
			k = "el",
			p = {
				tag = "span",
				key = "a." .. t.name,
				class = "tg-dash-var",
				title = err,
				actions = { click = "layer=" .. t.name },
			},
			c = { ui.text(spans) },
		})
	end
	if not s.solo then
		linkChips(s, env, chips)
	end
	if #chips == 0 then
		return nil
	end
	return ui.row(chips, { key = "vars", wrap = true })
end

local function header(s: State, env: Env): Node
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
	if s.sync.on then
		table.insert(spans, ui.span("  synced", "accent"))
	end
	local children: { Node } = { ui.text(spans, { key = "title" }) }
	local chips = varChips(s, env)
	if chips and not s.solo then
		table.insert(children, chips)
	end
	return ui.col(children, { key = "head", gap = "xs" })
end

local function rowHeader(s: State, sec: Repeat.SectionInstance, collapsed: boolean): Node
	local row = sec.row :: any
	local text = Interpolate.replace(row.title, Interpolate.merge(Core.plainScope(s), sec.scoped), {
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
	local stacked = Core.designWidth(env) < Core.STACK_BELOW_PX
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
				table.insert(children, layoutNode(band, byKey, s, env, assets, i, "main.sec." .. sec.key, stacked))
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
	elseif p.kind == "links" then
		props.title = if p.dash_link then "Dashboards" else "Panel links"
		props.placeholder = "Filter links"
	elseif p.kind == "vars" then
		props.title = if #s.layers.toggles > 0 then "Variables and annotations" else "Variables"
		props.placeholder = "Filter variables"
	else
		local v = Variables.find(s.vars, p.name or "")
		props.title = if v then (v.label or v.name) else p.name
		if v and v.adhoc then
			local step = p.step or "filters"
			if step ~= "filters" then
				-- The filter so far: `key`, `key op`.
				props.title = (v.label or v.name)
					.. ": "
					.. (p.key or "")
					.. (if step == "value" then " " .. (p.op or "") else "")
			end
			props.placeholder = if step == "filters"
				then "Filters; enter edits"
				elseif step == "key" then "Key"
				elseif step == "op" then "Operator"
				elseif p.chosen then "Values; space toggles, enter applies"
				else "Value"
			if p.list_status then
				props.state = p.list_status
				props.message = p.list_error
			end
			if p.chosen then
				local ids = table.create(#(p.chosen :: { string }))
				for i, x in p.chosen :: { string } do
					ids[i] = "v:" .. x
				end
				props.current = ids
			end
		elseif v and v.kind == "textbox" then
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
		table.insert(main, header(s, env))
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
			local inst = if s.focus then Core.find(s, s.focus :: string) else nil
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
