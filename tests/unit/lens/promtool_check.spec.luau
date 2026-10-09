--!strict
-- `promtool check rules|config` and `promtool test rules` gate rule and config
-- changes in CI and before reloads; the lens must put every failure where it
-- happened (file, line, rule) and never call a failing run green. Captures
-- come from both promtool generations: 3.x dropped the `Unit Testing:` file
-- header, so test verdicts must still land on the right files.
local Check = require("../../../plugin/lib/lens/promtool_check")
local Fixtures = require("../../lib/fixtures")
local S = require("./support")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local VERSIONS = { "2.53.5", "3.15.0" }
local BAD = "/etc/prometheus/promtool/rules-bad.yml"
local PASS = "/etc/prometheus/promtool/rules-test-pass.yml"
local FAIL = "/etc/prometheus/promtool/rules-test-fail.yml"

local function argvOf(command: string): { string }
	local words: { string } = {}
	for w in string.gmatch(command, "%S+") do
		table.insert(words, w)
	end
	table.remove(words, 1)
	return words
end

local function capture(version: string, name: string, stderrAfter: number?): S.Capture
	return S.capture("promtool/" .. version .. "/" .. name .. ".txt", stderrAfter)
end

local function report(c: S.Capture): Check.Report
	return Check.build(Check.parseArgs("promtool", argvOf(c.command)), c.lines)
end

local function view(c: S.Capture, cwd: string?): any
	local state = Check.open(S.run("promtool", argvOf(c.command), cwd))
	for _, l in c.lines do
		Check.line(state, l)
	end
	Check.finish(state, c.status)
	return Check.view(state, S.env())
end

