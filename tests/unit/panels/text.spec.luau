--!strict
-- The text panel (public/app/plugins/panel/text/panelcfg.cue, TextPanel.tsx):
-- markdown as Tern markdown with the inline HTML Grafana renders, HTML mode
-- sanitized as Grafana does, code as code, the content interpolated with
-- dashboard variables first. The HTML cases reproduce patterns of real
-- dashboards (Grafana Cloud billing and IRM insights), checked against
-- Grafana 12's render of dev/grafana/dashboards/tern-text-html.json.
local t = require("../../lib/test")
local S = require("./support")
local Text = require("../../../plugin/lib/panels/text")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env
local BASE = "https://grafana.example"

local function md(content: string): any
	return Text.view({ options = { mode = "markdown", content = content } }, env, { key = "x", base_url = BASE })
end

local function html(content: string): any
	return Text.view({ options = { mode = "html", content = content } }, env, { key = "x", base_url = BASE })
end

-- The el nodes of a tree in document order.
local function els(node: any, out: { any }?): { any }
	local list = out or {}
	if node.k == "el" then
		table.insert(list, node)
	end
	for _, c in node.c or {} do
		els(c, list)
	end
	return list
end

local function find(node: any, tag: string): any
	for _, e in els(node) do
		if e.p.tag == tag then
			return e
		end
	end
	return nil
end

-- Text of el nodes with their link targets, as "text<href>".
local function links(node: any): { string }
	local out = {}
	for _, e in els(node) do
		if e.p.href and e.p.text and e.p.text ~= "" then
			table.insert(out, e.p.text .. "<" .. e.p.href .. ">")
		end
	end
	return out
end

