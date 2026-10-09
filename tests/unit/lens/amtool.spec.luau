--!strict
-- `amtool alert query` and `amtool silence query` are how people look at an
-- Alertmanager from a shell. The lens must show what amtool printed in every
-- output format (amtool's config file can change the default, so the format
-- is read from the output), agree across formats on the same alerts and
-- silences, tone alerts by severity and state, and open the alerts inbox for
-- the context that serves the same Alertmanager. Anything it cannot read
-- faithfully stays raw (view nil), and an error must surface as an error.
local Amtool = require("../../../plugin/lib/lens/amtool")
local Fixtures = require("../../lib/fixtures")
local Group = require("../../../plugin/lib/alerts/group")
local Scheme = require("../../../plugin/lib/links/scheme")
local Validate = require("../../../plugin/lib/config/validate")
local Support = require("./support")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local DIR = "amtool/0.34.1/"
local AM = "--alertmanager.url=http://alertmanager:9093"

-- The argv scripts/fixtures/capture.sh ran for each capture (after `amtool`).
local ARGV: { [string]: { string } } = {
	alert_query = { AM, "alert", "query" },
	alert_query_silenced = { AM, "alert", "query", "--silenced" },
	alert_query_extended = { AM, "-o", "extended", "alert", "query" },
	alert_query_json = { AM, "-o", "json", "alert", "query" },
	alert_query_matcher = { AM, "alert", "query", "severity=warning" },
	alert_query_bad_matcher = { AM, "alert", "query", "foo=~(" },
	amtool_refused = { "--alertmanager.url=http://127.0.0.1:1", "alert", "query" },
	silence_query = { AM, "silence", "query" },
	silence_query_extended = { AM, "-o", "extended", "silence", "query" },
	silence_query_json = { AM, "-o", "json", "silence", "query" },
	silence_query_quiet = { AM, "silence", "query", "-q" },
	check_config = { "check-config", "/etc/alertmanager/alertmanager.yml" },
}

type Capture = { name: string, args: { string }, lines: { string }, status: number }

local function capture(name: string): Capture
	local args = ARGV[name]
	assert(args, "no argv for " .. name)
	local c = Support.capture(DIR .. name .. ".txt")
	expect(c.command).toBe("amtool " .. table.concat(args, " "))
	return { name = name, args = args, lines = c.lines, status = c.status }
end

local function cfg(text: string): any
	local c, problems = Validate.parseFile(text, json.decode)
	assert(c, problems[1] and Validate.format(problems[1]))
	return c
end

local LAB = cfg([[{"contexts": {
	"am": {"alertmanager": {"url": "http://alertmanager:9093"}},
	"graf": {"grafana": {"url": "http://localhost:3000"}},
	"sub": {"grafana": {"url": "https://ops.example.com", "path_prefix": "/grafana"}}}}]])

local env = Support.env
local findAll = Support.findAll
local textOf = Support.textOf
local withAction = Support.withAction

local function run(args: { string }): any
	return Support.run("amtool", args)
end

local function lensFor(c: Capture): any
	local state = Amtool.open(run(c.args))
	for _, l in c.lines do
		Amtool.line(state, l)
	end
	Amtool.finish(state, c.status)
	return state
end

local function result(c: Capture): Amtool.Result
	return Amtool.build(Amtool.parseArgs("amtool", c.args), c.lines, json.decode)
end

local function badges(node: any): { [string]: string }
	local out: { [string]: string } = {}
	for _, b in findAll(node, Support.ofKind("badge")) do
		out[b.p.text] = b.p.tone
	end
	return out
end

local function byName(alerts: { Amtool.Alert }): { [string]: Amtool.Alert }
	local out: { [string]: Amtool.Alert } = {}
	for _, a in alerts do
		out[a.name] = a
	end
	return out
end

local function sortedKeys(map: { [string]: any }): { string }
	local keys = {}
	for k in map do
		table.insert(keys, k)
	end
	table.sort(keys)
	return keys
