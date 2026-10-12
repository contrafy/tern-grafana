--!strict
-- The news panel (public/app/plugins/panel/news at v12.4.0: NewsPanel.tsx,
-- feed.ts loadFeed/isAtomFeed/getProperty, rss.ts, atom.ts, utils.ts
-- feedToDataFrame, component/News.tsx, constants.ts, panelcfg.cue).
--
-- The feed is fetched by the plugin: an absolute http(s) feedUrl as an
-- external GET (no credentials), a path ("/public/...") from the
-- dashboard's Grafana, where the browser would resolve it. The XML is read
-- by a small non-validating parser (elements, attributes, text, CDATA,
-- comments; no DTDs or external entities) bounded in size and items. Atom
-- when a <feed> element exists, else RSS 2.0, item fields as Grafana takes
-- them: the first descendant <title>, <link> (Atom: its href), <description>
-- / <content> and <pubDate> / <published> / <updated>. Content is reduced
-- to text (feedToDataFrame strips tags). Each item shows "MMM DD", its
-- title (opening the link in Tern's browser pane) and its content.
--
-- showImage draws no image: Grafana's image is an item's og:image <meta>
-- loaded by the browser, and a panel view has no image fetch; items are
-- text only, as with showImage off.

local Assets = require("../render/assets")
local Clock = require("./clock")
local Common = require("./common")
local Env = require("../env")
local Frame = require("../frame/types")
local Json = require("./json")
local Range = require("../time/range")
local Scheme = require("../links/scheme")
local Text = require("./text")
local TransportTypes = require("../transport/types")
local ui = require("../ui")

type Env = Env.Env
type Node = ui.Node

local M = {}

M.types = { "news" }

M.DEFAULT_FEED_URL = "https://grafana.com/blog/news.xml"
-- Bounds on what one feed may cost the host.
M.MAX_BYTES = 2 * 1024 * 1024
M.MAX_ITEMS = 100
M.MAX_DEPTH = 64

local TAG = "feed"

export type Item = {
	title: string,
	link: string,
	content: string,
	-- Epoch ms, nil when the date does not parse ("Invalid date").
	date_ms: number?,
}

local function feedUrl(panel: any, env: Env): string
	local u = Json.str(env, Json.path(env, panel, "options", "feedUrl"))
	-- NewsPanel: empty or missing is Grafana's blog.
	if u == nil or u == "" then
		return M.DEFAULT_FEED_URL
	end
	return u
end

-- Where the feed is read: (signal, path, query) or nil and why.
function M.target(url: string): (Common.Signal?, string?, { { string } }?, string?)
	local trimmed = string.match(url, "^%s*(.-)%s*$") or ""
	local lower = string.lower(trimmed)
	if string.sub(lower, 1, 7) == "http://" or string.sub(lower, 1, 8) == "https://" then
		if string.find(trimmed, "[%s%c]") then
			return nil, nil, nil, "the feed URL has spaces or control characters"
		end
		return "external", trimmed, nil, nil
	end
	if string.sub(trimmed, 1, 1) == "/" and string.sub(trimmed, 2, 2) ~= "/" then
		local path, query = string.match(trimmed, "^([^?#]*)%??([^#]*)")
		local q: { { string } } = {}
		for part in string.gmatch(query or "", "[^&]+") do
			local k, v = string.match(part, "^([^=]*)=?(.*)$")
			local dk = Scheme.percentDecode(k or "", true)
			local dv = Scheme.percentDecode(v or "", true)
			if dk == nil or dv == nil then
				return nil, nil, nil, "the feed URL has a malformed query"
			end
			table.insert(q, { dk :: string, dv :: string })
		end
		return "dashboards", path, if #q > 0 then q else nil, nil
	end
	return nil, nil, nil, string.format("feed URL %s is neither absolute nor a path on Grafana", trimmed)
end

function M.supports(panel: any, env: Env): (boolean, string?)
	local signal, _, _, why = M.target(feedUrl(panel, env))
	return signal ~= nil, why
end

function M.queries(_: any): boolean
	return false
end

function M.requests(panel: any, _ctx: Common.RequestContext, env: Env): { Common.PanelRequest }
	local signal, path, query = M.target(feedUrl(panel, env))
	if signal == nil then
		return {}
	end
	local headers = { Accept = "application/rss+xml, application/atom+xml, application/xml, text/xml, */*" }
	return {
		{
			tag = TAG,
			signal = signal :: Common.Signal,
			request = { method = "GET", path = path :: string, query = query, headers = headers },
		},
	}
end

-- XML -------------------------------------------------------------------------------------

export type XmlNode = {
	-- Local name (prefix dropped), as CSS type selectors match in XML.
	name: string,
	attrs: { [string]: string },
	children: { XmlNode | string },
}

local XML_ENTITIES: { [string]: string } = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }

