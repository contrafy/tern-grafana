--!strict
-- HTML as Grafana's text panel shows it (packages/grafana-data/src/text:
-- sanitize.ts sanitizeTextPanelContent, markdown.ts renderTextPanelMarkdown),
-- drawn with Tern `el` nodes. The sanitizer is js-xss with its default allow
-- list plus iframe and button: an allowed tag keeps a few attributes, a
-- disallowed one (script, style, form, input, custom tags) is escaped and
-- shows as literal text with its content, comments are removed, and href/src
-- keep only http(s), mailto, tel, ftp, data:image and rooted paths (xss
-- safeAttrValue). The browser then builds the tree: void tags, a self-closing
-- slash ignored on other tags, implied ends of p, li, dt/dd and table parts.
--
-- Tern has no a, img, br or iframe element: links are elements with `href`
-- (rooted paths resolved against the Grafana's browser URL), an image is a
-- Markdown image in an `md` node (Tern loads http(s) and data sources and
-- shows the alt text when it cannot), br a preformatted newline, and
-- iframe/video/audio a link to their source. Inline styles become classes for
-- bold, italic and alignment only (colors and boxes follow the Tern theme),
-- unless Options.style compiles them (lib/panels/html_style, dynamictext).

local Str = require("../str")
local ui = require("../ui")

type Node = ui.Node

export type Element = { tag: string, attrs: { [string]: string }, children: { Element | string } }

export type Tag = {
	name: string,
	close: boolean,
	attrs: { [string]: string },
	-- Index of the closing `>`.
	last: number,
}

export type Options = {
	key: string?,
	-- The Grafana's browser URL without a trailing slash, for rooted paths.
	base_url: string?,
	-- An element's inline `style` as classes; replaces the bold, italic and
	-- alignment classes.
	style: ((style: string) -> string?)?,
	-- Draws an img (nil: the default Markdown image); `href` is the link
	-- around it.
	image: ((e: Element, href: string?) -> Node?)?,
	-- The root's class (default "tgx").
	class: string?,
}

local M = {}

local function set(list: { string }): { [string]: boolean }
	local s = {}
	for _, v in list do
		s[v] = true
	end
	return s
end

-- js-xss getDefaultWhiteList plus Grafana's iframe and button.
M.ALLOWED = set({
	"a",
	"abbr",
	"address",
	"area",
	"article",
	"aside",
	"audio",
	"b",
	"bdi",
	"bdo",
	"big",
	"blockquote",
	"br",
	"button",
	"caption",
	"center",
	"cite",
	"code",
	"col",
	"colgroup",
	"dd",
	"del",
	"details",
	"div",
	"dl",
	"dt",
	"em",
	"figcaption",
	"figure",
	"font",
	"footer",
	"h1",
	"h2",
	"h3",
	"h4",
	"h5",
	"h6",
	"header",
	"hr",
	"i",
	"iframe",
	"img",
	"ins",
	"kbd",
	"li",
	"mark",
	"nav",
	"ol",
	"p",
	"pre",
	"s",
	"section",
	"small",
	"span",
	"strike",
	"strong",
	"sub",
	"summary",
	"sup",
	"table",
	"tbody",
	"td",
	"tfoot",
	"th",
	"thead",
	"tr",
	"tt",
	"u",
	"ul",
	"video",
})

local VOID = set({ "area", "br", "col", "hr", "img", "wbr" })

-- Allowed tags that lay out as blocks.
M.BLOCK = set({
	"address",
	"article",
	"aside",
	"blockquote",
	"caption",
	"center",
	"colgroup",
	"dd",
	"details",
	"div",
	"dl",
	"dt",
	"figcaption",
	"figure",
	"footer",
	"h1",
	"h2",
	"h3",
	"h4",
	"h5",
	"h6",
	"header",
	"hr",
	"li",
	"nav",
	"ol",
	"p",
	"pre",
	"section",
	"summary",
	"table",
	"tbody",
	"td",
	"tfoot",
	"th",
	"thead",
	"tr",
	"ul",
})

-- Containers whose whitespace-only text never draws.
local STRUCTURAL = set({ "table", "thead", "tbody", "tfoot", "tr", "colgroup", "ul", "ol", "dl" })

-- Tern `el` tag per allowed tag; the rest draw as span.
local EL_TAG: { [string]: string } = {
	address = "div",
	article = "article",
	aside = "aside",
	b = "b",
	blockquote = "blockquote",
	button = "button",
	caption = "div",
	center = "div",
	code = "code",
	dd = "dd",
	del = "del",
	details = "div",
	div = "div",
	dl = "dl",
	dt = "dt",
	em = "em",
	figcaption = "div",
	figure = "figure",
	footer = "footer",
	h1 = "h1",
	h2 = "h2",
	h3 = "h3",
	h4 = "h4",
	h5 = "h4",
	h6 = "h4",
	header = "header",
	hr = "hr",
	i = "i",
	kbd = "kbd",
	li = "li",
	mark = "mark",
	nav = "nav",
	ol = "ol",
	p = "p",
	pre = "pre",
	s = "del",
	section = "section",
	strike = "del",
	strong = "strong",
	summary = "div",
	table = "table",
	tbody = "tbody",
	td = "td",
	tfoot = "tbody",
	th = "th",
	thead = "thead",
	tr = "tr",
	tt = "code",
	ul = "ul",
}

local ENTITIES: { [string]: string } = {
	amp = "&",
	lt = "<",
	gt = ">",
	quot = '"',
	apos = "'",
	nbsp = " ",
	copy = "©",
	reg = "®",
	trade = "™",
	hellip = "…",
	mdash = "—",
	ndash = "–",
	bull = "•",
	middot = "·",
	times = "×",
	deg = "°",
	larr = "←",
	rarr = "→",
	uarr = "↑",
	darr = "↓",
	laquo = "«",
	raquo = "»",
	lsquo = "‘",
	rsquo = "’",
	ldquo = "“",
	rdquo = "”",
	euro = "€",
}

function M.decodeEntities(s: string): string
	if string.find(s, "&", 1, true) == nil then
		return s
	end
	return (
		string.gsub(s, "&(#?[%w]+);", function(name: string): string
			local known = ENTITIES[name]
			if known then
				return known
			end
			local hex = string.match(name, "^#[xX](%x+)$")
			local dec = string.match(name, "^#(%d+)$")
			local code = if hex then tonumber(hex, 16) elseif dec then tonumber(dec) else nil
			if code and code > 0 and code < 0x110000 then
				return utf8.char(code)
			end
			return "&" .. name .. ";"
		end)
	)
end

local function skipSpace(s: string, j: number): number
	return (string.find(s, "[^%s]", j) or #s + 1)
end

-- The tag whose `<` is at s[i], or nil when that `<` is text. Attribute
-- names are lowercased and values entity-decoded; a closing tag has none.
function M.tagAt(s: string, i: number): Tag?
	local close = string.sub(s, i + 1, i + 1) == "/"
	local j = if close then i + 2 else i + 1
	local name = string.match(s, "^[%a][%w%-]*", j)
	if name == nil then
		return nil
	end
	j += #name
	if string.match(string.sub(s, j, j), "^[%s/>]$") == nil then
		return nil
	end
	local attrs: { [string]: string } = {}
	while true do
		j = skipSpace(s, j)
		local c = string.sub(s, j, j)
		if c == "" then
			return nil
		elseif c == ">" then
			return { name = string.lower(name), close = close, attrs = attrs, last = j }
		elseif c == "/" then
			j += 1
		else
			local an = string.match(s, "^[^%s/>=\"'<]+", j)
			if an == nil then
				return nil
			end
			j = skipSpace(s, j + #an)
			local value = ""
			if string.sub(s, j, j) == "=" then
				j = skipSpace(s, j + 1)
				local q = string.sub(s, j, j)
				if q == '"' or q == "'" then
					local e = string.find(s, q, j + 1, true)
					if e == nil then
						return nil
					end
					value = string.sub(s, j + 1, e - 1)
					j = e + 1
				else
					value = string.match(s, "^[^%s>]*", j) or ""
					j += #value
				end
			end
			local key = string.lower(an)
			if not close and attrs[key] == nil then
				attrs[key] = M.decodeEntities(value)
			end
		end
	end
end

-- A sanitized href or src as a URL Tern can open, or nil (dropped by xss, or
-- relative to a page Tern does not have).
function M.resolve(value: string?, base: string?, image: boolean?): string?
	if value == nil then
		return nil
	end
	local v = Str.trim(value)
	local lower = string.lower(v)
	if
		string.match(lower, "^https?://")
		or string.match(lower, "^mailto:")
		or string.match(lower, "^tel:")
		or string.match(lower, "^ftp://")
	then
		return v
	elseif string.match(lower, "^data:image/") then
		return if image then v else nil
	elseif string.sub(v, 1, 2) == "//" then
		local scheme = if base then string.match(base, "^(%a[%w+.-]*:)") else nil
		return (scheme or "https:") .. v
	elseif string.sub(v, 1, 1) == "/" and base then
		return base .. v
	end
	return nil
end

-- Parses sanitized HTML into a tree under a root with tag "".
function M.parse(src: string): Element
	local root: Element = { tag = "", attrs = {}, children = {} }
	local stack: { Element } = { root }

	local function addText(t: string)
		if t == "" then
			return
		end
		local kids = stack[#stack].children
		local last = kids[#kids]
		if type(last) == "string" then
			kids[#kids] = last .. t
		else
			table.insert(kids, t)
		end
	end

	-- Pops through the nearest open element named in `names`, not past one
	-- named in `stop` (nor past a block when `inline` is set).
	local function closeOpen(names: { [string]: boolean }, stop: { [string]: boolean }?, inline: boolean?): boolean
		for k = #stack, 2, -1 do
			local tag = stack[k].tag
			if names[tag] then
				for _ = #stack, k, -1 do
					table.remove(stack)
				end
				return true
			end
			if (stop and stop[tag]) or (inline and M.BLOCK[tag]) then
				return false
			end
		end
		return false
	end

	local P = set({ "p" })
	local LI, LISTS = set({ "li" }), set({ "ul", "ol" })
	local DTDD, DL = set({ "dt", "dd" }), set({ "dl" })
	local CELL, ROW, SECTION, TABLE =
		set({ "td", "th" }), set({ "tr" }), set({ "thead", "tbody", "tfoot" }), set({ "table" })
	local ROW_STOP = set({ "table", "thead", "tbody", "tfoot" })

	local function open(tag: Tag)
		local name = tag.name
		if M.BLOCK[name] then
			closeOpen(P, nil, true)
		end
		if name == "li" then
			closeOpen(LI, LISTS)
		elseif name == "dt" or name == "dd" then
			closeOpen(DTDD, DL)
		elseif name == "tr" then
			closeOpen(ROW, ROW_STOP)
		elseif name == "td" or name == "th" then
			closeOpen(CELL, ROW)
		elseif SECTION[name] then
			closeOpen(SECTION, TABLE)
		end
		local e: Element = { tag = name, attrs = tag.attrs, children = {} }
		table.insert(stack[#stack].children, e)
		if not VOID[name] then
			table.insert(stack, e)
		end
	end

	local i, n = 1, #src
	while i <= n do
		local lt = string.find(src, "<", i, true)
		if lt == nil then
			addText(M.decodeEntities(string.sub(src, i)))
			break
		end
		if lt > i then
			addText(M.decodeEntities(string.sub(src, i, lt - 1)))
		end
		if string.sub(src, lt, lt + 3) == "<!--" then
			local e = string.find(src, "-->", lt + 4, true)
			i = if e then e + 3 else n + 1
			continue
		end
		local tag = M.tagAt(src, lt)
		if tag == nil then
			addText("<")
			i = lt + 1
		elseif not M.ALLOWED[tag.name] then
			addText(M.decodeEntities(string.sub(src, lt, tag.last)))
			i = tag.last + 1
		else
			i = tag.last + 1
			if not tag.close then
				open(tag)
			elseif tag.name == "br" then
				open({ name = "br", close = false, attrs = {}, last = tag.last })
			elseif not VOID[tag.name] then
				for k = #stack, 2, -1 do
					if stack[k].tag == tag.name then
						for _ = #stack, k, -1 do
							table.remove(stack)
						end
						break
					end
				end
			end
		end
	end
	return root
end

-- Element text with tags dropped and whitespace collapsed (code spans).
function M.textOf(e: Element | string): string
	if type(e) == "string" then
		return e
	end
	local parts: { string } = {}
	for _, c in e.children do
		table.insert(parts, M.textOf(c))
	end
	return table.concat(parts)
end

-- A URL as a Markdown link destination.
function M.mdUrl(u: string): string
	if string.find(u, "[%s()<>]") then
		return "<" .. string.gsub(string.gsub(u, "<", "%%3C"), ">", "%%3E") .. ">"
	end
	return u
end

function M.mdEscape(t: string): string
	return (string.gsub(t, "([%[%]\\])", "\\%1"))
end

-- `![alt](src)`, inside a link to `href` when given.
function M.mdImage(alt: string, src: string, href: string?): string
	local img = "![" .. M.mdEscape(alt) .. "](" .. M.mdUrl(src) .. ")"
	return if href then "[" .. img .. "](" .. M.mdUrl(href) .. ")" else img
end

type Ctx = { base: string?, href: string?, pre: boolean, opts: Options }

local function styleClasses(e: Element, classes: { string }, compile: ((string) -> string?)?)
	if compile then
		local align = string.lower(e.attrs.align or "")
		if align == "center" or e.tag == "center" then
			table.insert(classes, "tgx-center")
		elseif align == "right" then
			table.insert(classes, "tgx-right")
		end
		local style = e.attrs.style
		local c = if style and style ~= "" then compile(style) else nil
		if c and c ~= "" then
			table.insert(classes, c)
		end
		return
	end
	local style = string.lower(e.attrs.style or "")
	local align = string.lower(e.attrs.align or "")
	local weight = string.match(style, "font%-weight%s*:%s*([%w]+)")
	if weight == "bold" or weight == "bolder" or (tonumber(weight) or 0) >= 600 then
		table.insert(classes, "tgx-b")
	end
	if string.match(style, "font%-style%s*:%s*italic") then
		table.insert(classes, "tgx-i")
	end
	local ta = string.match(style, "text%-align%s*:%s*(%a+)") or align
	if ta == "center" or e.tag == "center" then
		table.insert(classes, "tgx-center")
	elseif ta == "right" then
		table.insert(classes, "tgx-right")
	end
end

local function hasBlock(e: Element): boolean
	for _, c in e.children do
		if type(c) ~= "string" and (M.BLOCK[c.tag] or hasBlock(c)) then
			return true
		end
	end
	return false
end

local build: (e: Element, ctx: Ctx) -> Node?

local function isBlockChild(c: (Element | string)?): boolean
	return c ~= nil and type(c) ~= "string" and M.BLOCK[c.tag] == true
end

-- The element's drawn children and its leading text (the `el` text prop).
local function children(e: Element, ctx: Ctx): ({ Node }, string?)
	local out: { Node } = {}
	local lead: string? = nil
	local kids = e.children
	for idx, c in kids do
		if type(c) == "string" then
			local t = if ctx.pre then c else string.gsub(c, "%s+", " ")
			local blank = not ctx.pre and t == " "
			if
				blank
				and (
					STRUCTURAL[e.tag]
					or idx == 1
					or idx == #kids
					or isBlockChild(kids[idx - 1])
					or isBlockChild(kids[idx + 1])
				)
			then
				continue
			end
			if idx == 1 then
				lead = if e.tag == "pre" then string.gsub(t, "^\r?\n", "") else t
			else
				table.insert(out, { k = "el", p = { tag = "span", text = t, href = ctx.href } })
			end
		else
			local node = build(c, ctx)
			if node then
				table.insert(out, node)
			end
		end
	end
	return out, lead
end

build = function(e: Element, ctx: Ctx): Node?
	local name = e.tag
	if name == "col" or name == "colgroup" or name == "area" then
		return nil
	elseif name == "br" then
		return { k = "el", p = { tag = "span", class = "tgx-br", text = "\n" } }
	elseif name == "img" then
		local custom = ctx.opts.image
		local node = if custom then custom(e, ctx.href) else nil
		if node then
			return node
		end
		local alt = Str.trim(e.attrs.alt or "")
		local src = M.resolve(e.attrs.src, ctx.base, true)
		if src then
			return { k = "md", p = { text = M.mdImage(alt, src, ctx.href) } }
		elseif alt ~= "" then
			return { k = "el", p = { tag = "span", class = "tgx-alt", text = alt, href = ctx.href } }
		end
		return nil
	elseif name == "iframe" or name == "video" or name == "audio" then
		local src = M.resolve(e.attrs.src, ctx.base)
		if src == nil then
			return nil
		end
		return { k = "el", p = { tag = "span", class = "tgx-a", text = src, href = src } }
	end
	local href = ctx.href
	local tag = EL_TAG[name] or "span"
	local classes: { string } = {}
	if name == "a" then
		local h = M.resolve(e.attrs.href, ctx.base)
		if h then
			href = h
			table.insert(classes, "tgx-a")
		end
		if hasBlock(e) then
			tag = "div"
		end
	elseif name == "u" or name == "ins" then
		table.insert(classes, "tgx-u")
	elseif ctx.opts.style and string.match(name, "^h[1-6]$") then
		-- Grafana's heading variant (dynamictext.css dt-hd<n>); h5 and h6
		-- draw as Tern h4 elements.
		table.insert(classes, "dt-hd" .. string.sub(name, 2))
	end
	styleClasses(e, classes, ctx.opts.style)
	local pre = ctx.pre or name == "pre"
	local inner = if href ~= ctx.href or pre ~= ctx.pre
		then { base = ctx.base, href = href, pre = pre, opts = ctx.opts }
		else ctx
	local kids, lead = children(e, inner)
	local p: { [string]: any } = { tag = tag, text = lead, href = href }
	if #classes > 0 then
		p.class = table.concat(classes, " ")
	end
	if e.attrs.title and e.attrs.title ~= "" then
		p.title = e.attrs.title
	end
	if name == "td" or name == "th" then
		local cs, rs = tonumber(e.attrs.colspan or ""), tonumber(e.attrs.rowspan or "")
		if cs or rs then
			p.attrs = { colspan = cs, rowspan = rs }
		end
	end
	return { k = "el", p = p, c = if #kids > 0 then kids else nil }
end

-- Sanitized HTML as one `el` div of class opts.class (default tgx).
function M.view(src: string, opts: Options): Node
	local root = M.parse(src)
	local kids, lead = children(root, { base = opts.base_url, pre = false, opts = opts })
	local p: { [string]: any } = { tag = "div", class = opts.class or "tgx", text = lead }
	if opts.key then
		p.key = opts.key
	end
	return { k = "el", p = p, c = kids }
end

return M