end

local function linkParams(target: string): { [string]: string }
	local link, err = Scheme.decode(target)
	assert(link, err and err.message)
	expect(link.action).toBe("alerts")
	return link.params
end

-- The [[lenses]] entry plugin.toml declares for this lens.
local CLAIMS: { Support.LensClaim } = {
	{
		id = "amtool",
		match = {
			"amtool alert",
			"amtool alert *",
			"amtool silence",
			"amtool silence *",
			"amtool -* alert",
			"amtool -* alert *",
			"amtool -* silence",
			"amtool -* silence *",
		},
	},
}

describe("amtool lens: fixtures and claims", function()
	it("has an argv for every recorded amtool capture", function()
		for _, path in Fixtures.list(DIR) do
			local name = string.match(path, "^" .. DIR .. "(.-)%.txt$")
			if name then
				expect(ARGV[name] ~= nil).toBe(true)
				capture(name)
			end
		end
	end)

	it("claims every alert and silence query form, and nothing it never renders", function()
		for name, args in ARGV do
			local claimed = Support.claim(CLAIMS, "amtool", args)
			expect(claimed).toBe(if name == "check_config" then nil else "amtool")
		end
		expect(Support.claim(CLAIMS, "amtool", { "alert" })).toBe("amtool")
		expect(Support.claim(CLAIMS, "amtool", { "-o", "json", "silence" })).toBe("amtool")
		expect(Support.claim(CLAIMS, "amtool", {})).toBeNil()
		expect(Support.claim(CLAIMS, "amtool", { "config", "routes" })).toBeNil()
		expect(Support.claim(CLAIMS, "amtool", { "template", "render" })).toBeNil()
	end)
end)

describe("amtool lens: arguments", function()
	local function parse(args: { string }): Amtool.Invocation
		return Amtool.parseArgs("amtool", args)
	end

	it("reads every recorded query invocation and leaves check-config raw", function()
		expect(parse(ARGV.alert_query).verb).toBe("alerts")
		expect(parse(ARGV.alert_query).url).toBe("http://alertmanager:9093")
		expect(parse(ARGV.alert_query_extended).output).toBe("extended")
		expect(parse(ARGV.alert_query_json).output).toBe("json")
		expect(parse(ARGV.alert_query_silenced).states).toEqual({ "silenced" })
		expect(parse(ARGV.alert_query_matcher).matchers).toEqual({ "severity=warning" })
		expect(parse(ARGV.silence_query).verb).toBe("silences")
		expect(parse(ARGV.silence_query_quiet).quiet).toBe(true)
		expect(parse(ARGV.check_config).verb).toBeNil()
	end)

	it("takes `alert` and `silence` alone as their default query command", function()
		local inv = parse({ AM, "alert", "severity=warning" })
		expect(inv.verb).toBe("alerts")
		expect(inv.matchers).toEqual({ "severity=warning" })
		expect(parse({ AM, "silence" }).verb).toBe("silences")
	end)

	it("reads a first argument without an operator as the alertname, as amtool does", function()
		expect(parse({ AM, "alert", "query", "TernTargetDown", "job=down" }).matchers).toEqual({
			'alertname="TernTargetDown"',
			"job=down",
		})
		expect(parse({ AM, "silence", "query", 'Odd"Name' }).matchers).toEqual({ 'alertname="Odd\\"Name"' })
	end)

	it("follows kingpin flag forms", function()
		expect(parse({ "-ojson", "alert", "query", AM }).output).toBe("json")
		expect(parse({ "--output", "extended", "alert" }).output).toBe("extended")
		expect(parse({ "alert", "query", "-sa", AM }).states).toEqual({ "silenced", "active" })
		expect(parse({ "alert", "query", "-r", "team-.*" }).receiver).toBe("team-.*")
		local s = parse({ "silence", "query", "--expired", "--within", "2h", "--created-by=me" })
		expect(s.expired).toBe(true)
		expect(s.within).toBe("2h")
		expect(s.created_by).toBe("me")
		expect(parse({ "alert", "query", "--", "-odd=1" }).matchers).toEqual({ "-odd=1" })
	end)

	it("leaves help, other subcommands and unknown formats raw", function()
		expect(parse({ "alert", "query", "--help" }).verb).toBeNil()
		expect(parse({ "-h", "alert" }).verb).toBeNil()
		expect(parse({ "alert", "add", "foo" }).verb).toBeNil()
		expect(parse({ "silence", "expire", "abc" }).verb).toBeNil()
		expect(parse({ "silence", "add", "foo=bar", "-c", "x" }).verb).toBeNil()
		expect(parse({ "-o", "yaml", "alert" }).verb).toBeNil()
		expect(parse({ "config", "show" }).verb).toBeNil()
		expect(Amtool.parseArgs("promtool", { "alert" }).verb).toBeNil()
	end)

	it("never keeps credentials from the Alertmanager URL", function()
		local inv = parse({ "--alertmanager.url=https://admin:hunter2@am.example.com/sub", "alert" })
		expect(inv.url).toBe("https://am.example.com/sub")
	end)
end)

