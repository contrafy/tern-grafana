--!strict
-- The text panel (public/app/plugins/panel/text: panelcfg.cue, TextPanel.tsx).
-- Content is interpolated with dashboard variables first, as TextPanel does.
-- options.mode html is sanitized HTML (lib/panels/html); code shows
-- options.code.language in a `code` node; markdown renders through Tern's
-- `md` node, which keeps raw HTML literal, so the HTML Grafana renders in
-- Markdown (marked, then the same sanitizer) is handled here first:
-- - HTML blocks (CommonMark 4.6, as marked splits them: a line opening with
--   script/pre/style/textarea, a comment, or a block tag runs to its end
--   marker or a blank line; a lone complete tag that does not interrupt a
--   paragraph runs to a blank line) draw as HTML between `md` nodes;
-- - inline tags in Markdown prose become Markdown: links, emphasis, code
--   spans, images, line breaks; other allowed tags keep only their text;
--   disallowed ones are backslash-escaped to show as plain text, as Grafana
--   escapes them.
-- Rooted link and image paths resolve against the Grafana's browser URL.

local Common = require("./common")
local Env = require("../env")
local Html = require("./html")
local Json = require("./json")
local ui = require("../ui")

type Env = Env.Env
type Node = ui.Node

local M = {}

-- HTML as plain text: scripts and styles dropped, block ends and <br> as
-- line breaks, list items bulleted, tags removed, entities decoded,
-- whitespace runs collapsed.
function M.htmlToText(html: string): string
	local s = html
	for _, tag in { "script", "style" } do
		s = string.gsub(s, "<%s*" .. tag .. "[^>]*>.-<%s*/%s*" .. tag .. "%s*>", "")
	end
	s = string.gsub(s, "<!%-%-.-%-%->", "")
	s = string.gsub(s, "[ \t\r\n]+", " ")
	s = string.gsub(s, "<%s*[bB][rR]%s*/?%s*>", "\n")
	s = string.gsub(s, "<%s*[lL][iI][^>]*>", "\n- ")
	s = string.gsub(s, "<%s*/%s*[%a][%w]*%s*>", function(tag: string): string
		local name = string.lower(string.match(tag, "/%s*([%a][%w]*)") or "")
		if
			name == "p"
			or name == "div"
			or name == "ul"
			or name == "ol"
			or name == "tr"
			or name == "table"
			or string.match(name, "^h%d$")
		then
			return "\n"
		end
		return ""
	end)
	s = string.gsub(s, "<[^>]*>", "")
	s = Html.decodeEntities(s)
	s = string.gsub(s, " *\n *", "\n")
	s = string.gsub(s, "\n\n\n+", "\n\n")
	-- List items sit directly under the line before them.
	s = string.gsub(s, "\n+%- ", "\n- ")
	return (string.match(s, "^%s*(.-)%s*$") or "")
end

-- Markdown blocks ------------------------------------------------------------

-- CommonMark's type 6 HTML block tags.
local BLOCK_START: { [string]: boolean } = {}
for _, t in
	{
		"address",
		"article",
		"aside",
		"base",
		"basefont",
		"blockquote",
		"body",
		"caption",
		"center",
		"col",
		"colgroup",
		"dd",
		"details",
		"dialog",
		"dir",
		"div",
		"dl",
		"dt",
		"fieldset",
		"figcaption",
		"figure",
		"footer",
		"form",
		"frame",
		"frameset",
		"h1",
		"h2",
		"h3",
		"h4",
		"h5",
		"h6",
		"head",
		"header",
		"hr",
		"html",
		"iframe",
		"legend",
		"li",
		"link",
		"main",
		"menu",
		"menuitem",
		"nav",
		"noframes",
		"ol",
		"optgroup",
		"option",
		"p",
		"param",
		"search",
		"section",
		"summary",
		"table",
		"tbody",
		"td",
		"tfoot",
		"th",
		"thead",
		"title",
		"tr",
		"track",
		"ul",
	}
do
	BLOCK_START[t] = true
end

