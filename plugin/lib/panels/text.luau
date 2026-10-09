--!strict
-- The text panel (public/app/plugins/panel/text: panelcfg.cue, TextPanel.tsx).
-- options.mode markdown renders through Tern's `md` node; html is reduced to
-- its text (Tern has no HTML node, and dashboards' HTML is mostly
-- formatting); code shows options.code.language in a `code` node. Content
-- is interpolated with dashboard variables first, as TextPanel does.

local Common = require("./common")
local Env = require("../env")
local Json = require("./json")
local ui = require("../ui")

type Env = Env.Env
type Node = ui.Node

local M = {}

local ENTITIES: { [string]: string } = {
	amp = "&",
	lt = "<",
	gt = ">",
	quot = '"',
	apos = "'",
	nbsp = " ",
	["#39"] = "'",
}

local function decodeEntities(s: string): string
	return (
		string.gsub(s, "&(#?[%w]+);", function(name: string): string
			local known = ENTITIES[name]
			if known then
				return known
			end
			local hex = string.match(name, "^#[xX](%x+)$")
			local dec = string.match(name, "^#(%d+)$")
			local code = if hex then tonumber(hex, 16) elseif dec then tonumber(dec) else nil
			if code and code < 0x110000 then
				return utf8.char(code)
			end
			return "&" .. name .. ";"
		end)
	)
end

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
	s = decodeEntities(s)
	s = string.gsub(s, " *\n *", "\n")
	s = string.gsub(s, "\n\n\n+", "\n\n")
	-- List items sit directly under the line before them.
	s = string.gsub(s, "\n+%- ", "\n- ")
	return (string.match(s, "^%s*(.-)%s*$") or "")
end

function M.view(panel: any, env: Env, opts: Common.Options): Node
	local options = Json.obj(env, Json.path(env, panel, "options"))
	local content = Json.str(env, options.content) or ""
	if opts.interpolate then
		content = opts.interpolate(content)
	end
	local mode = Json.str(env, options.mode) or "markdown"
	if mode == "html" then
		return ui.text({ M.htmlToText(content) }, { key = opts.key, wrap = "word" })
	elseif mode == "code" then
		local lang = Json.str(env, Json.path(env, options, "code", "language"))
		return ui.code(content, lang, nil, { key = opts.key })
	end
	return { k = "md", p = { key = opts.key, text = content } }
end

return M
