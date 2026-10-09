--!strict
-- The text panel (public/app/plugins/panel/text/panelcfg.cue, TextPanel.tsx):
-- markdown as Tern markdown, HTML reduced to its text, code as code, the
-- content interpolated with dashboard variables first.
local t = require("../../lib/test")
local S = require("./support")
local Text = require("../../../plugin/lib/panels/text")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env

for _, version in S.VERSIONS do
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
end

describe("text html mode", function()
	it("keeps the text of HTML and its line structure", function()
		local html = '<h2>Runbook</h2><p>Check <a href="https://x">the &amp; docs</a>.<br/>Then:</p>'
			.. "<ul><li>restart</li><li>page &lt;oncall&gt;</li></ul>"
			.. "<script>alert(1)</script><style>p{}</style><!-- note -->"
		expect(Text.htmlToText(html)).toBe("Runbook\nCheck the & docs.\nThen:\n- restart\n- page <oncall>")
	end)

	it("decodes numeric entities", function()
		expect(Text.htmlToText("caf&#233; &#x2713;")).toBe("café ✓")
	end)

	it("renders html as wrapped text", function()
		local node = Text.view({ options = { mode = "html", content = "<b>hi</b>" } }, env, { key = "x" })
		expect(node.k).toBe("text")
		expect(S.text(node)).toBe("hi")
	end)
end)

return nil
