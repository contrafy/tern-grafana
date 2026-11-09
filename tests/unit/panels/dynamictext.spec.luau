--!strict
-- marcusolsson-dynamictext-panel 6.3.1: Handlebars templates over the
-- panel's rows, markdown-it inline rendering, sanitized HTML with inline
-- styles compiled to plugin/dynamictext.css classes. The panels reproduce
-- the patterns of dev/grafana/dashboards/tern-s4-dynamictext.json (status
-- cards with {{#if}}, HTML built by the query via {{{ }}}, data: images,
-- percentage bars).
local t = require("../../lib/test")
local S = require("./support")
local Frame = require("../../../plugin/lib/frame/types")
local Handlebars = require("../../../plugin/lib/panels/handlebars")
local HtmlStyle = require("../../../plugin/lib/panels/html_style")
local Dyn = require("../../../plugin/lib/panels/dynamictext")
local Registry = require("../../../plugin/lib/panels/registry")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env

local function hb(src: string, ctx: any, extra: any?): string
	return Handlebars.render(Handlebars.compile(src), ctx, extra)
end

local function frame(fields: { any }): Frame.Frame
	return { refId = "A", fields = fields }
end

local function panel(options: any, defaults: any?): any
	return {
		type = "marcusolsson-dynamictext-panel",
		options = options,
		fieldConfig = { defaults = defaults or {}, overrides = {} },
	}
end

local function view(p: any, frames: { Frame.Frame }): (any, any)
	return Registry.view(p, frames, env, { key = "k" })
end

describe("handlebars", function()
	it("escapes double-stash output and keeps triple-stash HTML, as SQL-built rows need", function()
		expect(hb("{{a}}|{{{a}}}|{{&a}}", { a = "<b>x</b>&'" })).toBe(
			"&lt;b&gt;x&lt;/b&gt;&amp;&#x27;|<b>x</b>&'|<b>x</b>&'"
		)
	end)
	it("treats 0, empty strings and empty lists as false in #if unless includeZero", function()
		expect(hb("{{#if n}}y{{else}}n{{/if}}{{#if n includeZero=true}}Y{{/if}}", { n = 0 })).toBe("nY")
		expect(hb("{{#if l}}y{{else}}n{{/if}}{{#unless s}}u{{/unless}}", { l = {}, s = "" })).toBe("nu")
	end)
	it("chains else if", function()
		expect(hb("{{#if a}}A{{else if b}}B{{else}}C{{/if}}", { b = true })).toBe("B")
	end)
	it("walks each with @index, @first, @last and ../ back to the row", function()
		local out =
			hb("{{#each l}}{{@index}}{{this}}{{../s}}{{#if @last}}.{{/if}}{{/each}}", { l = { "a", "b" }, s = "-" })
		expect(out).toBe("0a-1b-.")
		local obj = Handlebars.object({ z = 1, a = 2 }, { "z", "a" })
		expect(hb("{{#each o}}{{@key}}{{.}}{{/each}}", { o = obj })).toBe("z1a2")
	end)
	it("removes standalone block lines and honors ~", function()
		expect(hb("<ul>\n  {{#each l}}\n  <li>{{.}}</li>\n  {{/each}}\n</ul>", { l = { 1 } })).toBe(
			"<ul>\n  <li>1</li>\n</ul>"
		)
		expect(hb("a  {{~ x ~}}  b{{! c }}{{!-- d --}}", { x = "-" })).toBe("a-b")
	end)
	it("runs the plugin's helpers with JavaScript semantics", function()
		local ctx = { v = 3.14159, s = "a,b", n = 4 }
		expect(hb("{{toFixed v 2}} {{toFixed s 2}} {{eq n 4}} {{eq n '4'}} {{gt n 3}}", ctx)).toBe(
			"3.14 0 true false true"
		)
		expect(hb("{{join (split s ',') '|'}} {{contains (split s ',') 'b'}}", ctx)).toBe("a|b true")
		expect(hb("{{#if (and n (not x))}}ok{{/if}} {{match s '^a,%w$'}}", ctx)).toBe("ok false")
		expect(hb("{{match s '^a,[a-z]$'}}", ctx)).toBe("true")
	end)
	it("pretty-prints json like JSON.stringify(v, null, 2)", function()
		local o = Handlebars.object({ a = 1, b = { 1, 2 } }, { "a", "b" })
		expect(hb("{{{json o}}}", { o = o })).toBe('{\n  "a": 1,\n  "b": [\n    1,\n    2\n  ]\n}')
	end)
	it("reports a missing helper and an unclosed block", function()
		local missing = pcall(hb, "{{nope a}}", {})
		expect(missing).toBe(false)
		local ok, err = pcall(hb, "{{#if a}}x", {})
		expect(ok).toBe(false)
		expect(string.find(tostring(err), "if", 1, true) ~= nil).toBe(true)
	end)
end)

describe("inline styles", function()
	it("spells exact colors and lengths with slot classes the stylesheet defines", function()
		local r = HtmlStyle.compile("color:#ee44cc; width:37%; padding:6px 12px; font-weight:900")
		expect(#r.dropped).toBe(0)
		local css = HtmlStyle.stylesheet()
		for cls in string.gmatch(r.class, "%S+") do
			expect(string.find(css, "." .. cls .. "{", 1, true) ~= nil).toBe(true)
		end
		expect(string.find(r.class, "dtc1r238", 1, true) ~= nil).toBe(true)
		expect(string.find(r.class, "dtc1g68", 1, true) ~= nil).toBe(true)
		expect(string.find(r.class, "dtc1b204", 1, true) ~= nil).toBe(true)
		expect(string.find(r.class, "dt-fwt-900", 1, true) ~= nil).toBe(true)
	end)
	it("shares one slot between equal values (padding on four sides)", function()
		local r = HtmlStyle.compile("padding:18px")
		expect(r.class).toBe("dt1t1 dt1o8 dt-pt1 dt-pr1 dt-pb1 dt-pl1")
	end)
	it("draws borders, radius, shadows and gradients the cards use", function()
		local r = HtmlStyle.compile(
			"border:1px solid #6b1d1d;border-radius:999px;box-shadow:0 10px 25px rgba(0,0,0,.25);background:linear-gradient(90deg,#1f6feb,#8250df)"
		)
		expect(#r.dropped).toBe(0)
		for _, c in { "dt-bts-solid", "dt-btc1", "dt-rtl", "dt-sh", "dt-sc", "dt-lg2", "dt-ga" } do
			expect(string.find(r.class, c, 1, true) ~= nil).toBe(true)
		end
	end)
	it("names what it cannot draw", function()
		local r = HtmlStyle.compile("transform:rotate(3deg); cursor:pointer; color:var(--x); display:flex")
		expect(r.dropped).toEqual({ "transform", "color" })
		expect(string.find(r.class, "dt-d-flex", 1, true) ~= nil).toBe(true)
	end)
	it("draws values Tern's parser rejects as their nearest accepted value", function()
		expect(#HtmlStyle.compile("width:fit-content; font-size:large").dropped).toBe(0)
		expect(HtmlStyle.compile("width:fit-content").class).toBe(HtmlStyle.compile("width:max-content").class)
		expect(HtmlStyle.compile("font-size:large").class).toBe(HtmlStyle.compile("font-size:18px").class)
		expect(HtmlStyle.compile("width:large").dropped).toEqual({ "width" })
	end)
	it("names properties Tern cannot style as not drawn", function()
		local r = HtmlStyle.compile("text-indent:2em; word-spacing:4px; table-layout:fixed")
		expect(r.dropped).toEqual({ "text-indent", "word-spacing", "table-layout" })
	end)
	it("only declares properties and values Tern 0.9.13's stylesheet parser accepts", function()
		-- Each loads without a parse error in Tern 0.9.13; a rejected
		-- declaration does nothing, so its class would silently not draw.
		local known: { [string]: boolean } = {}
		for _, p in
			string.split(
				"align-content align-items align-self background background-color background-image border-bottom "
					.. "border-bottom-color border-bottom-left-radius border-bottom-right-radius border-bottom-style "
					.. "border-bottom-width border-collapse border-left-color border-left-style border-left-width "
					.. "border-right-color border-right-style border-right-width border-top-color "
					.. "border-top-left-radius border-top-right-radius border-top-style border-top-width bottom "
					.. "box-shadow box-sizing color column-gap cursor display flex-basis flex-direction flex-grow "
					.. "flex-shrink flex-wrap font-family font-size font-style font-weight height justify-content "
					.. "justify-items justify-self left letter-spacing line-height list-style-type margin-bottom "
					.. "margin-left margin-right margin-top max-height max-width min-height min-width object-fit "
					.. "opacity order overflow-wrap overflow-x overflow-y padding padding-bottom padding-left "
					.. "padding-right padding-top position right row-gap text-align text-decoration "
					.. "text-decoration-line text-overflow text-transform top vertical-align visibility white-space "
					.. "width word-break z-index",
				" "
			)
		do
			known[p] = true
		end
		local css = HtmlStyle.stylesheet()
		for prop, value in string.gmatch(css, "[{;]([%a%-]+):([^;}]*)") do
			if string.sub(prop, 1, 2) ~= "--" then
				expect({ prop = prop, known = known[prop] == true }).toEqual({ prop = prop, known = true })
				local fit = string.find(value :: string, "fit-content", 1, true) ~= nil
				expect({ prop = prop, fit = fit }).toEqual({ prop = prop, fit = false })
			end
		end
		expect(string.find(css, "font-size:%a") ~= nil).toBe(false)
	end)
	it("keeps the stylesheet under 150 KB", function()
		expect(#HtmlStyle.stylesheet() < 150 * 1024).toBe(true)
	end)
end)

describe("dynamictext panel", function()
	it("leaves panels with their own JavaScript or URL resources on the ladder", function()
		local ok, why = Registry.supports(panel({ content = "x", afterRender = "el.x = 1" }), env)
		expect(ok).toBe(false)
		expect(why).toBe("the panel runs its own JavaScript (afterRender)")
		ok, why = Registry.supports(panel({ content = "x", externalStyles = { { url = "https://x/a.css" } } }), env)
		expect(ok).toBe(false)
		ok = Registry.supports(panel({ content = "x", helpers = "", afterRender = "  " }), env)
		expect(ok).toBe(true)
	end)
	it("renders every row with {{#if}} and the formatted value of fields with a unit", function()
		local p = panel({
			renderMode = "everyRow",
			wrap = false,
			content = '<div style="color:#f87171">{{site}}: {{#if down}}down{{else}}up{{/if}} {{lat}}</div>',
		})
		local f = frame({
			Frame.field("site", "string", { "DFW", "ORD" }),
			Frame.field("down", "boolean", { false, true }),
			Frame.field("lat", "number", { 12, 340 }, nil, { unit = "ms" }),
		})
		local node = view(p, { f })
		local text = S.text(node)
		expect(string.find(text, "DFW: up 12 ms", 1, true) ~= nil).toBe(true)
		expect(string.find(text, "ORD: down 340 ms", 1, true) ~= nil).toBe(true)
		local rows = S.findAll(node, function(n: any): boolean
			return n.p and n.p.class == "dt-row"
		end)
		expect(#rows).toBe(2)
	end)
	it("draws HTML a query built through {{{ }}} as elements, not text", function()
		local p = panel({ wrap = false, content = "**{{who}}** {{{rows}}}" })
		local f = frame({
			Frame.field("who", "string", { "Avery" }),
			Frame.field("rows", "string", { "<table><tr><td>INC-1</td></tr></table>" }),
		})
		local node = view(p, { f })
		expect(S.find(node, function(n: any): boolean
			return n.p and n.p.tag == "strong" and n.p.text == "Avery"
		end) ~= nil).toBe(true)
		expect(S.find(node, function(n: any): boolean
			return n.p and n.p.tag == "td" and n.p.text == "INC-1"
		end) ~= nil).toBe(true)
	end)
	it("turns data: images into image assets", function()
		local svg = '<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"/>'
		local p = panel({ wrap = false, content = '<img src="{{u}}" style="width:100%">' })
		local f = frame({ Frame.field("u", "string", { "data:image/svg+xml;utf8," .. svg }) })
		local node, assets = view(p, { f })
		local img = S.find(node, function(n: any): boolean
			return n.k == "image"
		end)
		expect(img ~= nil).toBe(true)
		expect(assets[img.p.asset].bytes).toBe(svg)
		local mime, bytes = Dyn.dataImage("data:image/png;base64,iVBORw0KGgo=")
		expect(mime).toBe("image/png")
		expect(bytes).toBe("\137PNG\r\n\26\n")
	end)
	it("shows the default content when the frame has no rows", function()
		local node = view(panel({ wrap = false, content = "x", defaultContent = "Nothing here" }), { frame({}) })
		expect(string.find(S.text(node), "Nothing here", 1, true) ~= nil).toBe(true)
	end)
	it("gives allRows the rows as data", function()
		local p = panel({ renderMode = "allRows", wrap = false, content = "{{#each data}}{{n}};{{/each}}" })
		local node = view(p, { frame({ Frame.field("n", "number", { 1, 2 }) }) })
		expect(string.find(S.text(node), "1;2;", 1, true) ~= nil).toBe(true)
	end)
	it("shows template errors the way the plugin does", function()
		local node = view(panel({ content = "{{#if a}}" }), { frame({ Frame.field("a", "number", { 1 }) }) })
		expect(string.find(S.text(node), "Couldn't build text from template", 1, true) ~= nil).toBe(true)
	end)
	it("applies plain panel styles and notes rule sets it skips", function()
		local plain = view(panel({ content = "x", styles = "padding:4px" }), { frame({}) })
		expect(string.find(plain.p.class, "dt-pt1", 1, true) ~= nil).toBe(true)
		local rules = view(panel({ content = "x", styles = ".x { color: red }" }), { frame({}) })
		expect(string.find(S.text(rules), "panel styles with selectors", 1, true) ~= nil).toBe(true)
	end)
end)

describe("markdown-it renderInline", function()
	it("passes tags through and formats the text between them", function()
		expect(Dyn.renderInline('<div style="a:b">*x* `<b>` a_b_c</div>')).toBe(
			'<div style="a:b"><em>x</em> <code>&lt;b&gt;</code> a_b_c</div>'
		)
	end)
end)

return nil
