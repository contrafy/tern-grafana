--!strict
-- marcusolsson-dynamictext-panel 6.3.1 (github.com/grafana/business-text:
-- src/components/Text/Text.tsx, src/utils/html.ts, rows.ts). The content is a
-- Handlebars template (lib/panels/handlebars) applied to the panel's data:
-- - the frame is the first frame with fields (renderMode data) or the first
--   frame (Grafana's frame picker starts there); a frame without rows draws
--   options.defaultContent through the same pipeline with no data;
-- - a row is an object keyed by each field's config displayName or name; the
--   value is the formatted text (prefix, value, suffix) when the field has a
--   unit, else the raw value; options.status adds `statusColor`;
-- - renderMode everyRow applies the template per row (each in its own
--   bordered block), allRows once to `{ data: rows }`, data once to
--   `{ data: rows per frame }`;
-- - the output goes through markdown-it with HTML enabled: render() when
--   options.wrap is set (Markdown blocks between HTML blocks, as the text
--   panel draws them), renderInline() otherwise (tags pass through, Markdown
--   emphasis, code, links and line breaks apply to the text between them).
--   The editor language (html or markdown) only changes the editor;
-- - the HTML is sanitized (lib/panels/html) and drawn as `el` nodes whose
--   inline styles compile to classes of plugin/dynamictext.css
--   (lib/panels/html_style). data: images become image assets. Style the
--   compiler cannot draw is listed under the panel.
-- Dashboard variables are not interpolated into the content (the plugin
-- does not either); the variable and variableValue helpers read them.
-- Panels that run their own JavaScript (helpers, afterRender) or load
-- templates or stylesheets from URLs are not drawn natively. options.styles
-- (CSS the plugin scopes to the panel) applies only when it is plain
-- declarations, which then style the panel; rule sets with selectors are
-- skipped and noted, since their selectors target the browser's DOM.

local Assets = require("../render/assets")
local Base64 = require("../auth/base64")
local Common = require("./common")
local Convert = require("./transforms/convert")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local FieldDisplay = require("./fielddisplay")
local Frame = require("../frame/types")
local Handlebars = require("./handlebars")
local Html = require("./html")
local HtmlStyle = require("./html_style")
local Json = require("./json")
local Str = require("../str")
local Text = require("./text")
local ui = require("../ui")

type Env = Env.Env
type Frame = Frame.Frame
type Node = ui.Node

local M = {}

M.types = { "marcusolsson-dynamictext-panel" }
-- module.ts setNoPadding().
M.no_padding = true

-- Tern blob limit.
local MAX_IMAGE_BYTES = 256 * 1024

-- PanelChrome getContentStyle with the plugin's setNoPadding(): the panel's
-- 1 px border on each side, no padding, and the title header's height
-- (panel.headerHeight grid units).
local PANEL_BORDER_PX = 1
local PANEL_HEADER_PX = 32

local IMAGE_MIME: { [string]: boolean } = {
	["image/svg+xml"] = true,
	["image/png"] = true,
	["image/jpeg"] = true,
	["image/gif"] = true,
	["image/webp"] = true,
}

local function nonEmpty(env: Env, v: any): boolean
	local s = Json.str(env, v)
	if s then
		return Str.trim(s) ~= ""
	end
	local list = Json.tbl(env, v)
	return list ~= nil and #list > 0
end

function M.supports(panel: any, env: Env): (boolean, string?)
	local why = FieldConfig.unsupported(panel, env)
	if why then
		return false, why
	end
	local o = Json.obj(env, Json.path(env, panel, "options"))
	local js: { string } = {}
	if nonEmpty(env, o.helpers) then
		table.insert(js, "helpers")
	end
	if nonEmpty(env, o.afterRender) then
		table.insert(js, "afterRender")
	end
	if #js > 0 then
		return false, "the panel runs its own JavaScript (" .. table.concat(js, ", ") .. ")"
	end
	if nonEmpty(env, o.contentPartials) then
		return false, "the panel loads templates from URLs (content partials)"
	end
	if nonEmpty(env, o.externalStyles) then
		return false, "the panel loads stylesheets from URLs (external styles)"
	end
	return true, nil
end

-- Template data -------------------------------------------------------------------

type Ctx = {
	panel: any,
	env: Env,
	opts: Common.Options,
	display: FieldDisplay.Options,
	status: string?,
}

-- Rows of frame `index` as template objects.
local function rowsOf(ctx: Ctx, frames: { Frame }, index: number): { any }
	local items: { FieldConfig.Item } = {}
	for _, item in FieldConfig.resolve(ctx.panel, frames, ctx.env) do
		if item.frame_index == index then
			table.insert(items, item)
		end
	end
	local n = 0
	for _, item in items do
		n = math.max(n, #item.field.values)
	end
	local rows: { any } = table.create(n)
	for i = 1, n do
		local values: { [string]: any } = {}
		local keys: { string } = {}
		for _, item in items do
			local key = item.config.display_name or item.field.name
			local v = item.field.values[i]
			if v == Frame.NULL or v == ctx.env.null then
				v = nil
			end
			local unit = item.config.unit
			local d: FieldDisplay.Display? = nil
			if (unit and unit ~= "") or ctx.status == item.field.name then
				d = FieldDisplay.display(item, v, ctx.display)
			end
			if unit and unit ~= "" and d then
				v = FieldDisplay.joined(d)
			end
			if values[key] == nil and not table.find(keys, key) then
				table.insert(keys, key)
			end
			values[key] = v
			if ctx.status then
				if ctx.status == item.field.name and d then
					values.statusColor = d.color
				end
				if not table.find(keys, "statusColor") then
					table.insert(keys, "statusColor")
				end
			end
		end
		rows[i] = Handlebars.object(values, keys)
	end
	return rows
end

local function rowCount(frame: Frame): number
	local n = 0
	for _, f in frame.fields do
		n = math.max(n, #f.values)
	end
	return n
end

-- Helpers that read the dashboard -----------------------------------------------

local function helpers(ctx: Ctx, frames: { Frame }, frameIndex: number?): { [string]: Handlebars.Helper }
	local env, opts = ctx.env, ctx.opts
	local timeEnv = { now_ms = env.now_ms, local_offset_min = opts.local_offset_min, null = env.null }
	local function interpolate(s: string): string
		return if opts.interpolate then opts.interpolate(s) else s
	end
	local function variable(a: { any }): any
		local name = Handlebars.toString(a[1])
		local base, fmt = string.match(name, "^(__from):(.+)$")
		if base == nil then
			base, fmt = string.match(name, "^(__to):(.+)$")
		end
		if base and fmt then
			local raw = interpolate("$" .. base)
			local ms = tonumber(raw)
			if ms == nil then
				return { raw }
			elseif fmt == "date" or fmt == "date:iso" then
				return { Convert.format(ms, "YYYY-MM-DDTHH:mm:ss.SSS[Z]", "utc", timeEnv) }
			elseif fmt == "date:seconds" then
				return { string.format("%.0f", ms / 1000) }
			elseif string.sub(fmt, 1, 5) == "date:" then
				return { Convert.format(ms, string.sub(fmt, 6), opts.timezone, timeEnv) }
			end
			return { raw }
		end
		local json = interpolate("${" .. name .. ":json}")
		if json ~= "${" .. name .. ":json}" then
			local ok, v = pcall(env.decode, json)
			if ok and type(v) == "table" then
				local out: { string } = {}
				for _, x in v do
					table.insert(out, Handlebars.toString(x))
				end
				return out
			elseif ok and type(v) == "string" then
				return { v }
			end
		end
		return { interpolate("$" .. name) }
	end
	local frame = if frameIndex then frames[frameIndex] else nil
	return {
		variable = variable,
		variableValue = function(a: { any }): any
			return interpolate(Handlebars.toString(a[1]))
		end,
		fieldStatusColor = function(a: { any }): any
			if frame == nil then
				return ""
			end
			local name = a[1]
			for _, item in FieldConfig.resolve(ctx.panel, frames, env) do
				if item.frame_index == frameIndex and item.field.name == name then
					local idx = if type(a[2]) == "number" then a[2] else 0
					local v = item.field.values[idx + 1]
					return FieldDisplay.display(item, if v == Frame.NULL then nil else v, ctx.display).color
				end
			end
			return ""
		end,
		date = function(a: { any }, o: Handlebars.Options): any
			local v, pattern = a[1], a[2]
			if not o.block and #a == 0 then
				v = nil
			end
			local fmt = if type(pattern) == "string" then pattern else "MMMM DD, YYYY"
			local ms = if v == nil then env.now_ms else Convert.parse(v, nil, opts.timezone, timeEnv)
			return Convert.format(ms, fmt, opts.timezone, timeEnv)
		end,
	}
end

-- markdown-it ---------------------------------------------------------------------

local function escapeText(s: string): string
	s = string.gsub(s, "&(#?%w+;)", "\0%1")
	s = string.gsub(s, "&", "&amp;")
	s = string.gsub(s, "%z", "&")
	s = string.gsub(s, "<", "&lt;")
	s = string.gsub(s, ">", "&gt;")
	return (string.gsub(s, '"', "&quot;"))
end

local function attrEscape(s: string): string
	return (string.gsub(string.gsub(s, "&", "&amp;"), '"', "&quot;"))
end

-- Emphasis, strikethrough, links and images in a run of escaped text.
local function emphasis(s: string): string
	s = string.gsub(s, "!%[([^%]]*)%]%(%s*([^%s%)]+)%s*%)", '<img src="%2" alt="%1">')
	s = string.gsub(s, "%[([^%]]+)%]%(%s*([^%s%)]+)%s*%)", '<a href="%2">%1</a>')
	s = string.gsub(s, "%*%*([^%s%*][^%*]-)%*%*", "<strong>%1</strong>")
	s = string.gsub(s, "%f[%w_]__([^%s_][^_]-)__%f[^%w_]", "<strong>%1</strong>")
	s = string.gsub(s, "~~([^%s~][^~]-)~~", "<s>%1</s>")
	s = string.gsub(s, "%*([^%s%*][^%*]-)%*", function(inner: string): string
		return if string.match(inner, "%s$") then "*" .. inner .. "*" else "<em>" .. inner .. "</em>"
	end)
	s = string.gsub(s, "%f[%w_]_([^%s_][^_]-)_%f[^%w_]", function(inner: string): string
		return if string.match(inner, "%s$") then "_" .. inner .. "_" else "<em>" .. inner .. "</em>"
	end)
	return s
end

-- md.renderInline(src) with `html: true`: tags, comments and autolinks pass
-- through, code spans and backslash escapes are literal, the text between
-- gets emphasis and links, and a line ending in two spaces breaks.
function M.renderInline(src: string): string
	local out: { string } = {}
	local text: { string } = {}
	local function flush()
		if #text > 0 then
			local s = emphasis(escapeText(table.concat(text)))
			s = string.gsub(s, " %s+\n", "<br>\n")
			table.insert(out, s)
			table.clear(text)
		end
	end
	local i, n = 1, #src
	while i <= n do
		local c = string.sub(src, i, i)
		if c == "\\" and i < n then
			local d = string.sub(src, i + 1, i + 1)
			if d == "\n" then
				flush()
				table.insert(out, "<br>\n")
				i += 2
				continue
			elseif string.match(d, "%p") then
				flush()
				table.insert(out, escapeText(d))
				i += 2
				continue
			end
			table.insert(text, c)
			i += 1
		elseif c == "`" then
			local run = string.match(src, "^`+", i) :: string
			local close = string.find(src, run, i + #run, true)
			while close and string.sub(src, close + #run, close + #run) == "`" do
				close = string.find(src, run, close + #run + 1, true)
			end
			if close then
				flush()
				local code = string.sub(src, i + #run, close - 1)
				code = string.gsub(code, "\n", " ")
				if string.match(code, "^ .* $") and not string.match(code, "^%s*$") then
					code = string.sub(code, 2, -2)
				end
				table.insert(out, "<code>" .. escapeText(code) .. "</code>")
				i = close + #run
			else
				table.insert(text, run)
				i += #run
			end
		elseif c == "<" then
			local auto = string.match(src, "^<(%a[%w+.-]*:[^%s<>]*)>", i)
			if auto then
				flush()
				table.insert(out, '<a href="' .. attrEscape(auto) .. '">' .. escapeText(auto) .. "</a>")
				i += #auto + 2
				continue
			end
			local stop: number? = nil
			if string.sub(src, i, i + 3) == "<!--" then
				local e = string.find(src, "-->", i + 4, true)
				stop = if e then e + 2 else nil
			else
				local tag = Html.tagAt(src, i)
				stop = if tag then tag.last else nil
			end
			if stop then
				flush()
				table.insert(out, string.sub(src, i, stop))
				i = stop + 1
			else
				table.insert(text, c)
				i += 1
			end
		else
			local j = string.find(src, "[\\`<]", i) or n + 1
			table.insert(text, string.sub(src, i, j - 1))
			i = j
		end
	end
	flush()
	return table.concat(out)
end

-- Images ---------------------------------------------------------------------------

local function percentDecode(s: string): string
	return (
		string.gsub(s, "%%(%x%x)", function(h: string): string
			return string.char(tonumber(h, 16) :: number)
		end)
	)
end

-- A data: URL's MIME type and bytes, nil when it is not an image Tern draws.
function M.dataImage(src: string): (string?, string?)
	local head, body = string.match(Str.trim(src), "^[dD][aA][tT][aA]:([^,]*),(.*)$")
	if head == nil or body == nil then
		return nil, nil
	end
	local params = string.split(string.lower(head), ";")
	local mime = Str.trim(params[1] or "")
	if not IMAGE_MIME[mime] then
		return nil, nil
	end
	local bytes: string?
	if table.find(params, "base64") then
		bytes = Base64.decode(percentDecode(body))
	else
		bytes = percentDecode(body)
	end
	if bytes == nil or #bytes == 0 or #bytes > MAX_IMAGE_BYTES then
		return nil, nil
	end
	return mime, bytes
end

-- View -------------------------------------------------------------------------------

type Draw = {
	key: string,
	base: string?,
	assets: Assets.Assets,
	dropped: { string },
	count: number,
}

local function compileStyle(d: Draw): (string) -> string?
	return function(style: string): string?
		local r = HtmlStyle.compile(style)
		for _, what in r.dropped do
			if not table.find(d.dropped, what) then
				table.insert(d.dropped, what)
			end
		end
		return r.class
	end
end

local function imageHook(d: Draw, style: (string) -> string?): (Html.Element, string?) -> Node?
	return function(e: Html.Element, _href: string?): Node?
		local src = e.attrs.src
		if src == nil then
			return nil
		end
		local mime, bytes = M.dataImage(src)
		if mime == nil or bytes == nil then
			return nil
		end
		d.count += 1
		local key = d.key .. ".img" .. d.count
		d.assets[key] = { mime = mime, bytes = bytes }
		local p: { [string]: any } = { key = "i", asset = key, alt = Str.trim(e.attrs.alt or "") }
		local w, h = tonumber(e.attrs.width or ""), tonumber(e.attrs.height or "")
		if w and w > 0 then
			p.w = math.floor(w)
		end
		if h and h > 0 then
			p.h = math.floor(h)
		end
		local img: Node = { k = "image", p = p }
		local classes = { "dt-img" }
		local sc = if e.attrs.style then style(e.attrs.style) else nil
		if sc and sc ~= "" then
			-- A CSS width or height sizes the box; the picture fills it on
			-- that axis (object-fit inside), as an img element does.
			for _, axis in { "w", "h" } do
				if string.find(" " .. sc, " dt%-" .. axis .. "%d") then
					table.insert(classes, "dt-img-" .. axis)
				end
			end
			table.insert(classes, sc)
		end
		return { k = "el", p = { tag = "span", class = table.concat(classes, " ") }, c = { img } }
	end
end

-- One rendered template as nodes.
local function draw(html: string, wrap: boolean, d: Draw, key: string): Node
	local style = compileStyle(d)
	local hopts: Html.Options =
		{ key = key, base_url = d.base, style = style, image = imageHook(d, style), class = "dt-row" }
	if wrap then
		hopts.class = "dt-html"
		local body = Text.markdown(html, "m", d.base, hopts)
		return { k = "el", p = { key = key, tag = "div", class = "dt-row" }, c = { body } }
	end
	return Html.view(M.renderInline(html), hopts)
end

local function errorView(key: string, message: string): Node
	return ui.col({
		ui.text({ ui.span("Couldn't build text from template", "error") }),
		ui.muted(message),
	}, { key = key })
end

function M.view(panel: any, frames: { Frame }, env: Env, opts: Common.Options): (Node, Assets.Assets?)
	local o = Json.obj(env, Json.path(env, panel, "options"))
	local mode = Json.str(env, o.renderMode) or "everyRow"
	local wrap = o.wrap ~= false
	local ctx: Ctx = {
		panel = panel,
		env = env,
		opts = opts,
		display = { theme = opts.theme, offset_min = opts.offset_min, now_ms = env.now_ms },
		status = Json.str(env, o.status),
	}
	if ctx.status == "" then
		ctx.status = nil
	end
	local frameIndex: number? = nil
	if mode == "data" then
		for i, f in frames do
			if #f.fields > 0 then
				frameIndex = i
				break
			end
		end
	elseif frames[1] then
		frameIndex = 1
	end
	local frame = if frameIndex then frames[frameIndex] else nil

	local content: string
	local contexts: { any } = {}
	if frame == nil or rowCount(frame) == 0 then
		content = Json.str(env, o.defaultContent) or ""
		contexts = { {} }
	else
		content = Json.str(env, o.content) or ""
		if mode == "everyRow" then
			contexts = rowsOf(ctx, frames, frameIndex :: number)
		elseif mode == "data" then
			local all: { any } = {}
			for i in frames do
				table.insert(all, rowsOf(ctx, frames, i))
			end
			contexts = { Handlebars.object({ data = all }, { "data" }) }
		else
			contexts = { Handlebars.object({ data = rowsOf(ctx, frames, frameIndex :: number) }, { "data" }) }
		end
	end

	local ok, tpl = pcall(Handlebars.compile, content)
	if not ok then
		return errorView(opts.key, tostring(tpl)), nil
	end
	local extra = helpers(ctx, frames, if mode == "data" then nil else frameIndex)
	local d: Draw = { key = opts.key, base = opts.base_url, assets = {}, dropped = {}, count = 0 }
	local rows: { Node } = {}
	for i, data in contexts do
		local rok, html = pcall(Handlebars.render, tpl :: Handlebars.Template, data, extra)
		if not rok then
			return errorView(opts.key, tostring(html)), nil
		end
		table.insert(rows, draw(html, wrap, d, "r" .. i))
	end

	-- TextPanel sizes the plugin's root to the panel's content box and
	-- scrolls inside it, so a row is a flex item of a column with a definite
	-- height and a template's `height: 100%` resolves against the row. Tern's
	-- capped card body stands for that box; an expanded panel takes Grafana's
	-- (gridPos height less PanelChrome's border and title header).
	local box = opts.card_height
	if box == nil and opts.size then
		local header = if (Json.str(env, panel.title) or "") ~= "" then PANEL_HEADER_PX else 0
		box = opts.size.h - 2 * PANEL_BORDER_PX - header
	end
	local css = if box then string.format("height:%dpx;overflow:auto", math.max(0, math.floor(box))) else ""
	local styles = Json.str(env, o.styles)
	if styles and Str.trim(styles) ~= "" then
		local own = if opts.interpolate then opts.interpolate(styles) else styles
		if string.find(own, "{", 1, true) then
			table.insert(d.dropped, "panel styles with selectors")
		else
			css ..= ";" .. own
		end
	end
	local rootClass = { "tgd dt-root" }
	local c = if css ~= "" then compileStyle(d)(css) else nil
	if c and c ~= "" then
		table.insert(rootClass, c)
	end
	local kids: { Node } = rows
	if #d.dropped > 0 then
		table.sort(d.dropped)
		table.insert(kids, ui.muted("Not drawn natively: " .. table.concat(d.dropped, ", "), { key = "dropped" }))
	end
	return { k = "el", p = { key = opts.key, tag = "div", class = table.concat(rootClass, " ") }, c = kids }, d.assets
end

return M
