--!strict
-- `logcli query` is how people read Loki from a shell. The lens must show the
-- log lines logcli printed in each output mode (default, jsonl, raw) with the
-- same entries, labels and levels, keep the labels logcli factored out as
-- common, tone each line by its level, read metric queries (printed as JSON
-- whatever the mode) as series, and turn logcli's logged errors into an error
-- card naming the real cause. Anything it cannot read stays raw (view nil).
local Fixtures = require("../../lib/fixtures")
local Logcli = require("../../../plugin/lib/lens/logcli")
local Support = require("./support")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local DIR = "logcli/3.7.8/"
local SELECTOR = '{job="loggen"}'
local METRIC = 'sum by (level) (count_over_time({job="loggen"}[5m]))'

-- The argv scripts/fixtures/capture.sh ran for each capture (after `logcli`).
local ARGV: { [string]: { string } } = {
	query = { "query", "--quiet", "--limit=20", "--since=10m", SELECTOR },
	query_jsonl = { "query", "--quiet", "--limit=20", "--since=10m", "--output=jsonl", SELECTOR },
	query_raw = { "query", "--quiet", "--limit=20", "--since=10m", "--output=raw", '{app="payments"}' },
	query_metric = { "query", "--quiet", "--since=10m", METRIC },
	query_meta = { "query", "--limit=5", "--since=10m", SELECTOR },
	query_no_labels = { "query", "--quiet", "--limit=5", "--since=10m", "--no-labels", SELECTOR },
	query_parse_error = { "query", "--quiet", "--since=10m", '{job="loggen"' },
	query_refused = { "--addr=http://127.0.0.1:1", "query", "--quiet", "--since=10m", SELECTOR },
	labels = { "labels", "--quiet", "--since=10m" },
	series = { "series", "--quiet", "--since=10m", SELECTOR },
}

type Capture = { name: string, args: { string }, lines: { string }, status: number }

-- logcli logs its metadata (request URL, common labels) and errors before it
-- prints any entry, so stderr comes first in the stream.
local function capture(name: string): Capture
	local args = ARGV[name]
	assert(args, "no argv for " .. name)
	local c = Support.capture(DIR .. name .. ".txt", 0)
	expect(c.command).toBe("logcli " .. table.concat(args, " "))
	return { name = name, args = args, lines = c.lines, status = c.status }
end

local env = Support.env
local findAll = Support.findAll
local textOf = Support.textOf
local withAction = Support.withAction

local function run(args: { string }): any
	return Support.run("logcli", args)
end

local function lensFor(c: Capture): any
	local state = Logcli.open(run(c.args))
	for _, l in c.lines do
		Logcli.line(state, l)
	end
	Logcli.finish(state, c.status)
	return state
end

local function result(c: Capture): Logcli.Result
	return Logcli.build(Logcli.parseArgs("logcli", c.args), c.lines, json.decode)
end

local function levelCounts(r: Logcli.Result): { [string]: number }
	local out: { [string]: number } = {}
	for _, e in r.entries do
		local l = Logcli.level(e.labels, r.common, e.line)
		out[l] = (out[l] or 0) + 1
	end
	return out
end

local function find(r: Logcli.Result, needle: string): Logcli.Entry?
	for _, e in r.entries do
		if string.find(e.line, needle, 1, true) then
			return e
		end
	end
	return nil
end

-- The [[lenses]] entry plugin.toml declares for this lens.
local CLAIMS: { Support.LensClaim } = {
	{ id = "logcli", match = { "logcli query *", "logcli -* query *" } },
}

describe("logcli lens: fixtures and claims", function()
	it("has an argv for every recorded logcli capture", function()
		for _, path in Fixtures.list(DIR) do
			local name = string.match(path, "^" .. DIR .. "(.-)%.txt$")
			if name then
				expect(ARGV[name] ~= nil).toBe(true)
				capture(name)
			end
		end
	end)

	it("claims logcli query with flags anywhere, and not labels or series", function()
		for name, args in ARGV do
			local claimed = Support.claim(CLAIMS, "logcli", args)
			expect(claimed).toBe(if name == "labels" or name == "series" then nil else "logcli")
		end
		expect(Support.claim(CLAIMS, "logcli", { "-q", "-o", "jsonl", "query", SELECTOR })).toBe("logcli")
		expect(Support.claim(CLAIMS, "logcli", { "query" })).toBeNil()
		expect(Support.claim(CLAIMS, "logcli", { "instant-query", METRIC })).toBeNil()
	end)
end)