local function decodeEntities(s: string): string
	return (
		string.gsub(s, "&(#?[%w]+);", function(name: string): string
			local known = XML_ENTITIES[name]
			if known then
				return known
			end
			local hex = string.match(name, "^#[xX](%x+)$")
			local dec = string.match(name, "^#(%d+)$")
			local code = if hex then tonumber(hex, 16) elseif dec then tonumber(dec) else nil
			if code and code > 0 and code < 0x110000 and not (code >= 0xD800 and code <= 0xDFFF) then
				return utf8.char(code)
			end
			return "&" .. name .. ";"
		end)
	)
end

local function localName(qname: string): string
	return string.match(qname, ":([^:]+)$") or qname
end

-- A forgiving parse into a tree: unknown constructs are skipped, unclosed
-- elements close at the end, a stray end tag closes up to its match.
function M.parseXml(text: string): (XmlNode?, string?)
	if #text > M.MAX_BYTES then
		return nil, string.format("the feed is larger than %d KiB", M.MAX_BYTES // 1024)
	end
	local root: XmlNode = { name = "#document", attrs = {}, children = {} }
	local stack: { XmlNode } = { root }
	local i = 1
	local n = #text
	while i <= n do
		local lt = string.find(text, "<", i, true)
		if lt == nil then
			table.insert(stack[#stack].children, decodeEntities(string.sub(text, i)))
			break
		end
		if lt > i then
			table.insert(stack[#stack].children, decodeEntities(string.sub(text, i, lt - 1)))
		end
		if string.sub(text, lt, lt + 3) == "<!--" then
			local e = string.find(text, "-->", lt + 4, true)
			i = if e then e + 3 else n + 1
		elseif string.sub(text, lt, lt + 8) == "<![CDATA[" then
			local e = string.find(text, "]]>", lt + 9, true)
			table.insert(stack[#stack].children, string.sub(text, lt + 9, if e then e - 1 else n))
			i = if e then e + 3 else n + 1
		elseif string.sub(text, lt, lt + 1) == "<?" then
			local e = string.find(text, "?>", lt + 2, true)
			i = if e then e + 2 else n + 1
		elseif string.sub(text, lt, lt + 1) == "<!" then
			-- DOCTYPE and declarations: skipped, internal subsets included.
			local depth, j = 0, lt + 2
			while j <= n do
				local c = string.sub(text, j, j)
				if c == "[" then
					depth += 1
				elseif c == "]" then
					depth -= 1
				elseif c == ">" and depth <= 0 then
					break
				end
				j += 1
			end
			i = j + 1
		elseif string.sub(text, lt, lt + 1) == "</" then
			local name, e = string.match(text, "^</%s*([^%s>]+)%s*>()", lt)
			if name == nil then
				i = lt + 2
			else
				local ln = localName(name :: string)
				for k = #stack, 2, -1 do
					if stack[k].name == ln then
						for _ = #stack, k, -1 do
							table.remove(stack)
						end
						break
					end
				end
				i = e :: number
			end
		else
			local name, body, e = string.match(text, "^<([%a_:][%w_:%.%-]*)(.-)>()", lt)
			if name == nil then
				table.insert(stack[#stack].children, "<")
				i = lt + 1
			else
				local b = body :: string
				local selfClosing = string.sub(b, -1) == "/"
				if selfClosing then
					b = string.sub(b, 1, -2)
				end
				local attrs: { [string]: string } = {}
				for k, _, v in string.gmatch(b, "([%a_:][%w_:%.%-]*)%s*=%s*([\"'])(.-)%2") do
					attrs[localName(k :: string)] = decodeEntities(v :: string)
				end
				local node: XmlNode = { name = localName(name :: string), attrs = attrs, children = {} }
				table.insert(stack[#stack].children, node)
				if not selfClosing then
					if #stack > M.MAX_DEPTH then
						return nil, "the feed nests too deeply"
					end
					table.insert(stack, node)
				end
				i = e :: number
			end
		end
	end
	return root, nil
end

-- Elements named `name` under `node`, in document order (querySelectorAll).
local function all(node: XmlNode, name: string, out: { XmlNode }, max: number): { XmlNode }
	for _, c in node.children do
		if #out >= max then
			break
		end
		if type(c) == "table" then
			if c.name == name then
				table.insert(out, c)
			end
			all(c, name, out, max)
		end
	end
	return out
end

local function first(node: XmlNode, name: string): XmlNode?
	return all(node, name, {}, 1)[1]
end

local function textContent(node: XmlNode): string
	local parts: { string } = {}
	local function walk(x: XmlNode)
		for _, c in x.children do
			if type(c) == "string" then
				table.insert(parts, c)
			else
				walk(c)
			end
		end
	end
	walk(node)
	return table.concat(parts)
end

-- getProperty.
local function property(node: XmlNode, name: string): string
	local p = first(node, name)
	return if p then textContent(p) else ""
end

-- Dates -----------------------------------------------------------------------------------

local MONTHS: { [string]: number } = {
	jan = 1,
	feb = 2,
	mar = 3,
	apr = 4,
	may = 5,
	jun = 6,
	jul = 7,
	aug = 8,
	sep = 9,
	oct = 10,
	nov = 11,
	dec = 12,
}

-- RFC 822 zone names moment's RFC 2822 parser knows (minutes east).
local ZONES: { [string]: number } = {
	ut = 0,
	gmt = 0,
	z = 0,
	edt = -240,
	est = -300,
	cdt = -300,
	cst = -360,
	mdt = -360,
	mst = -420,
	pdt = -420,
	pst = -480,
}

local function daysFromCivil(y: number, m: number, d: number): number
	y = if m <= 2 then y - 1 else y
	local era = y // 400
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

-- RSS pubDate (RFC 822/2822, "Tue, 07 Jul 2026 09:30:00 GMT") or an Atom
-- RFC 3339 date, as moment reads them; nil is moment's invalid date.
function M.parseDate(s: string): number?
	local t = string.match(s, "^%s*(.-)%s*$") or ""
	if t == "" then
		return nil
	end
	local body = string.gsub(t, "^%a+,%s*", "")
	local d, mon, y, h, mi, rest = string.match(body, "^(%d%d?)%s+(%a+)%s+(%d+)%s+(%d%d?):(%d%d)(.*)$")
	if d and mon and y and h and mi then
		local month = MONTHS[string.lower(string.sub(mon :: string, 1, 3))]
		if month == nil then
			return nil
		end
		local year = tonumber(y) :: number
		if year < 100 then
			year += if year < 50 then 2000 else 1900
		end
		local sec = 0
		local tail = rest :: string
		local ss, after = string.match(tail, "^:(%d%d)(.*)$")
		if ss then
			sec = tonumber(ss) :: number
			tail = after :: string
		end
		local zone = string.lower(string.match(tail, "^%s*(%S*)") or "")
		local offset: number? = 0
		if zone ~= "" then
			local sign, zh, zm = string.match(zone, "^([+-])(%d%d)(%d%d)$")
			if sign then
				offset = ((tonumber(zh) :: number) * 60 + (tonumber(zm) :: number)) * (if sign == "-" then -1 else 1)
			else
				offset = ZONES[zone]
			end
		end
		if offset == nil then
			return nil
		end
		local days = daysFromCivil(year, month, tonumber(d) :: number)
		return ((days * 24 + (tonumber(h) :: number)) * 60 + (tonumber(mi) :: number) - (offset :: number)) * 60000
			+ sec * 1000
	end
	if string.match(t, "^%d%d%d%d%-%d%d") then
		local ms = Range.parse(t, false, { now_ms = 0 })
		return ms
	end
	return nil
end

-- Feed ------------------------------------------------------------------------------------

function M.parseFeed(text: string): ({ Item }?, string?)
	local doc, err = M.parseXml(text)
	if doc == nil then
		return nil, err
	end
	local atom = first(doc :: XmlNode, "feed") ~= nil
	local nodes = all(doc :: XmlNode, if atom then "entry" else "item", {}, M.MAX_ITEMS)
	local items: { Item } = {}
	for _, node in nodes do
		local link: string
		local content: string
		local date: string
		if atom then
			local l = first(node, "link")
			link = if l then l.attrs.href or "" else ""
			content = property(node, "content")
			date = property(node, "published")
			if date == "" then
				date = property(node, "updated")
			end
		else
			link = property(node, "link")
			content = property(node, "description")
			date = property(node, "pubDate")
		end
		table.insert(items, {
			title = property(node, "title"),
			link = string.match(link, "^%s*(.-)%s*$") or "",
			-- feedToDataFrame strips tags; News renders the rest as HTML.
			content = Text.htmlToText(content),
			date_ms = M.parseDate(date),
		})
	end
	return items, nil
end

function M.parse(_: any, _tag: string, response: TransportTypes.Response, _env: Env): any
	if response.failure then
		return { error = response.failure.message }
	end
	if response.error and response.error ~= "" then
		return { error = response.error }
	end
	if response.timed_out then
		return { error = "the feed request timed out" }
	end
	if response.status < 200 or response.status >= 300 then
		return { error = string.format("the feed answered HTTP %d", response.status) }
	end
	local items, err = M.parseFeed(response.body)
	if items == nil then
		return { error = err }
	end
	return { items = items }
end

-- View ------------------------------------------------------------------------------------

-- textUtil.sanitizeUrl keeps http(s) links; the title opens them in the
-- browser pane (a Grafana URL too, as the news panel's target=_blank does).
function M.link(url: string): string?
	if not string.match(string.lower(url), "^https?://") then
		return nil
	end
	local ok, link = pcall(Scheme.encode, { action = "browse", params = { url = url }, vars = {} })
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

function M.view(_: any, _frames: { Frame.Frame }, env: Env, opts: Common.Options): (Node, Assets.Assets?)
	local answer = if opts.extra then (opts.extra :: { [string]: any })[TAG] else nil
	if answer == nil then
		return ui.muted("Loading...", { key = opts.key }), nil
	end
	if answer.error then
		return el("tgl-list", opts.key, {
			ui.text({ ui.span("Error loading RSS feed", "error strong") }, { key = "t" }),
			ui.muted(tostring(answer.error), { key = "e" }),
		}),
			nil
	end
	-- dateTimeFormat: the viewer's timezone.
	local localMin = opts.local_offset_min or env.local_offset_min or 0
	local zone = Clock.zone("", localMin, nil, nil)
	local children: { Node } = {}
	for i, item in answer.items :: { Item } do
		local date = if item.date_ms
			then Clock.format("MMM DD", item.date_ms :: number, (Clock.zoneAt(zone, item.date_ms :: number)), "")
			else "Invalid date"
		local link = M.link(item.link)
		local body: { Node } = {
			ui.text({ ui.span(date, "muted") }, { key = "d" }),
			el("tgl-news-title", "tw", { ui.text({ { t = item.title, s = "accent", href = link } }, { key = "t" }) }),
		}
		if item.content ~= "" then
			table.insert(body, ui.text({ ui.span(item.content) }, { key = "c" }))
		end
		table.insert(children, el("tgl-news", "n" .. i, body))
	end
	return el("tgl-list", opts.key, children, { role = "tern-grafana.news" }), nil
end

return M