describe("promtool check fixtures", function()
	it("cover every recorded check and test capture", function()
		for _, version in VERSIONS do
			local seen = 0
			for _, prefix in { "check_", "test_" } do
				for _, path in Fixtures.list("promtool/" .. version .. "/" .. prefix) do
					if string.match(path, "%.txt$") then
						seen += 1
						local c = S.capture(path)
						local inv = Check.parseArgs("promtool", argvOf(c.command))
						expect(inv.command ~= nil).toBe(true)
						expect(#Check.build(inv, c.lines).files > 0).toBe(true)
					end
				end
			end
			expect(seen).toBe(5)
		end
	end)
end)

describe("promtool check rules", function()
	for _, version in VERSIONS do
		describe(version, function()
			it("passes every file with its rule count", function()
				local r = report(capture(version, "check_rules_good"))
				expect(#r.files).toBe(2)
				expect(r.files[1].path).toBe("/etc/prometheus/rules/recording.yml")
				expect(r.files[1].verdict).toBe("ok")
				expect(r.files[1].summary).toEqual({ "3 rules found" })
				expect(r.files[2].summary).toEqual({ "4 rules found" })
				expect(r.unparsed).toBe(0)
				local v = view(capture(version, "check_rules_good"))
				expect(v.p.tone).toBe("success")
				expect(S.contains(S.textOf(v), "2 passed")).toBe(true)
			end)

			it("places each rule error at its file, line, group and rule", function()
				local r = report(capture(version, "check_rules_bad"))
				expect(#r.files).toBe(1)
				local f = r.files[1]
				expect(f.verdict).toBe("failed")
				expect(#f.diagnostics).toBe(2)
				local parse, missing = f.diagnostics[1], f.diagnostics[2]
				expect(parse.severity).toBe("error")
				expect(parse.path).toBe(BAD)
				expect({ parse.line, parse.col }).toEqual({ 6, 15 })
				expect(parse.group).toBe("tern-bad")
				expect(parse.rule).toBe(1)
				expect(parse.rule_name).toBe("job:up:sum")
				expect(parse.message).toBe("could not parse expression: 1:17: parse error: unclosed left parenthesis")
				-- 0:0 is promtool's "no position" for a missing field.
				expect(missing.line).toBeNil()
				expect(missing.rule).toBe(2)
				expect(missing.rule_name).toBe("MissingExpr")
				expect(missing.message).toBe("field 'expr' must be set in rule")
			end)

			it("draws a failed run as error cards linking to the rule's line", function()
				local v = view(capture(version, "check_rules_bad"))
				expect(v.p.tone).toBe("error")
				local text = S.textOf(v)
				expect(S.contains(text, "FAILED")).toBe(true)
				expect(S.contains(text, "unclosed left parenthesis")).toBe(true)
				local cards = S.findAll(v, function(n: any): boolean
					return n.k == "card" and n.p.tone == "error" and n ~= v
				end)
				expect(#cards).toBe(2)
				expect(cards[1].p.head[1]).toEqual({
					t = BAD .. ":6:15",
					s = "path",
					href = "file://" .. BAD .. "#L6C15",
				})
			end)
		end)
	end

	-- `docker run` (no tty) forwards stdout and stderr separately, so a bad
	-- file's errors can arrive after the next file's verdict.
	it("puts errors on the file they name when stderr arrives late", function()
		local good = capture("3.15.0", "check_rules_good").lines
		local bad = capture("3.15.0", "check_rules_bad").lines
		local lines = { bad[1], good[1], good[2], good[3] }
		for i = 2, #bad do
			table.insert(lines, bad[i])
		end
		local inv = Check.parseArgs("promtool", { "check", "rules", BAD, "/etc/prometheus/rules/recording.yml" })
		local r = Check.build(inv, lines)
		expect(r.files[1].verdict).toBe("failed")
		expect(#r.files[1].diagnostics).toBe(2)
		expect(r.files[2].verdict).toBe("ok")
		expect(#r.files[2].diagnostics).toBe(0)
		expect(r.unparsed).toBe(0)
	end)

	-- cmd/promtool/main.go checkRuleGroups: errLint "%w %s" over several lines.
	it("shows lint findings as warnings that do not fail the file", function()
		local r = Check.build(Check.parseArgs("promtool", { "check", "rules", "dup.yml" }), {
			"Checking dup.yml",
			"  FAILED:",
			"lint error 1 duplicate rule(s) found.",
			"Metric: job:up:sum",
			"Label(s):",
			"Might cause inconsistency while recording expressions",
			"",
		})
		local f = r.files[1]
		expect(f.verdict).toBe("warning")
		expect(#f.diagnostics).toBe(1)
		expect(f.diagnostics[1].severity).toBe("warning")
		expect(f.diagnostics[1].message).toBe("1 duplicate rule(s) found.")
		expect(#f.diagnostics[1].detail).toBe(3)
	end)
end)

describe("promtool check config", function()
	for _, version in VERSIONS do
		it(version .. ": reports the config and every rule file it loads", function()
			local r = report(capture(version, "check_config"))
			local paths: { string } = {}
			for _, f in r.files do
				table.insert(paths, f.path :: string)
				expect(f.verdict).toBe("ok")
			end
			expect(paths).toEqual({
				"/etc/prometheus/prometheus.yml",
				"/etc/prometheus/rules/alerts.yml",
				"/etc/prometheus/rules/broken.yml",
				"/etc/prometheus/rules/recording.yml",
			})
			expect(r.files[1].summary).toEqual({ "3 rule files found", "valid config syntax" })
			expect(r.unparsed).toBe(0)
		end)
	end

	it("keeps a multi-line config error together and does not pass the file", function()
		local inv = Check.parseArgs("promtool", { "check", "config", "bad.yml" })
		local r = Check.build(inv, {
			"Checking bad.yml",
			"  FAILED: parsing YAML file bad.yml: yaml: unmarshal errors:",
			"  line 3: field scrape_intervall not found in type config.plain",
			"",
		})
		local f = r.files[1]
		expect(f.verdict).toBe("failed")
		expect(#f.diagnostics).toBe(1)
		expect(f.diagnostics[1].message).toBe("parsing YAML file bad.yml: yaml: unmarshal errors:")
		expect(f.diagnostics[1].detail).toEqual({ "  line 3: field scrape_intervall not found in type config.plain" })
	end)
end)

describe("promtool test rules", function()
	for _, version in VERSIONS do
		describe(version, function()
			it("names the passing file even without 3.x's header", function()
				local r = report(capture(version, "test_rules_pass"))
				expect(#r.files).toBe(1)
				expect(r.files[1].path).toBe(PASS)
				expect(r.files[1].verdict).toBe("ok")
				expect(view(capture(version, "test_rules_pass")).p.tone).toBe("success")
			end)

			it("shows a failure with what was expected and what was got", function()
				-- Both orders: stdout/stderr grouped and as written to the terminal.
				for _, after in { nil :: number?, if version == "2.53.5" then 1 else 0 } do
					local r = report(capture(version, "test_rules_fail", after))
					expect(#r.files).toBe(1)
					local f = r.files[1]
					expect(f.path).toBe(FAIL)
					expect(f.verdict).toBe("failed")
					expect(#f.failures).toBe(1)
					expect(f.failures[1].title).toBe("alertname: TernTargetDown, time: 1m")
					local detail = table.concat(f.failures[1].detail, "\n")
					expect(S.contains(detail, "exp:[")).toBe(true)
					expect(S.contains(detail, 'severity="warning"')).toBe(true)
					expect(S.contains(detail, "got:[]")).toBe(true)
					-- Shared indentation is gone.
					expect(string.sub(f.failures[1].detail[1], 1, 1) ~= " ").toBe(true)
				end
				local v = view(capture(version, "test_rules_fail"))
				expect(v.p.tone).toBe("error")
				expect(S.contains(S.textOf(v), "0 passed · 1 failed")).toBe(true)
			end)
		end)
	end

	it("maps 3.x verdicts onto the file arguments in order", function()
		local pass = capture("3.15.0", "test_rules_pass", 0)
		local fail = capture("3.15.0", "test_rules_fail", 0)
		local lines: { string } = {}
		for _, c in { pass, fail } do
			for _, l in c.lines do
				table.insert(lines, l)
			end
			table.insert(lines, "")
		end
		local r = Check.build(Check.parseArgs("promtool", { "test", "rules", PASS, FAIL }), lines)
		expect(#r.files).toBe(2)
		expect({ r.files[1].path, r.files[1].verdict }).toEqual({ PASS, "ok" })
		expect({ r.files[2].path, r.files[2].verdict }).toEqual({ FAIL, "failed" })
		-- An unexpanded glob cannot name them: they stay numbered.
		local glob = Check.build(Check.parseArgs("promtool", { "test", "rules", "tests/*.yml" }), lines)
		expect(glob.files[1].path).toBeNil()
	end)
end)

describe("promtool check argv", function()
	local function command(args: { string }): string?
		return Check.parseArgs("promtool", args).command
	end

	it("reads kingpin flags around the files", function()
		local inv =
			Check.parseArgs("promtool", { "check", "rules", "--lint", "none", "a.yml", "--lint-fatal", "b.yml" })
		expect(inv.command).toBe("check-rules")
		expect(inv.files).toEqual({ "a.yml", "b.yml" })
		local test = Check.parseArgs("promtool", { "test", "rules", "--run=group", "--junit", "out.xml", "t.yml" })
		expect(test.files).toEqual({ "t.yml" })
		-- Rules from standard input.
		expect(command({ "check", "rules" })).toBe("check-rules")
	end)

	it("leaves help and other check commands raw", function()
		expect(command({ "check", "rules", "--help" })).toBeNil()
		expect(command({ "check", "rules", "-h" })).toBeNil()
		expect(command({ "check", "web-config", "web.yml" })).toBeNil()
		expect(command({ "check", "healthy" })).toBeNil()
	end)

	it("stays raw when promtool printed nothing it recognizes", function()
		local state = Check.open(S.run("promtool", { "check", "rules", "a.yml" }))
		Check.line(state, "zsh: command not found: promtool")
		expect(Check.view(state, S.env())).toBeNil()
		Check.finish(state, 127)
		expect(Check.view(state, S.env())).toBeNil()
	end)
end)

describe("Check.fileHref", function()
	it("links absolute paths and paths relative to the shell's directory", function()
		expect(Check.fileHref("/etc/a b.yml", nil, 3, nil)).toBe("file:///etc/a%20b.yml#L3")
		expect(Check.fileHref("./rules/a.yml", "/home/me/repo/", 6, 15)).toBe("file:///home/me/repo/rules/a.yml#L6C15")
		expect(Check.fileHref("rules/a.yml", nil, nil, nil)).toBeNil()
		expect(Check.fileHref("~/a.yml", "/home/me", nil, nil)).toBeNil()
		expect(Check.fileHref("standard input", "/home/me", nil, nil)).toBeNil()
	end)
end)

return nil