local RAW_START = { "script", "pre", "style", "textarea" }

-- Markdown source split into prose, fenced code and HTML blocks.
type Segment = { kind: "md" | "code" | "html", text: string }

local function blank(line: string): boolean
	return string.match(line, "^%s*$") ~= nil
end

-- The end marker kind of an HTML block starting on `line`, or nil.
local function htmlStart(line: string, inParagraph: boolean): string?
	local rest = string.match(line, "^ ? ? ?(<.*)$")
	if rest == nil then
		return nil
	end
	local lower = string.lower(rest)
	for _, t in RAW_START do
		if string.match(lower, "^<" .. t .. "[%s>]") or lower == "<" .. t then
			return "raw"
		end
	end
	if string.sub(lower, 1, 4) == "<!--" then
		return "-->"
	elseif string.sub(lower, 1, 2) == "<?" then
		return "?>"
	elseif string.sub(lower, 1, 9) == "<![cdata[" then
		return "]]>"
	elseif string.match(lower, "^<!%a") then
		return ">"
	end
	local slash, name = string.match(lower, "^<(/?)([%a][%w%-]*)")
	if slash == nil or name == nil then
		return nil
	end
	local after = string.sub(lower, 2 + #slash + #name, 3 + #slash + #name)
	if BLOCK_START[name] and (after == "" or string.match(after, "^[%s>]") or after == "/>") then
		return "blank"
	end
	if inParagraph or table.find(RAW_START, name) then
		return nil
	end
	local tag = Html.tagAt(rest, 1)
	if tag and blank(string.sub(rest, tag.last + 1)) then
		return "blank"
	end
	return nil
end

local function htmlEnds(kind: string, line: string): boolean
	if kind == "raw" then
		local lower = string.lower(line)
		for _, t in RAW_START do
			if string.find(lower, "</" .. t .. ">", 1, true) then
				return true
			end
		end
		return false
	end
	return string.find(line, kind, 1, true) ~= nil
end

local function segments(src: string): { Segment }
	local lines = string.split(src, "\n")
	local out: { Segment } = {}
	local buf: { string } = {}
	local bufKind: "md" | "code" | "html" = "md"
	local function push(kind: "md" | "code" | "html", line: string)
		if #buf > 0 and kind ~= bufKind then
			table.insert(out, { kind = bufKind, text = table.concat(buf, "\n") })
			table.clear(buf)
		end
		bufKind = kind
		table.insert(buf, line)
	end
	local fence: string? = nil
	local para = false
	local i = 1
	while i <= #lines do
		local line = lines[i]
		if fence then
			push("code", line)
			local f = string.match(line, "^ ? ? ?([`~]+)%s*$")
			if f and string.sub(f, 1, 1) == string.sub(fence, 1, 1) and #f >= #fence then
				fence = nil
			end
			i += 1
			continue
		end
		local f = string.match(line, "^ ? ? ?(```+)") or string.match(line, "^ ? ? ?(~~~+)")
		if f then
			fence = f
			para = false
			push("code", line)
			i += 1
			continue
		end
		local kind = htmlStart(line, para)
		if kind == nil then
			push("md", line)
			para = not blank(line)
				and string.match(line, "^ ? ? ?#+%s") == nil
				and string.match(line, "^ ? ? ?#+$") == nil
			i += 1
			continue
		end
		local j = i
		if kind == "blank" then
			while j < #lines and not blank(lines[j + 1]) do
				j += 1
			end
		else
			while j < #lines and not htmlEnds(kind, lines[j]) do
				j += 1
			end
		end
		for k = i, j do
			push("html", lines[k])
		end
		para = false
		i = j + 1
	end
	if #buf > 0 then
		table.insert(out, { kind = bufKind, text = table.concat(buf, "\n") })
	end
	return out
end

-- Inline HTML as Markdown --------------------------------------------------------

local EMPHASIS: { [string]: string } =
	{ b = "**", strong = "**", i = "*", em = "*", del = "~~", s = "~~", strike = "~~" }
local CODE = { code = true, tt = true, kbd = true }

type Open = { name: string, close: string, opened: boolean }

-- Prose with its inline HTML rewritten as Markdown; code spans and escapes
-- stay as written, disallowed tags are escaped to plain text. Rooted link
-- destinations get `base`.
function M.inline(src: string, base: string?): string
	local out: { string } = {}
	local stack: { Open } = {}
	-- Openers waiting for the next non-space text (`<b> x` is `**x**`).
	local pending = ""

	local function emit(t: string)
		if t == "" then
			return
		end
		if pending ~= "" then
			local ws, rest = string.match(t, "^(%s*)(.*)$")
			if rest == "" then
				table.insert(out, t)
				return
			end
			table.insert(out, (ws :: string) .. pending .. (rest :: string))
			pending = ""
			for _, o in stack do
				o.opened = true
			end
			return
		end
		table.insert(out, t)
	end

	-- A closer goes before trailing whitespace (`x </b>` is `**x** `).
	local function emitClose(marker: string)
		local trail: { string } = {}
		while #out > 0 do
			local last = out[#out]
			local body, ws = string.match(last, "^(.-)(%s*)$")
			if body ~= "" then
				out[#out] = (body :: string) .. marker .. (ws :: string) .. table.concat(trail)
				return
			end
			table.insert(trail, 1, last)
			table.remove(out)
		end
		table.insert(out, marker .. table.concat(trail))
	end

	local function close(o: Open)
		if o.close == "" then
			return
		end
		if not o.opened then
			if string.sub(pending, -#o.close) == o.close then
				pending = string.sub(pending, 1, #pending - #o.close)
			end
			return
		end
		emitClose(o.close)
	end

	local function boundary()
		local last = out[#out]
		if last and string.sub(last, -1) ~= "\n" then
			table.insert(out, "\n")
		end
	end

	local function inTableRow(at: number): boolean
		local lineStart = 1
		local k = at - 1
		while k >= 1 do
			if string.sub(src, k, k) == "\n" then
				lineStart = k + 1
				break
			end
			k -= 1
		end
		return string.match(src, "^%s*|", lineStart) ~= nil
	end

	local function tag(t: Html.Tag, at: number): number
		local name = t.name
		if t.close then
			for k = #stack, 1, -1 do
				if stack[k].name == name then
					for _ = #stack, k, -1 do
						close(table.remove(stack) :: Open)
					end
					break
				end
			end
			if Html.BLOCK[name] and name ~= "td" and name ~= "th" then
				boundary()
			end
			return t.last + 1
		end
		local marker = EMPHASIS[name]
		if marker then
			pending ..= marker
			table.insert(stack, { name = name, close = marker, opened = false })
		elseif name == "a" then
			local href = Html.resolve(t.attrs.href, base)
			if href then
				emit("[")
			end
			local o: Open = { name = name, close = if href then "](" .. Html.mdUrl(href) .. ")" else "", opened = true }
			table.insert(stack, o)
		elseif CODE[name] then
			local lower = string.lower(src)
			local e1, e2 = string.find(lower, "</%s*" .. name .. "%s*>", t.last + 1)
			local inner = string.sub(src, t.last + 1, if e1 then e1 - 1 else #src)
			local text = string.gsub(Html.textOf(Html.parse(inner)), "%s+", " ")
			if text ~= "" then
				local run = 0
				for ticks in string.gmatch(text, "`+") do
					run = math.max(run, #ticks)
				end
				local fence = string.rep("`", run + 1)
				local pad = if string.match(text, "^`") or string.match(text, "`$") then " " else ""
				emit(fence .. pad .. text .. pad .. fence)
			end
			return if e2 then e2 + 1 else #src + 1
		elseif name == "br" then
			emit(if inTableRow(at) then " " else "\n")
		elseif name == "img" then
			local alt = Html.decodeEntities(t.attrs.alt or "")
			local url = Html.resolve(t.attrs.src, base, true)
			emit(if url then Html.mdImage(alt, url) else Html.mdEscape(alt))
		elseif name == "iframe" or name == "video" or name == "audio" then
			local url = Html.resolve(t.attrs.src, base)
			if url then
				emit("[" .. Html.mdEscape(url) .. "](" .. Html.mdUrl(url) .. ")")
			end
		elseif name == "td" or name == "th" then
			emit(" ")
		elseif Html.BLOCK[name] then
			boundary()
		end
		return t.last + 1
	end

	local pos, n = 1, #src
	while pos <= n do
		local at = string.find(src, "[`<\\%]]", pos)
		if at == nil then
			emit(string.sub(src, pos))
			break
		end
		if at > pos then
			emit(string.sub(src, pos, at - 1))
		end
		local c = string.sub(src, at, at)
		if c == "\\" then
			emit(string.sub(src, at, at + 1))
			pos = at + 2
		elseif c == "`" then
			local ticks = string.match(src, "^`+", at) :: string
			local stop = at + #ticks
			local e = stop
			local found: number? = nil
			while true do
				local s1, s2 = string.find(src, "`+", e)
				if s1 == nil or s2 == nil then
					break
				end
				if s2 - s1 + 1 == #ticks then
					found = s2
					break
				end
				e = s2 + 1
			end
			if found then
				emit(string.sub(src, at, found))
				pos = found + 1
			else
				emit(ticks)
				pos = stop
			end
		elseif c == "]" then
			if base and string.match(src, "^%(/[^/]", at + 1) then
				emit("](" .. base)
				pos = at + 2
			else
				emit("]")
				pos = at + 1
			end
		elseif string.sub(src, at, at + 3) == "<!--" then
			local e = string.find(src, "-->", at + 4, true)
			pos = if e then e + 3 else n + 1
		else
			local t = Html.tagAt(src, at)
			if t == nil then
				emit("<")
				pos = at + 1
			elseif not Html.ALLOWED[t.name] then
				emit("\\" .. string.sub(src, at, t.last))
				pos = t.last + 1
			else
				pos = tag(t, at)
			end
		end
	end
	for k = #stack, 1, -1 do
		close(stack[k])
	end
	return table.concat(out)
end

-- Markdown with Grafana's HTML handling: one `md` node when the content has
-- no HTML block, else the blocks in order in a column.
function M.markdown(content: string, key: string, base: string?): Node
	local nodes: { Node } = {}
	local md: { string } = {}
	local function flush()
		if #md > 0 then
			local text = table.concat(md, "\n")
			table.clear(md)
			if not blank(text) then
				table.insert(nodes, { k = "md", p = { text = text } })
			end
		end
	end
	for _, seg in segments(content) do
		if seg.kind == "html" then
			flush()
			local view = Html.view(seg.text, { base_url = base })
			if #(view.c :: { Node }) > 0 or (view.p :: { [string]: any }).text then
				table.insert(nodes, view)
			end
		else
			table.insert(md, if seg.kind == "md" then M.inline(seg.text, base) else seg.text)
		end
	end
	flush()
	if #nodes == 0 then
		return { k = "md", p = { key = key, text = "" } }
	elseif #nodes == 1 then
		local p = nodes[1].p :: { [string]: any }
		p.key = key
		return nodes[1]
	end
	for i, node in nodes do
		local p = node.p :: { [string]: any }
		p.key = "s" .. i
	end
	return ui.col(nodes, { key = key })
end

function M.view(panel: any, env: Env, opts: Common.Options): Node
	local options = Json.obj(env, Json.path(env, panel, "options"))
	local content = Json.str(env, options.content) or ""
	if opts.interpolate then
		content = opts.interpolate(content)
	end
	local mode = Json.str(env, options.mode) or "markdown"
	if mode == "html" then
		return Html.view(content, { key = opts.key, base_url = opts.base_url })
	elseif mode == "code" then
		local lang = Json.str(env, Json.path(env, options, "code", "language"))
		return ui.code(content, lang, nil, { key = opts.key })
	end
	return M.markdown(content, opts.key, opts.base_url)
end

return M