describe("logcli lens: arguments", function()
	local function parse(args: { string }): Logcli.Invocation
		return Logcli.parseArgs("logcli", args)
	end

	it("reads every recorded query and leaves labels and series raw", function()
		local q = parse(ARGV.query)
		expect(q.verb).toBe("query")
		expect(q.expr).toBe(SELECTOR)
		expect(q.metric).toBe(false)
		expect(q.output).toBe("default")
		expect(q.quiet).toBe(true)
		expect(q.limit).toBe(20)
		expect(q.since).toBe("10m")
		expect(parse(ARGV.query_jsonl).output).toBe("jsonl")
		expect(parse(ARGV.query_raw).output).toBe("raw")
		expect(parse(ARGV.query_metric).metric).toBe(true)
		expect(parse(ARGV.query_no_labels).no_labels).toBe(true)
		expect(parse(ARGV.query_refused).addr).toBe("http://127.0.0.1:1")
		expect(parse(ARGV.labels).verb).toBeNil()
		expect(parse(ARGV.series).verb).toBeNil()
	end)

	it("follows kingpin flag forms and logcli's default limit", function()
		expect(parse({ "-o", "jsonl", "query", SELECTOR }).output).toBe("jsonl")
		expect(parse({ "-ojsonl", "query", SELECTOR }).output).toBe("jsonl")
		expect(parse({ "-q", "query", "--limit", "7", SELECTOR }).limit).toBe(7)
		expect(parse({ "query", SELECTOR }).limit).toBe(30)
		expect(parse({ "query", "--limit=0", SELECTOR }).limit).toBeNil()
		expect(parse({ "query", "--from=2026-10-09T20:00:00Z", "--to", "2026-10-09T21:00:00Z", SELECTOR }).to).toBe(
			"2026-10-09T21:00:00Z"
		)
		expect(parse({ "--addr", "https://u:p@loki.example.com", "query", SELECTOR }).addr).toBe(
			"https://loki.example.com"
		)
	end)

	it("leaves tails, help and split queries raw", function()
		expect(parse({ "query", "--tail", SELECTOR }).verb).toBeNil()
		expect(parse({ "query", "-f", SELECTOR }).verb).toBeNil()
		expect(parse({ "query", "--help" }).verb).toBeNil()
		expect(parse({ "query", "{job=", '"x"}' }).verb).toBeNil()
		expect(parse({ "-o", "yaml", "query", SELECTOR }).verb).toBeNil()
		expect(parse({ "instant-query", METRIC }).verb).toBeNil()
		expect(Logcli.parseArgs("amtool", { "query", SELECTOR }).verb).toBeNil()
	end)

	it("never keeps credential flag values", function()
		local inv = parse({
			"--password=hunter2",
			"--bearer-token",
			"tok-secret",
			"--header=Authorization: Bearer abc",
			"query",
			SELECTOR,
		})
		expect(inv.verb).toBe("query")
		expect(inv.expr).toBe(SELECTOR)
		local seen = json.encode(inv)
		expect(Support.contains(seen, "hunter2")).toBe(false)
		expect(Support.contains(seen, "tok-secret")).toBe(false)
		expect(Support.contains(seen, "Bearer")).toBe(false)
	end)
end)