-- The inputs (panel JSON and frames) are byte-identical across the pinned
-- Grafana versions, so one version covers them.
local version = S.VERSIONS[#S.VERSIONS]
describe("text on tern-panels, Grafana " .. version, function()
	-- Panel 10 "About these fixtures": markdown.
	it("renders markdown content as an md node", function()
		local panel = S.panel(version, 10)
		local node: any = Text.view(panel, env, { key = "x" })
		expect(node.k).toBe("md")
		expect(node.p.text).toBe(panel.options.content)
	end)

	it("interpolates dashboard variables into the content", function()
		local panel = S.clone(S.panel(version, 10))
		panel.options.content = "Env: $env"
		local node: any = Text.view(panel, env, {
			key = "x",
			interpolate = function(s: string): string
				return (string.gsub(s, "%$env", "prod"))
			end,
		})
		expect(node.p.text).toBe("Env: prod")
	end)

	it("shows code mode in a code node with the panel's language", function()
		local panel = S.clone(S.panel(version, 10))
		panel.options.mode = "code"
		panel.options.code.language = "json"
		panel.options.content = '{"a": 1}'
		local node: any = Text.view(panel, env, { key = "x" })
		expect(node.k).toBe("code")
		expect(node.p.lang).toBe("json")
	end)
end)

-- Grafana renders the HTML inside Markdown; Tern's md node would show it as
-- raw tags, which is what the billing dashboards looked like before.
describe("text markdown with inline HTML", function()
	it("turns links in list items into Markdown links, target ignored", function()
		local node = md(
			'- billed by <a href="https://example.com/users" target="_blank">active monthly users</a>, with extra costs.\n'
				.. '- <a href="/d/cardinality-management" target="_blank">Locate your metrics</a> from dashboards'
		)
		expect(node.k).toBe("md")
		expect(node.p.text).toBe(
			"- billed by [active monthly users](https://example.com/users), with extra costs.\n"
				.. "- [Locate your metrics](https://grafana.example/d/cardinality-management) from dashboards"
		)
	end)

	it("follows a tag broken over lines inside a paragraph", function()
		local node = md('Profiles are subject to <a\n  href="https://example.com/pricing" target="_blank">Pricing</a>.')
		expect(node.p.text).toBe("Profiles are subject to [Pricing](https://example.com/pricing).")
	end)

	it("keeps a paragraph that opens with a link inline", function()
		-- Text after the tag makes it prose, not a CommonMark HTML block.
		local node = md('<a href="https://example.com/r" target="_blank">Reconcile invoices</a>')
		expect(node.k).toBe("md")
		expect(node.p.text).toBe("[Reconcile invoices](https://example.com/r)")
	end)

	it("maps nested inline tags to emphasis, moving spaces outside the markers", function()
		local node =
			md("Line one<br>two with <b><i>both</i></b>, <strong> spaced </strong>, <u>under</u> and <b></b>none")
		expect(node.p.text).toBe("Line one\ntwo with ***both***,  **spaced** , under and none")
	end)

	it("decodes code tag content into a code span", function()
		-- CommonMark drops one space each side of a padded code span.
		expect(md("Use <code>a &lt;b&gt; `c`</code> here").p.text).toBe("Use `` a <b> `c` `` here")
	end)

	it("leaves code spans, fences and escapes as written", function()
		local src = 'Keep `<b>x</b>` and \\<b> literal\n\n```\n<div>\n<a href="/x">y</a>\n```'
		local node = md(src)
		expect(node.k).toBe("md")
		expect(node.p.text).toBe(src)
	end)

	it("resolves rooted Markdown link targets against the Grafana", function()
		local node = md("Set up [IRM](/a/grafana-irm-app/alert-groups) and [docs](https://grafana.com/docs)")
		expect(node.p.text).toBe(
			"Set up [IRM](https://grafana.example/a/grafana-irm-app/alert-groups) and [docs](https://grafana.com/docs)"
		)
	end)

	it("shows tags Grafana's sanitizer escapes as literal text", function()
		-- Grafana 12 draws `<custom-tag>inner</custom-tag>` with the tags as
		-- plain text; a backslash keeps Tern's Markdown from treating them as HTML.
		expect(md("Unknown <custom-tag>inner</custom-tag> <input type=checkbox>").p.text).toBe(
			"Unknown \\<custom-tag>inner\\</custom-tag> \\<input type=checkbox>"
		)
	end)

	it("drops unsafe link targets and keeps the text", function()
		expect(md('<a href="javascript:alert(1)" onclick="x()">bad</a> link').p.text).toBe("bad link")
	end)

	it("draws images it can resolve and the alt text otherwise", function()
		local node = md('A <img src="/public/img/icon.svg" alt="logo"> and <img src="icon.png" alt="rel">')
		expect(node.p.text).toBe("A ![logo](https://grafana.example/public/img/icon.svg) and rel")
		local bare = Text.view({ options = { content = 'See <img src="/x.png" alt="x">' } }, env, { key = "x" })
		expect((bare :: any).p.text).toBe("See x")
	end)
end)

describe("text markdown with HTML blocks", function()
	it("draws a div wrapper block as HTML instead of stray tags", function()
		-- The billing dashboard's pattern: a self-closed <a/> that still wraps
		-- the heading below it (browsers ignore the slash), then Markdown.
		local node = md(
			'<div>\n  <a href="https://example.com/invoices" target="_blank"/>\n    <h1 style="\n      text-align: center;\n    ">\n'
				.. "      View invoices\n    </h1>\n  </a>\n</div>\n\nText after with `<b>code</b>`."
		)
		expect(node.k).toBe("col")
		expect(#node.c).toBe(2)
		local block = node.c[1]
		expect(block.k).toBe("el")
		expect(block.p.class).toBe("tgx")
		local h1 = find(block, "h1")
		expect(h1.p.href).toBe("https://example.com/invoices")
		expect(h1.p.class).toBe("tgx-center")
		expect(S.text(h1)).toBe(" View invoices ")
		expect(node.c[2].k).toBe("md")
		expect(node.c[2].p.text).toBe("\nText after with `<b>code</b>`.")
		expect((string.find(S.text(block), "<", 1, true))).toBeNil()
	end)

	it("keeps HTML blocks and Markdown in source order", function()
		local node = md("# Title\n<div><p><b>Bold</b> lead</p></div>\n\nAfter **md**.")
		expect(node.k).toBe("col")
		expect(node.c[1].p.text).toBe("# Title")
		expect(node.c[2].k).toBe("el")
		local b = find(node.c[2], "b")
		expect(b.p.text).toBe("Bold")
		expect(node.c[3].p.text).toBe("\nAfter **md**.")
	end)

	it("shows script and style blocks as text, as Grafana's sanitizer escapes them", function()
		local node = md("<script>alert(1)</script>\n<style>p { color: red; }</style>\n\nok")
		expect(node.k).toBe("col")
		expect(S.text(node.c[1])).toBe("<script>alert(1)</script> <style>p { color: red; }</style>")
	end)

	it("drops comment blocks", function()
		local node = md("<!-- hidden\nnote -->\nshown")
		expect(node.k).toBe("md")
		expect(node.p.text).toBe("shown")
	end)
end)

describe("text html mode", function()
	it("keeps a table whose cells hold block content", function()
		-- The IPv6 schedule pattern: cells of stacked divs, bold via style.
		local node = html(
			'<table><colgroup><col style="width:50%"></colgroup>\n  <tr>\n    <td style="font-weight:bold;">Monday</td>\n'
				.. "    <td>Tuesday</td>\n  </tr>\n  <tr>\n    <td><div><b>Haven</b></div><div><b>Lofts</b></div></td>\n"
				.. "    <td><div>No upgrades</div></td>\n  </tr>\n</table>"
		)
		local tags = {}
		for _, e in els(node) do
			table.insert(tags, e.p.tag)
		end
		expect(table.concat(tags, " ")).toBe("div table tr td td tr td div b div b td div")
		expect(find(node, "td").p.class).toBe("tgx-b")
		expect(S.text(node)).toBe("MondayTuesdayHavenLoftsNo upgrades")
	end)

	it("closes implied paragraphs, list items and cells", function()
		local node = html("<p>one<p>two<ul><li>a<li>b</ul>")
		local tags = {}
		for _, e in els(node) do
			table.insert(tags, e.p.tag .. "=" .. (e.p.text or ""))
		end
		expect(table.concat(tags, " ")).toBe("div= p=one p=two ul= li=a li=b")
	end)

	it("links text inside anchors and resolves rooted paths", function()
		local node = html('<p>See <a href="/d/abc">the <b>dashboard</b></a> or <a href="https://x.io">x</a>.</p>')
		expect(table.concat(links(node), " ")).toBe(
			"the <https://grafana.example/d/abc> dashboard<https://grafana.example/d/abc> x<https://x.io>"
		)
	end)

	it("keeps line breaks, entities and preformatted text", function()
		local node = html("<p>a &amp; b &#x2713;<br>c</p><pre>\n  x  y\n</pre>")
		expect(S.text(node)).toBe("a & b ✓\nc  x  y\n")
		expect(find(node, "span").p.class).toBe("tgx-br")
	end)

	it("draws images as Markdown images, inside their link", function()
		local node = html('<div><a href="https://x.io"><img src="/public/logo.svg" alt="Logo"></a></div>')
		local img = node.c[1].c[1].c[1] :: any
		expect(img.k).toBe("md")
		expect(img.p.text).toBe("[![Logo](https://grafana.example/public/logo.svg)](https://x.io)")
	end)

	it("shows an iframe as a link to its source", function()
		local node = html('<iframe src="https://example.com/frame"></iframe>')
		expect(table.concat(links(node), " ")).toBe("https://example.com/frame<https://example.com/frame>")
	end)

	it("escapes disallowed tags and drops comments", function()
		local node = html('<form action="/x"><input type="text"></form><!-- c --><b onclick="x()">hi</b>')
		expect(S.text(node)).toBe('<form action="/x"><input type="text"></form>hi')
		expect(find(node, "b").p.onclick).toBeNil()
	end)
end)

describe("text htmlToText", function()
	it("keeps the text of HTML and its line structure", function()
		local src = '<h2>Runbook</h2><p>Check <a href="https://x">the &amp; docs</a>.<br/>Then:</p>'
			.. "<ul><li>restart</li><li>page &lt;oncall&gt;</li></ul>"
			.. "<script>alert(1)</script><style>p{}</style><!-- note -->"
		expect(Text.htmlToText(src)).toBe("Runbook\nCheck the & docs.\nThen:\n- restart\n- page <oncall>")
	end)

	it("decodes numeric entities", function()
		expect(Text.htmlToText("caf&#233; &#x2713;")).toBe("café ✓")
	end)
end)

return nil