describe("amtool lens: alerts", function()
	it("reads the same alerts from the simple, extended and json formats", function()
		local simple = result(capture("alert_query"))
		local extended = result(capture("alert_query_extended"))
		local fromJson = result(capture("alert_query_json"))
		expect(simple.format).toBe("simple")
		expect(extended.format).toBe("extended")
		expect(fromJson.format).toBe("json")
		local names = { "TernGrafanaAlwaysFiring", "TernGrafanaTargetDown", "TernTargetDown" }
		for _, r in { simple, extended, fromJson } do
			expect(r.kind).toBe("alerts")
			expect(r.unparsed).toBe(0)
			expect(sortedKeys(byName(r.alerts))).toEqual(names)
		end
		local s, e, j = byName(simple.alerts), byName(extended.alerts), byName(fromJson.alerts)
		for _, name in names do
			expect(e[name].starts).toBe(s[name].starts)
			expect(j[name].starts).toBe(s[name].starts)
			expect(e[name].summary).toBe(s[name].summary)
			expect(j[name].summary).toBe(s[name].summary)
			expect(s[name].state).toBe("active")
			expect(j[name].labels).toEqual(e[name].labels)
			expect(j[name].annotations).toEqual(e[name].annotations)
			expect(j[name].severity).toBe(e[name].severity)
		end
		expect(s.TernTargetDown.summary).toBe("Target node-exporter:9999 of job down is down")
		expect(s.TernTargetDown.starts).toBe("2026-10-09 20:16:34 UTC")
		expect(e.TernGrafanaAlwaysFiring.severity).toBe("critical")
		expect(e.TernTargetDown.severity).toBe("warning")
		-- The simple format prints no labels, so there is no severity to guess.
		expect(s.TernTargetDown.severity).toBeNil()
	end)

	it("reads extended labels and annotations whose values hold unescaped quotes", function()
		local e = byName(result(capture("alert_query_extended")).alerts)
		local a = e.TernGrafanaAlwaysFiring
		local annotations = a.annotations :: { [string]: string }
		expect(annotations.__values__).toBe('{"A":1,"C":1}')
		expect(annotations.description).toBe("Fires on every evaluation so Grafana alert views always have data.")
		expect(annotations.runbook_url).toBe("https://example.com/runbooks/tern-grafana-always-firing")
		expect((a.labels :: { [string]: string }).grafana_folder).toBe("Tern Alerts")
		expect(a.generator).toBe("http://127.0.0.1:3011/alerting/grafana/tern-g-firing/view")
		expect(e.TernTargetDown.ends).toBe("2026-10-09 20:35:44 UTC")
	end)

	it("tones by severity, and mutes alerts a silence suppresses", function()
		local view = Amtool.view(lensFor(capture("alert_query_extended")), env(LAB))
		local tones = badges(view)
		expect(tones.critical).toBe("error")
		expect(tones.warning).toBe("warning")
		expect(tones.active).toBe("error")
		local silenced = result(capture("alert_query_silenced"))
		expect(silenced.alerts[1].state).toBe("suppressed")
		expect(Amtool.stateTone(silenced.alerts[1])).toBe("muted")
		local text = textOf(Amtool.view(lensFor(capture("alert_query_silenced")), env(LAB)))
		expect(text).toContain("TernAlwaysFiring")
		expect(text).toContain("silenced")
	end)

	it("says why the simple format has no severity column", function()
		local text = textOf(Amtool.view(lensFor(capture("alert_query")), env(LAB)))
		expect(text).toContain("3 alerts")
		expect(text).toContain("Severity and labels need -o extended or -o json")
		expect(text).toContain("Target node-exporter:9999 of job down is down")
	end)

	it("filters by the matchers amtool was given", function()
		local r = result(capture("alert_query_matcher"))
		expect(sortedKeys(byName(r.alerts))).toEqual({ "TernGrafanaTargetDown", "TernTargetDown" })
		expect(textOf(Amtool.view(lensFor(capture("alert_query_matcher")), env(LAB)))).toContain("severity=warning")
	end)

	it("shows an empty table as no alerts, not raw", function()
		local r = result(capture("alert_query_bad_matcher"))
		expect(r.kind).toBe("alerts")
		expect(#r.alerts).toBe(0)
		local view = Amtool.view(lensFor(capture("alert_query_bad_matcher")), env(LAB))
		expect(textOf(view)).toContain("No alerts")
	end)

	it("cuts rows at the header's rune columns", function()
		local name = "Störung"
		local header = "Alertname  Starts At                Summary  State"
		-- Tabwriter pads by runes: "Störung" is 7 runes, 8 bytes.
		local pad = string.rep(" ", 11 - (utf8.len(name) :: number))
		local row = name .. pad .. "2026-10-09 20:16:00 UTC  " .. "über     active"
		local inv = Amtool.parseArgs("amtool", { "alert" })
		local r = Amtool.build(inv, { header, row }, json.decode)
		expect(r.unparsed).toBe(0)
		expect(r.alerts[1].name).toBe(name)
		expect(r.alerts[1].summary).toBe("über")
		expect(r.alerts[1].state).toBe("active")
	end)

	it("keeps rows a newline in a summary broke out of the table, and counts them", function()
		local c = capture("alert_query")
		local lines = table.clone(c.lines)
		table.insert(lines, 3, "second line of a summary")
		local inv = Amtool.parseArgs("amtool", c.args)
		local r = Amtool.build(inv, lines, json.decode)
		expect(#r.alerts).toBe(3)
		expect(r.unparsed).toBe(1)
		local view = Amtool.render(inv, r, Amtool.defaultView(), LAB)
		expect(textOf(view)).toContain("1 line not shown (Raw shows everything)")
	end)
end)

describe("amtool lens: silences", function()
	it("reads the same silence from the simple and json formats", function()
		local simple = result(capture("silence_query"))
		local fromJson = result(capture("silence_query_json"))
		expect(simple.format).toBe("simple")
		expect(fromJson.format).toBe("json")
		for _, r in { simple, fromJson } do
			expect(r.kind).toBe("silences")
			expect(#r.silences).toBe(1)
			local s = r.silences[1]
			expect(s.id).toBe("892a1c9d-e05b-4e32-8dad-b5b3860bc8c3")
			expect(s.matchers).toBe('alertname="TernAlwaysFiring"')
			expect(s.ends).toBe("2026-10-09 21:31:38 UTC")
			expect(s.created_by).toBe("tern-grafana capture")
			expect(s.comment).toBe("Fixture capture silence")
		end
		expect(fromJson.silences[1].state).toBe("active")
		expect(simple.silences[1].state).toBeNil()
	end)

	it("reads the extended format and the bare IDs of -q for the same silence", function()
		local extended = result(capture("silence_query_extended"))
		local quiet = result(capture("silence_query_quiet"))
		expect(extended.format).toBe("extended")
		local s = extended.silences[1]
		expect(s.id).toBe("f147bbd4-b127-49b9-af95-804199a45837")
		expect(s.matchers).toBe('{alertname="TernAlwaysFiring"}')
		expect(s.starts).toBe("2026-10-09 21:33:21 UTC")
		expect(s.updated).toBe("2026-10-09 21:33:21 UTC")
		expect(quiet.kind).toBe("ids")
		expect(quiet.ids).toEqual({ s.id })
	end)

	it("copies a silence's full ID from its row", function()
		local state = lensFor(capture("silence_query"))
		local view = Amtool.view(state, env(LAB))
		local rows = findAll(view, withAction("id=1"))
		expect(#rows).toBe(1)
		local effects = Amtool.event(state, { ev = "action", act = "id", value = "1" }, env(LAB))
		expect(effects[1]).toEqual({ kind = "copy", text = "892a1c9d-e05b-4e32-8dad-b5b3860bc8c3" })
		local quiet = lensFor(capture("silence_query_quiet"))
		Amtool.view(quiet, env(LAB))
		local copied = Amtool.event(quiet, { ev = "action", act = "id", value = "1" }, env(LAB))
		expect(copied[1]).toEqual({ kind = "copy", text = "f147bbd4-b127-49b9-af95-804199a45837" })
	end)

	it("tones json silence states", function()
		local tones = badges(Amtool.view(lensFor(capture("silence_query_json")), env(LAB)))
		expect(tones.active).toBe("accent")
	end)
end)

describe("amtool lens: errors", function()
	it("shows a refused connection as an error card naming the Alertmanager", function()
		local c = capture("amtool_refused")
		expect(c.status).toBe(1)
		local r = result(c)
		expect(r.kind).toBe("error")
		expect(r.errors[1].kind).toBe("network")
		local view = Amtool.view(lensFor(c), env(LAB))
		expect(view and view.p and view.p.tone).toBe("error")
		local text = textOf(view)
		expect(text).toContain("Cannot reach Alertmanager")
		expect(text).toContain("connect: connection refused")
		expect(text).toContain("http://127.0.0.1:1")
	end)

	it("classifies usage errors", function()
		local inv = Amtool.parseArgs("amtool", { "alert" })
		local r = Amtool.build(inv, { "amtool: error: required flag --alertmanager.url not provided" }, json.decode)
		expect(r.errors[1].kind).toBe("usage")
		expect(textOf(Amtool.render(inv, r, Amtool.defaultView(), nil))).toContain("amtool rejected the arguments")
	end)

	it("keeps the version mismatch warning beside the data", function()
		local c = capture("alert_query")
		local lines = table.clone(c.lines)
		table.insert(lines, 1, "Warning: amtool version (0.34.1) and alertmanager version (0.28.0) are different.")
		local inv = Amtool.parseArgs("amtool", c.args)
		local r = Amtool.build(inv, lines, json.decode)
		expect(#r.alerts).toBe(3)
		expect(textOf(Amtool.render(inv, r, Amtool.defaultView(), LAB))).toContain("are different")
	end)

	it("stays raw for output it cannot read", function()
		local inv = Amtool.parseArgs("amtool", { "alert" })
		local r = Amtool.build(inv, { "something else entirely" }, json.decode)
		expect(r.kind).toBe("unreadable")
		expect(Amtool.render(inv, r, Amtool.defaultView(), LAB)).toBeNil()
	end)
end)

describe("amtool lens: alerts inbox", function()
	it("opens the inbox of the context serving that Alertmanager, filtered like the query", function()
		local state = lensFor(capture("alert_query_matcher"))
		local view = Amtool.view(state, env(LAB))
		expect(#findAll(view, withAction("inbox"))).toBe(1)
		local effects = Amtool.event(state, { ev = "action", act = "inbox" }, env(LAB))
		expect(effects[1].kind).toBe("open")
		local params = linkParams((effects[1] :: any).target)
		expect(params.context).toBe("am")
		expect(params.filter).toBe("severity=warning")
		-- The inbox accepts the filter it is handed.
		expect(Group.parseFilter(params.filter) ~= nil).toBe(true)
	end)

	it("opens one alert's row filtered to its alertname", function()
		local state = lensFor(capture("alert_query"))
		local r = result(capture("alert_query"))
		Amtool.view(state, env(LAB))
		local effects = Amtool.event(state, { ev = "action", act = "inbox", value = "3" }, env(LAB))
		local params = linkParams((effects[1] :: any).target)
		expect(params.filter).toBe('alertname="' .. r.alerts[3].name .. '"')
		local filter = Group.parseFilter(params.filter)
		expect(filter and filter.matchers[1].value).toBe(r.alerts[3].name)
	end)

	it("maps Grafana's Alertmanager URLs to the Grafana context", function()
		expect(Amtool.contextFor("http://localhost:3000/api/alertmanager/grafana", LAB)).toBe("graf")
		expect(Amtool.contextFor("https://ops.example.com/grafana/api/alertmanager/am-uid", LAB)).toBe("sub")
		expect(Amtool.contextFor("http://alertmanager:9093/", LAB)).toBe("am")
		expect(Amtool.contextFor("http://alertmanager:9094", LAB)).toBeNil()
		expect(Amtool.contextFor("http://localhost:3000/api/alertmanager", LAB)).toBeNil()
	end)

	it("falls back to the default inbox when no context serves the URL", function()
		local c = capture("alert_query")
		local inv = Amtool.parseArgs("amtool", { "--alertmanager.url=http://elsewhere:9093", "alert" })
		local r = result(c)
		local view = Amtool.render(inv, r, Amtool.defaultView(), LAB)
		expect(textOf(view)).toContain("opens the default context")
		local params = linkParams(Amtool.inboxLink(inv, LAB, nil) :: string)
		expect(params.context).toBeNil()
	end)
end)

describe("amtool lens: lifecycle", function()
	it("shows raw output while amtool runs and for captures past the cap", function()
		local c = capture("alert_query")
		local state = Amtool.open(run(c.args))
		for _, l in c.lines do
			Amtool.line(state, l)
		end
		expect(Amtool.view(state, env(LAB))).toBeNil()
		Amtool.finish(state, c.status)
		expect(Amtool.view(state, env(LAB)) ~= nil).toBe(true)

		local big = Amtool.open(run(c.args))
		for _ = 1, Amtool.MAX_LINES + 1 do
			Amtool.line(big, c.lines[2])
		end
		Amtool.finish(big, 0)
		expect(Amtool.view(big, env(LAB))).toBeNil()
	end)

	it("carries Show all in the action so a rehydrated lens lands on it", function()
		local c = capture("alert_query")
		local lines = { c.lines[1] }
		for _ = 1, Amtool.MAX_ROWS + 5 do
			table.insert(lines, c.lines[2])
		end
		local state = lensFor({ name = c.name, args = c.args, lines = lines, status = 0 })
		local view = Amtool.view(state, env(LAB))
		local more = findAll(view, withAction("v=all:1"))
		expect(#more).toBe(1)
		expect(textOf(view)).toContain("5 more")
		-- A fresh state (after a reload) gets the same click.
		local fresh = lensFor({ name = c.name, args = c.args, lines = lines, status = 0 })
		Amtool.event(fresh, { ev = "action", act = "v", value = "all:1" }, env(LAB))
		local all = Amtool.view(fresh, env(LAB))
		expect(#findAll(all, withAction("inbox=" .. (Amtool.MAX_ROWS + 5)))).toBe(1)
	end)
end)

return nil