describe("logcli lens: log lines", function()
	it("reads the default and jsonl modes as the same entries", function()
		local default = result(capture("query"))
		local jsonl = result(capture("query_jsonl"))
		for _, r in { default, jsonl } do
			expect(r.kind).toBe("logs")
			expect(#r.entries).toBe(20)
			expect(r.unparsed).toBe(0)
		end
		-- Captured a second apart: the same log line reads the same in both.
		local needle = 'msg="charge failed" error="card declined" order_id=475'
		local d, j = find(default, needle), find(jsonl, needle)
		assert(d and j, "order 475 in both captures")
		expect(d.time).toBe("2026-10-09T20:31:59Z")
		expect(j.time).toBe(d.time)
		expect(j.line).toBe(d.line)
		expect(d.labels).toEqual({
			app = "payments",
			detected_level = "error",
			level = "error",
			service_name = "payments",
		})
		expect(j.labels).toEqual(d.labels)
		-- A JSON log line keeps its braces: the stream labels end before it.
		local warn = find(default, '"msg":"slow upstream"')
		assert(warn, "a JSON line")
		expect(string.sub(warn.line, 1, 1)).toBe("{")
		expect((warn.labels :: any).app).toBe("payments")
	end)

	it("tones every line by its level", function()
		expect(levelCounts(result(capture("query")))).toEqual({ debug = 4, error = 2, info = 10, warning = 4 })
		expect(levelCounts(result(capture("query_jsonl")))).toEqual({ debug = 4, error = 1, info = 11, warning = 4 })
		local view = Logcli.view(lensFor(capture("query")), env())
		local tones: { [string]: string } = {}
		for _, b in
			findAll(view, function(n: any): boolean
				return n.k == "badge"
			end)
		do
			tones[b.p.text] = b.p.tone
		end
		expect(tones.error).toBe("error")
		expect(tones.warning).toBe("warning")
		expect(tones.info).toBe("info")
		expect(tones.debug).toBe("muted")
		expect(tones["2 error"]).toBe("error")
		local text = textOf(view)
		expect(text).toContain("20 lines (limit reached)")
		expect(text).toContain("last 10m")
	end)

	it("reads levels from the line itself in raw mode", function()
		local r = result(capture("query_raw"))
		expect(r.kind).toBe("logs")
		expect(#r.entries).toBe(20)
		expect(r.entries[1].time).toBeNil()
		expect(r.entries[1].labels).toBeNil()
		expect(levelCounts(r)).toEqual({ error = 4, warning = 16 })
		local view = Logcli.view(lensFor(capture("query_raw")), env())
		expect(#findAll(view, function(n: any): boolean
			return n.k == "el" and n.p.text == "Time"
		end)).toBe(0)
	end)

	it("reads --no-labels lines as time and line", function()
		local r = result(capture("query_no_labels"))
		expect(#r.entries).toBe(5)
		expect(r.entries[1].labels).toBeNil()
		expect(r.entries[1].time).toBe("2026-10-09T21:33:45Z")
		expect(r.entries[2].line).toBe("GET /checkout status=200 bytes=655 duration_ms=527")
		expect(levelCounts(r)).toEqual({ info = 2, unknown = 2, error = 1 })
	end)

	it("keeps the common labels logcli logs and leaves them out of each stream", function()
		local r = result(capture("query_meta"))
		expect(r.kind).toBe("logs")
		expect(#r.entries).toBe(5)
		expect(r.unparsed).toBe(0)
		expect(r.common).toEqual({ env = "dev", job = "loggen" })
		local view = Logcli.view(lensFor(capture("query_meta")), env())
		local text = textOf(view)
		expect(text).toContain("Common labels")
		expect(text).toContain('{env="dev", job="loggen"}')
		expect(text).toContain("5 lines (limit reached)")
		-- The Level column carries the level labels; the stream cell's title
		-- keeps every label.
		expect(text).toContain("app=payments service_name=payments")
		local titled = findAll(view, function(n: any): boolean
			return n.p ~= nil and n.p.title == "app=payments detected_level=error level=error service_name=payments"
		end)
		expect(#titled).toBe(1)
	end)

	it("copies a line from its cell", function()
		local view = Logcli.view(lensFor(capture("query")), env())
		local copyable = findAll(view, withAction("copy"))
		-- The query plus every line.
		expect(#copyable).toBe(21)
	end)

	it("shows a timestamp-only line as an empty log line", function()
		local inv = Logcli.parseArgs("logcli", ARGV.query)
		local r = Logcli.build(inv, { '2026-10-09T20:31:59Z {app="x"}' }, json.decode)
		expect(r.entries[1].line).toBe("")
		local other = Logcli.build(inv, { "2026-10-09T20:31:59Z" }, json.decode)
		expect(other.entries[1].line).toBe("")
	end)
end)

describe("logcli lens: metric queries", function()
	it("reads the JSON matrix as one series per level", function()
		local r = result(capture("query_metric"))
		expect(r.kind).toBe("metric")
		local metric = r.metric :: Logcli.Metric
		expect(metric.kind).toBe("matrix")
		expect(#metric.series).toBe(4)
		local levels: { string } = {}
		for _, s in metric.series do
			table.insert(levels, s.labels.level)
			expect(#s.values).toBe(302)
		end
		expect(levels).toEqual({ "debug", "error", "info", "warn" })
		expect(metric.series[1].times[1]).toBe(1791577322000)
		expect(metric.series[1].values[1]).toBe(119)
	end)

	it("renders a spark grid and switches to a table with the whole choice in the action", function()
		local state = lensFor(capture("query_metric"))
		local view = Logcli.view(state, env())
		expect(textOf(view)).toContain("4 series")
		expect(#findAll(view, function(n: any): boolean
			return n.k == "chart"
		end)).toBe(4)
		expect(#findAll(view, withAction("v=table:1"))).toBe(1)
		local fresh = lensFor(capture("query_metric"))
		Logcli.event(fresh, { ev = "action", act = "v", value = "table:1" }, env())
		local tableView = Logcli.view(fresh, env())
		expect(#findAll(tableView, function(n: any): boolean
			return n.k == "chart"
		end)).toBe(0)
	end)

	it("reads the JSON when zsh's end-of-line mark follows the closing bracket", function()
		-- logcli prints the JSON without a final newline; in a Tern zsh pane
		-- the last captured line is `]%` (seen live), `]#` for root.
		local c = capture("query_metric")
		local inv = Logcli.parseArgs("logcli", c.args)
		expect(c.lines[#c.lines]).toBe("]")
		for _, tail in { "]%", "]#" } do
			local lines = table.clone(c.lines)
			lines[#lines] = tail
			local r = Logcli.build(inv, lines, json.decode)
			expect(r.kind).toBe("metric")
			expect(r.unparsed).toBe(0)
			expect(#(r.metric :: Logcli.Metric).series).toBe(4)
		end
		-- An empty result prints `[]`.
		local empty = Logcli.build(inv, { "[]%" }, json.decode)
		expect(empty.kind).toBe("empty")
		expect(empty.unparsed).toBe(0)
		expect(textOf(Logcli.render(inv, empty, { table = false, all = false }))).toContain("No data")
	end)

	it("skips logcli's stderr metadata around the JSON", function()
		local c = capture("query_metric")
		local lines = table.clone(c.lines)
		table.insert(
			lines,
			1,
			"2026/10/09 21:33:07 http://loki:3100/loki/api/v1/query_range?direction=BACKWARD&limit=30&query=x"
		)
		local inv = Logcli.parseArgs("logcli", { "query", "--since=10m", METRIC })
		local r = Logcli.build(inv, lines, json.decode)
		expect(r.kind).toBe("metric")
		expect(r.unparsed).toBe(0)
	end)
end)

describe("logcli lens: errors", function()
	it("names the server's parse error, not the retry summary", function()
		local c = capture("query_parse_error")
		expect(c.status).toBe(1)
		local r = result(c)
		expect(r.kind).toBe("error")
		expect(r.errors[1].kind).toBe("query")
		expect(r.errors[1].message).toBe(
			"parse error at line 1, col 14: syntax error: unexpected $end, expecting } or ,"
		)
		expect(#r.errors).toBe(1)
		local view = Logcli.view(lensFor(c), env())
		expect(view and view.p and view.p.tone).toBe("error")
		expect(textOf(view)).toContain("Query failed")
	end)

	it("shows a refused connection as Loki unreachable", function()
		local c = capture("query_refused")
		local r = result(c)
		expect(r.kind).toBe("error")
		expect(r.errors[1].kind).toBe("network")
		local text = textOf(Logcli.view(lensFor(c), env()))
		expect(text).toContain("Cannot reach Loki")
		expect(text).toContain("connect: connection refused")
		expect(text).toContain("Loki: http://127.0.0.1:1")
	end)

	it("shows kingpin's usage errors", function()
		local inv = Logcli.parseArgs("logcli", ARGV.query)
		local r = Logcli.build(inv, { "logcli: error: unknown long flag '--nope', try --help" }, json.decode)
		expect(r.errors[1].kind).toBe("usage")
		expect(textOf(Logcli.render(inv, r, { table = false, all = false }))).toContain("logcli rejected the arguments")
	end)

	it("stays raw for output it cannot read", function()
		local inv = Logcli.parseArgs("logcli", ARGV.query)
		local r = Logcli.build(inv, { "not a log line" }, json.decode)
		expect(r.kind).toBe("unreadable")
		expect(Logcli.render(inv, r, { table = false, all = false })).toBeNil()
	end)
end)

describe("logcli lens: lifecycle", function()
	it("shows raw output while logcli runs, for unread commands and past the cap", function()
		local c = capture("query")
		local state = Logcli.open(run(c.args))
		for _, l in c.lines do
			Logcli.line(state, l)
		end
		expect(Logcli.view(state, env())).toBeNil()
		Logcli.finish(state, 0)
		expect(Logcli.view(state, env()) ~= nil).toBe(true)
		expect(Logcli.view(lensFor(capture("labels")), env())).toBeNil()
		expect(Logcli.view(lensFor(capture("series")), env())).toBeNil()

		local big = Logcli.open(run(c.args))
		for _ = 1, Logcli.MAX_LINES + 1 do
			Logcli.line(big, c.lines[1])
		end
		Logcli.finish(big, 0)
		expect(Logcli.view(big, env())).toBeNil()
	end)

	it("caps rows behind Show all, carried whole in the action", function()
		local c = capture("query")
		local lines: { string } = {}
		for _ = 1, 3 do
			for _, l in c.lines do
				table.insert(lines, l)
			end
		end
		local args = { "query", "--quiet", "--limit=0", SELECTOR }
		local state = lensFor({ name = c.name, args = args, lines = lines, status = 0 })
		local view = Logcli.view(state, env())
		expect(textOf(view)).toContain("10 more")
		expect(#findAll(view, withAction("v=all:1"))).toBe(1)
		Logcli.event(state, { ev = "action", act = "v", value = "all:1" }, env())
		local all = Logcli.view(state, env())
		expect(#findAll(all, withAction("copy"))).toBe(61)
	end)
end)

return nil
