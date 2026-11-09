--!strict
-- The Zabbix Problems panel (alexanderzobnin-zabbix-triggers-panel) over the
-- problems its Zabbix targets fetch on the dev stack (tests/lib/zabbix.luau):
-- the rows, their order and colors must be what Grafana's render of panel 7
-- of tern-s4-zabbix lists.
local S = require("./support")
local TsGradient = require("../../../plugin/lib/render/ts_gradient")
local Z = require("../../lib/zabbix")
local ZabbixProblems = require("../../../plugin/lib/panels/zabbix_problems")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local env = Z.env
local OPTS: any = { key = "p" }

local function frames(version: string): { any }
	local outcome = Z.run(version, Z.panel(version, 7).targets)
	assert(outcome.data, outcome.error)
	return outcome.data.frames
end

for _, version in Z.VERSIONS do
	describe("Zabbix Problems panel on Grafana " .. version, function()
		local panel = Z.panel(version, 7)

		it("lists both targets' problems by severity, then time, then event id, newest first", function()
			local rows = ZabbixProblems.rows(frames(version), ZabbixProblems.options(panel, env), env)
			local got: { string } = {}
			for _, r in rows do
				table.insert(got, string.format("%s %d %s", r.eventid, r.severity, r.host or ""))
			end
			-- Grafana lists the two problems both targets return twice, as its render shows.
			expect(got).toEqual({
				"27 5 nni-edge-ord",
				"27 5 nni-edge-ord",
				"26 4 nni-edge-dfw",
				"26 4 nni-edge-dfw",
				"18 3 nni-edge-ord",
				"25 2 nni-edge-dfw",
			})
		end)

		it("shows the columns its options turn on and fills severity cells with the severity's color", function()
			local view = ZabbixProblems.view(panel, frames(version), env, OPTS)
			local heads: { string } = {}
			for _, h in
				S.findAll(view, function(n)
					return n.p and type(n.p.class) == "string" and string.find(n.p.class, "tg-h", 1, true) == 1
				end)
			do
				table.insert(heads, S.text(h))
			end
			-- statusField and ackField off; Problem and Time always.
			expect(heads).toEqual({ "Host", "Severity", "Problem", "Tags", "Time" })
			local sev = S.findAll(view, function(n)
				return n.p and type(n.p.class) == "string" and string.find(n.p.class, "tgz-sev", 1, true) == 1
			end)
			expect(#sev).toBe(6)
			expect(S.text(sev[1])).toBe("Disaster")
			expect(sev[1].p.class).toBe("tgz-sev " .. TsGradient.fixedClass("rgb(215, 0, 0)"))
			expect(S.text(sev[6])).toBe("Warning")
			expect(sev[6].p.class).toBe("tgz-sev " .. TsGradient.fixedClass("rgb(175, 180, 36)"))
			local tags = S.findAll(view, function(n)
				return n.p and type(n.p.class) == "string" and string.find(n.p.class, "tgz-tag ", 1, true) == 1
			end)
			expect(tags[1].p.text).toBe("Priority: 1")
			expect(string.find(S.text(view), "Page 1 of 1", 1, true) ~= nil).toBe(true)
		end)
	end)
end

describe("Zabbix Problems panel", function()
	it("colors tags by EventTag.tsx's hash of the lower-cased tag name", function()
		-- Expected values from the browser's own djb2 (JavaScript, 32-bit shifts).
		expect(ZabbixProblems.tagColor("Priority")).toBe("#BF1B00")
		expect(ZabbixProblems.tagColor("description")).toBe("#584477")
		expect(ZabbixProblems.tagColor("component")).toBe("#2F4F4F")
		expect(ZabbixProblems.tagColor("scope")).toBe("#99440A")
	end)

	it("says No problems found without problems", function()
		local view = ZabbixProblems.view(Z.panel("12.4.12", 7), {}, env, OPTS)
		expect(string.find(S.text(view), "No problems found", 1, true) ~= nil).toBe(true)
	end)

	it("draws one card per problem in the list layout", function()
		local panel = S.clone(Z.panel("12.4.12", 7))
		panel.options.layout = "list"
		local view = ZabbixProblems.view(panel, frames("12.4.12"), env, OPTS)
		local cards = S.findAll(view, function(n)
			return n.p and n.p.class == "tgz-card"
		end)
		expect(#cards).toBe(6)
		expect(string.find(S.text(cards[1]), "Transit nni-edge-ord down", 1, true) ~= nil).toBe(true)
	end)

	it("leaves panels saved before the React migration to Grafana", function()
		local ok, reason = ZabbixProblems.supports({ schemaVersion = 5, triggerSeverity = {} }, env)
		expect(ok).toBe(false)
		expect(reason).toBe("a Problems panel saved before its React migration migrates in Grafana's browser")
	end)
end)

return nil
