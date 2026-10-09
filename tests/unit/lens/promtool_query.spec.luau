--!strict
-- `promtool query` is how people check PromQL from a shell; the lens must show
-- exactly what promtool printed, never a guess. Both promtool generations
-- (Prometheus 2.53 LTS and 3.x) print the same shapes, so every recorded
-- capture is read in both output formats and the text and JSON readings must
-- agree sample for sample. Anything the lens cannot read faithfully stays raw
-- (view nil), and an error must surface as an error, not as "no data".
local Fixtures = require("../../lib/fixtures")
local Promtool = require("../../../plugin/lib/lens/promtool_query")
local Scheme = require("../../../plugin/lib/links/scheme")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local VERSIONS = { "2.53.5", "3.15.0" }
local SERVER: { [string]: string } = { ["2.53.5"] = "http://prometheus2:9090", ["3.15.0"] = "http://prometheus3:9090" }
local RANGE_START, RANGE_END = "1791577598", "1791577898"
local JOBS = { "alertmanager", "down", "loki", "node", "prometheus", "tempo" }

-- The argv scripts/fixtures/capture.sh ran for each capture (after `promtool`).
local function argvFor(name: string, server: string): { string }?
	local byName: { [string]: { string } } = {
		query_instant = { "query", "instant", server, "sum by (job) (up)" },
		query_instant_json = { "query", "instant", "-o", "json", server, "sum by (job) (up)" },
		query_range = {
			"query",
			"range",
			"--start=" .. RANGE_START,
			"--end=" .. RANGE_END,
			"--step=60s",
			server,
			"sum by (job) (up)",
		},
		query_range_json = {
			"query",
			"range",
			"-o",
			"json",
			"--start=" .. RANGE_START,
			"--end=" .. RANGE_END,
			"--step=60s",
			server,
			"sum by (job) (up)",
		},
		query_error = { "query", "instant", server, "sum(up" },
		query_refused = { "query", "instant", "http://127.0.0.1:1", "up" },
		query_instant_vector_metric = { "query", "instant", server, "up" },
		query_scalar = { "query", "instant", server, "scalar(sum(up))" },
		query_series = { "query", "series", "--match=up", server },
		query_series_json = { "query", "series", "-o", "json", "--match=up", server },
		query_labels = { "query", "labels", server, "job" },
		query_labels_json = { "query", "labels", "-o", "json", server, "job" },
	}
	return byName[name]
end

type Capture = { name: string, args: { string }, lines: { string }, status: number }

local manifest: { [string]: { command: string, status: number } } = {}
for line in string.gmatch(Fixtures.read("MANIFEST.tsv"), "[^\n]+") do
	local path, method, command, status = string.match(line, "^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)")
	if path and method == "CLI" and command and status then
		manifest[path] = { command = command, status = tonumber(status) :: number }
	end
end

-- Tern feeds stdout and stderr as one stream with trailing blanks trimmed.
local function outputLines(path: string): { string }
	local lines: { string } = {}
	local stderr = string.gsub(path, "%.txt$", ".stderr")
	for _, p in { path, stderr } do
		if Fixtures.has(p) then
			for raw in string.gmatch(Fixtures.read(p), "([^\n]*)\n?") do
				local trimmed = string.gsub(raw, "%s+$", "")
				table.insert(lines, trimmed)
			end
		end
	end
	while #lines > 0 and lines[#lines] == "" do
		table.remove(lines)
	end
	return lines
end

local function capture(version: string, name: string): Capture
	local path = "promtool/" .. version .. "/" .. name .. ".txt"
	local args = argvFor(name, SERVER[version])
	assert(args, "no argv for " .. path)
	local entry = manifest[path]
	assert(entry, "no MANIFEST row for " .. path)
	return { name = name, args = args, lines = outputLines(path), status = entry.status }
end

local function cfg(text: string): any
	local c, problems = Validate.parseFile(text, json.decode)
	assert(c, problems[1] and Validate.format(problems[1]))
	return c
end

local LAB = cfg([[{"contexts": {
	"lab2": {"prometheus": {"url": "http://prometheus2:9090"}},
	"lab3": {"prometheus": {"url": "http://prometheus3:9090/"}},
	"graf": {"grafana": {"url": "http://localhost:3000", "datasources": {"prometheus": "prom3"}}},
	"sub": {"prometheus": {"url": "https://ops.example.com", "path_prefix": "/prometheus"}}}}]])

local function env(config: any?): any
	return { now_ms = 0, decode = json.decode, encode = json.encode, null = json.null, config = config }
end

local function run(args: { string }): any
	return { line = "promtool " .. table.concat(args, " "), typed = "", program = "promtool", args = args }
end

local function lensFor(c: Capture): any
	local state = Promtool.open(run(c.args))
	for _, l in c.lines do
		Promtool.line(state, l)
	end
	Promtool.finish(state, c.status)
	return state
end

local function result(c: Capture): Promtool.Result
	local inv = Promtool.parseArgs("promtool", c.args)
	return Promtool.build(inv, c.lines, json.decode)
end

-- Every node in a view tree matching `pred`.
local function findAll(node: any, pred: (any) -> boolean, out: { any }?): { any }
	local acc = out or {}
	if type(node) ~= "table" then
		return acc
	end
	if pred(node) then
		table.insert(acc, node)
	end
	for _, child in node.c or {} do
		findAll(child, pred, acc)
	end
	return acc
end

local function kind(k: string): (any) -> boolean
	return function(n: any): boolean
		return n.k == k
	end
end

local function always(_: any): boolean
	return true
end

local function textOf(node: any): string
	local parts: { string } = {}
	for _, n in findAll(node, always) do
		local p = n.p or {}
		if type(p.text) == "string" then
			table.insert(parts, p.text)
		end
		for _, s in p.spans or {} do
			table.insert(parts, s.t)
		end
		if p.head then
			for _, s in p.head do
				table.insert(parts, s.t)
			end
		end
		for _, item in p.items or {} do
			for _, s in item.k do
				table.insert(parts, s.t)
			end
			for _, s in item.v do
				table.insert(parts, s.t)
			end
		end
	end
	return table.concat(parts, "|")
end

local function withAction(act: string): (any) -> boolean
	return function(n: any): boolean
		return n.p ~= nil and n.p.actions ~= nil and n.p.actions.click == act
	end
end

-- Series keyed by `job` (or the full name), each as its times and values.
local function byName(series: { Promtool.Series }): { [string]: Promtool.Series }
	local out: { [string]: Promtool.Series } = {}
	for _, s in series do
		out[s.labels.job or Promtool.seriesName(s.labels)] = s
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

describe("promtool query fixtures", function()
	it("cover every recorded promtool query capture with the argv capture.sh ran", function()
		for _, version in VERSIONS do
			for _, path in Fixtures.list("promtool/" .. version .. "/query_") do
				local name = string.match(path, "/(query_[%w_]+)%.txt$")
				if name then
					local args = argvFor(name, SERVER[version])
					expect(args ~= nil).toBe(true)
					-- The manifest records the argv space-joined.
					expect(manifest[path].command).toBe("promtool " .. table.concat(args :: { string }, " "))
				end
			end
		end
	end)

	for _, version in VERSIONS do
		describe(version, function()
			it("reads the instant vector in both formats, one row per job, same samples", function()
				local text = result(capture(version, "query_instant"))
				local js = result(capture(version, "query_instant_json"))
				for _, r in { text, js } do
					expect(r.kind).toBe("vector")
					expect(r.unparsed).toBe(0)
					expect(sortedKeys(byName(r.series))).toEqual(JOBS)
					expect(byName(r.series).down.values).toEqual({ 0 })
					expect(byName(r.series).node.values).toEqual({ 1 })
					-- One evaluation time for the whole vector, in epoch ms.
					local at = r.series[1].times[1]
					expect(at > 1.7e12).toBe(true)
					for _, s in r.series do
						expect(s.times).toEqual({ at })
					end
				end
			end)

			it("reads the range matrix identically from text and JSON", function()
				local text = result(capture(version, "query_range"))
				local js = result(capture(version, "query_range_json"))
				expect(text.kind).toBe("matrix")
				expect(js.kind).toBe("matrix")
				expect(text.series).toEqual(js.series)
				local start = (tonumber(RANGE_START) :: number) * 1000
				for _, s in text.series do
					expect(s.times).toEqual({
						start,
						start + 60000,
						start + 120000,
						start + 180000,
						start + 240000,
						start + 300000,
					})
				end
				expect(sortedKeys(byName(text.series))).toEqual(JOBS)
				expect(byName(text.series).down.values).toEqual({ 0, 0, 0, 0, 0, 0 })
			end)

			it("keeps __name__ and every label of a plain selector", function()
				local r = result(capture(version, "query_instant_vector_metric"))
				expect(r.kind).toBe("vector")
				expect(#r.series).toBe(6)
				local node = byName(r.series).node
				expect(node.labels).toEqual({
					__name__ = "up",
					env = "dev",
					instance = "node-exporter:9100",
					job = "node",
				})
				expect(Promtool.seriesName(node.labels)).toBe(
					'up{env="dev", instance="node-exporter:9100", job="node"}'
				)
			end)

			it("reads a scalar result", function()
				local r = result(capture(version, "query_scalar"))
				expect(r.kind).toBe("scalar")
				expect(r.series[1].values).toEqual({ 5 })
			end)

			it("turns a PromQL parse error into a query error, not empty data", function()
				local c = capture(version, "query_error")
				expect(c.status).toBe(1)
				local r = result(c)
				expect(r.kind).toBe("error")
				expect(r.errors[1].kind).toBe("query")
				expect(string.find(r.errors[1].message, "unclosed left parenthesis", 1, true) ~= nil).toBe(true)
			end)

			it("reports an unreachable server as a network error naming the server", function()
				local c = capture(version, "query_refused")
				local r = result(c)
				expect(r.kind).toBe("error")
				expect(r.errors[1].kind).toBe("network")
				local view = Promtool.view(lensFor(c), env(LAB))
				expect(view and view.p and view.p.tone).toBe("error")
				local text = textOf(view)
				expect(string.find(text, "Cannot reach the server", 1, true) ~= nil).toBe(true)
				expect(string.find(text, "connection refused", 1, true) ~= nil).toBe(true)
				expect(string.find(text, "http://127.0.0.1:1", 1, true) ~= nil).toBe(true)
			end)

			it("reads series label sets identically from text and JSON", function()
				local text = result(capture(version, "query_series"))
				local js = result(capture(version, "query_series_json"))
				expect(text.kind).toBe("series")
				expect(text.unparsed).toBe(0)
				expect(#text.label_sets).toBe(6)
				expect(text.label_sets).toEqual(js.label_sets)
				for _, set in text.label_sets do
					expect(set.__name__).toBe("up")
				end
			end)

			it("reads label values identically from text and JSON", function()
				local text = result(capture(version, "query_labels"))
				local js = result(capture(version, "query_labels_json"))
				expect(text.kind).toBe("labels")
				expect(text.values).toEqual(JOBS)
				expect(js.values).toEqual(JOBS)
			end)
		end)
	end
end)

describe("promtool query view", function()
	local range = capture("3.15.0", "query_range")

	it("stays raw while promtool runs and for commands it does not render", function()
		local running = Promtool.open(run(range.args))
		for _, l in range.lines do
			Promtool.line(running, l)
		end
		expect(Promtool.view(running, env(LAB))).toBeNil()

		for _, version in VERSIONS do
			for _, name in { "check_rules_good", "check_config", "test_rules_pass" } do
				local path = "promtool/" .. version .. "/" .. name .. ".txt"
				local cmd = manifest[path].command
				local args: { string } = {}
				for word in string.gmatch(cmd, "%S+") do
					table.insert(args, word)
				end
				table.remove(args, 1)
				local c: Capture =
					{ name = name, args = args, lines = outputLines(path), status = manifest[path].status }
				expect(Promtool.view(lensFor(c), env(LAB))).toBeNil()
			end
		end
	end)

	it("draws one spark row per series with last/min/max", function()
		local view = Promtool.view(lensFor(range), env(LAB))
		assert(view, "range view")
		local charts = findAll(view, kind("chart"))
		expect(#charts).toBe(6)
		for _, chart in charts do
			expect(chart.p.kind).toBe("spark")
			expect(#chart.p.series).toBe(6)
		end
		local text = textOf(view)
		expect(string.find(text, "sum by (job) (up)", 1, true) ~= nil).toBe(true)
		expect(string.find(text, "step 60s", 1, true) ~= nil).toBe(true)
		expect(string.find(text, '{job="down"}', 1, true) ~= nil).toBe(true)
	end)

	-- The `down` target is 0 throughout the capture: a dead series must not
	-- look like the busiest one.
	it("draws an all-zero series as flat stubs and a constant series as flat bars", function()
		for _, version in VERSIONS do
			for _, s in result(capture(version, "query_range")).series do
				local heights = {}
				for i, bar in Promtool.spark(s.times, s.values) do
					heights[i] = bar.value
				end
				local expected = if s.labels.job == "down" then 0 else 1
				expect(heights).toEqual({ expected, expected, expected, expected, expected, expected })
			end
		end
	end)

	it("names series by the labels that tell them apart", function()
		local series = result(capture("3.15.0", "query_instant_vector_metric")).series
		local common = Promtool.commonLabels(series)
		expect(common).toEqual({ __name__ = "up" })
		local node = byName(series).node
		expect(Promtool.distinctName(node.labels, common)).toBe(
			'{env="dev", instance="node-exporter:9100", job="node"}'
		)
		-- A lone series keeps its whole name.
		expect(Promtool.commonLabels({ node })).toEqual({})
		expect(Promtool.distinctName({ __name__ = "up", job = "a" }, { __name__ = "up", job = "a" })).toBe(
			'up{job="a"}'
		)
	end)

	it("shows common labels once and the full name as the row tooltip", function()
		local state = Promtool.open(run({ "query", "range", "http://prometheus3:9090", "rate(x[5m])" }))
		for _, code in { "200", "500" } do
			Promtool.line(state, string.format('{code="%s", handler="/api/v1/query", job="prometheus"} =>', code))
			Promtool.line(state, "1 @[1791577598]")
			Promtool.line(state, "2 @[1791577658]")
		end
		Promtool.finish(state, 0)
		local view = Promtool.view(state, env(nil))
		local text = textOf(view)
		expect(string.find(text, 'Common labels|{handler="/api/v1/query", job="prometheus"}', 1, true) ~= nil).toBe(
			true
		)
		local rows = findAll(view, function(n: any): boolean
			return n.k == "text" and n.p.title ~= nil and string.find(n.p.title, "code=", 1, true) ~= nil
		end)
		expect(#rows).toBe(2)
		expect(rows[1].p.spans[1].t).toBe('{code="200"}')
		expect(rows[1].p.title).toBe('{code="200", handler="/api/v1/query", job="prometheus"}')
	end)

	it("shows the instant vector as a table without sparks", function()
		local view = Promtool.view(lensFor(capture("2.53.5", "query_instant")), env(LAB))
		assert(view, "instant view")
		expect(#findAll(view, kind("chart"))).toBe(0)
		local text = textOf(view)
		for _, job in JOBS do
			expect(string.find(text, job, 1, true) ~= nil).toBe(true)
		end
	end)

	-- A click on a lens rebuilt after a reload must land on the same view.
	it("carries the whole view choice in the action so a rehydrated lens agrees", function()
		local first = lensFor(range)
		local view = Promtool.view(first, env(LAB))
		local tableChip = findAll(view, withAction("v=table:1"))
		expect(#tableChip).toBe(1)
		Promtool.event(first, { ev = "action", act = "v", value = "table:1" }, env(LAB))
		local after = Promtool.view(first, env(LAB))
		expect(#findAll(after, kind("chart"))).toBe(0)

		local rehydrated = lensFor(range)
		Promtool.event(rehydrated, { ev = "action", act = "v", value = "table:1" }, env(LAB))
		expect(Promtool.view(rehydrated, env(LAB))).toEqual(after)
	end)

	it("caps rows and offers Show all", function()
		local lines: { string } = {}
		for i = 1, 120 do
			table.insert(lines, string.format('{i="%d"} => %d @[1791577918.43]', i, i))
		end
		local state = Promtool.open(run({ "query", "instant", "http://prometheus3:9090", "x" }))
		for _, l in lines do
			Promtool.line(state, l)
		end
		Promtool.finish(state, 0)
		local view = Promtool.view(state, env(nil))
		expect(#findAll(view, withAction("v=all:1"))).toBe(1)
		Promtool.event(state, { ev = "action", act = "v", value = "all:1" }, env(nil))
		expect(#findAll(Promtool.view(state, env(nil)), withAction("v=all:1"))).toBe(0)
	end)

	it("opens the run in the Query block of the context that owns the server", function()
		local state = lensFor(range)
		local view = Promtool.view(state, env(LAB))
		expect(#findAll(view, withAction("query"))).toBe(1)
		local effects = Promtool.event(state, { ev = "action", act = "query" }, env(LAB))
		expect(#effects).toBe(1)
		local effect = effects[1] :: any
		expect(effect.kind).toBe("open")
		local link = Scheme.decode(effect.target)
		assert(link, "query link")
		expect(link.action).toBe("query")
		expect(link.params).toEqual({
			context = "lab3",
			expr = "sum by (job) (up)",
			mode = "graph",
			from = RANGE_START .. "000",
			to = RANGE_END .. "000",
		})
	end)

	it("offers no Query block action when no context owns the server", function()
		local state = lensFor(range)
		local view = Promtool.view(state, env(nil))
		expect(#findAll(view, withAction("query"))).toBe(0)
		local effects = Promtool.event(state, { ev = "action", act = "query" }, env(nil))
		expect((effects[1] :: any).kind).toBe("toast")
	end)
end)

describe("promtool query argv", function()
	local function parse(args: { string }): Promtool.Invocation
		return Promtool.parseArgs("promtool", args)
	end

	it("keeps a quoted expression with spaces and quotes as one argument", function()
		local expr = 'sum by (job) (rate(http_requests_total{path="/a b", code=~"5.."}[5m]))'
		local inv = parse({ "query", "instant", "http://p:9090", expr })
		expect(inv.verb).toBe("instant")
		expect(inv.server).toBe("http://p:9090")
		expect(inv.expr).toBe(expr)
	end)

	it("accepts flags before, between and after the positionals in every kingpin form", function()
		local inv =
			parse({ "query", "-o", "json", "range", "--start", "1", "http://p", "--end=2", "up", "--step", "15s" })
		expect(inv.verb).toBe("range")
		expect(inv.format).toBe("json")
		expect({ inv.server, inv.expr, inv.start, inv.stop, inv.step }).toEqual({ "http://p", "up", "1", "2", "15s" })
		expect(parse({ "query", "instant", "-ojson", "http://p", "up" }).format).toBe("json")
		expect(parse({ "query", "instant", "--format=json", "http://p", "up" }).format).toBe("json")
		expect(parse({ "query", "instant", "--time=2026-10-09T20:00:00Z", "http://p", "up" }).time).toBe(
			"2026-10-09T20:00:00Z"
		)
	end)

	it("treats everything after -- as positional", function()
		local inv = parse({ "query", "instant", "--", "http://p", "-up" })
		expect(inv.verb).toBe("instant")
		expect(inv.expr).toBe("-up")
		-- Without `--` promtool reads -up as a flag and fails: raw output.
		expect(parse({ "query", "instant", "http://p", "-up" }).verb).toBeNil()
	end)

	it("leaves to raw what promtool would reject or does not answer with a result", function()
		expect(parse({ "query", "instant", "http://p", "sum", "by", "(job)", "(up)" }).verb).toBeNil()
		expect(parse({ "query", "instant", "--help" }).verb).toBeNil()
		expect(parse({ "query", "-h", "range" }).verb).toBeNil()
		expect(parse({ "query", "analyze", "--server=http://p" }).verb).toBeNil()
		expect(parse({ "query", "instant", "-o", "yaml", "http://p", "up" }).verb).toBeNil()
		expect(parse({ "query", "range", "http://p", "up", "--start" }).verb).toBeNil()
		expect(parse({ "check", "rules", "x.yml" }).verb).toBeNil()
		expect(Promtool.parseArgs("amtool", { "query", "instant", "http://p", "up" }).verb).toBeNil()
	end)

	it("collects repeated --match selectors", function()
		local inv = parse({ "query", "series", "--match", "up", "--match=node_load1", "http://p" })
		expect(inv.verb).toBe("series")
		expect(inv.matches).toEqual({ "up", "node_load1" })
	end)
end)

describe("promtool text format details", function()
	it("unescapes Go-quoted label values and reads NaN and infinities", function()
		local inv = Promtool.parseArgs("promtool", { "query", "instant", "http://p", "x" })
		local r = Promtool.build(inv, {
			'x{msg="a \\"b\\" => c\\\\d"} => NaN @[1.5]',
			'{"my.metric", "a.b"="c"} => +Inf @[2]',
			"{} => -Inf @[3]",
		}, json.decode)
		expect(r.kind).toBe("vector")
		expect(r.unparsed).toBe(0)
		expect(r.series[1].labels).toEqual({ __name__ = "x", msg = 'a "b" => c\\d' })
		expect(r.series[1].times).toEqual({ 1500 })
		local nan = r.series[1].values[1]
		expect(nan ~= nan).toBe(true)
		expect(r.series[2].labels).toEqual({ __name__ = "my.metric", ["a.b"] = "c" })
		expect(r.series[2].values).toEqual({ math.huge })
		expect(r.series[3].values).toEqual({ -math.huge })
	end)

	it("returns raw for output it cannot read", function()
		local inv = Promtool.parseArgs("promtool", { "query", "instant", "http://p", "x" })
		expect(Promtool.build(inv, { "something else entirely" }, json.decode).kind).toBe("unreadable")
		local js = Promtool.parseArgs("promtool", { "query", "instant", "-o", "json", "http://p", "x" })
		expect(Promtool.build(js, { "[{" }, json.decode).kind).toBe("unreadable")
		expect(Promtool.build(inv, {}, json.decode).kind).toBe("empty")
	end)
end)

describe("Promtool.spark", function()
	local function series(n: number, f: (number) -> number): ({ number }, { number })
		local times, values = table.create(n), table.create(n)
		for i = 1, n do
			times[i] = 1791577598000 + (i - 1) * 15000
			values[i] = f(i)
		end
		return times, values
	end

	it("never exceeds the bar budget, also for gap-heavy series", function()
		local times, values = series(1000, function(i: number): number
			return math.sin(i / 20)
		end)
		local bars = Promtool.spark(times, values)
		expect(#bars).toBe(Promtool.MAX_SPARK)
		local gappy, gv = series(1000, function(i: number): number
			return if i % 2 == 0 then 0 / 0 else i
		end)
		expect(#Promtool.spark(gappy, gv) <= Promtool.MAX_SPARK).toBe(true)
		expect(#Promtool.spark(times, values, 10) <= 10).toBe(true)
	end)

	it("keeps short series whole", function()
		local times, values = series(5, function(i: number): number
			return i
		end)
		expect(#Promtool.spark(times, values)).toBe(5)
	end)

	-- Tern scales bars to the tallest, so a series near 1000 must not look flat.
	it("maps each series onto its own min..max and draws missing samples as stubs", function()
		local times, values = series(4, function(i: number): number
			return ({ 1000, 1001, 0 / 0, 1000.5 })[i]
		end)
		local bars = Promtool.spark(times, values)
		expect(bars[1].value).toBe(0.1)
		expect(bars[2].value).toBe(1)
		expect(bars[3].value).toBeNil()
		expect(bars[4].value).toBe(0.55)
		expect(bars[2].title).toBe("1001 at 2026-10-09 20:26:53")
		local flat = Promtool.spark(series(3, function(): number
			return 7
		end))
		expect({ flat[1].value, flat[2].value, flat[3].value }).toEqual({ 1, 1, 1 })
	end)
end)

describe("Promtool.queryLink", function()
	local function link(args: { string }, config: any): any
		local url, why = Promtool.queryLink(Promtool.parseArgs("promtool", args), config)
		if url == nil then
			return { error = why }
		end
		return (Scheme.decode(url :: string) :: any).params
	end

	it("matches the server against prometheus URLs, path prefixes included", function()
		expect(link({ "query", "instant", "http://prometheus3:9090/", "up" }, LAB).context).toBe("lab3")
		expect(link({ "query", "instant", "https://ops.example.com/prometheus", "up" }, LAB).context).toBe("sub")
		expect(link({ "query", "instant", "https://ops.example.com", "up" }, LAB).error).toBe(
			"no configured context serves https://ops.example.com"
		)
	end)

	it("recognizes a Grafana datasource proxy URL and keeps its datasource", function()
		local p = link({ "query", "instant", "http://localhost:3000/api/datasources/proxy/uid/prom3", "up" }, LAB)
		expect(p.context).toBe("graf")
		expect(p.ds).toBe("prom3")
	end)

	it("opens instant queries as a table, at --time when given", function()
		expect(link({ "query", "instant", "http://prometheus2:9090", "up" }, LAB)).toEqual({
			context = "lab2",
			expr = "up",
			mode = "table",
		})
		local p = link({ "query", "instant", "--time=1791577598", "http://prometheus2:9090", "up" }, LAB)
		expect({ p.from, p.to }).toEqual({ "1791573998000", "1791577598000" })
	end)

	it("uses promtool's own range defaults when --start/--end are absent", function()
		local p = link({ "query", "range", "http://prometheus2:9090", "up" }, LAB)
		expect({ p.from, p.to }).toEqual({ "now-5m", "now" })
		local q = link({ "query", "range", "--end=1791577898", "http://prometheus2:9090", "up" }, LAB)
		expect({ q.from, q.to }).toEqual({ "1791577598000", "1791577898000" })
	end)

	it("opens a single series selector, but not label values", function()
		expect(link({ "query", "series", "--match=up", "http://prometheus2:9090" }, LAB).expr).toBe("up")
		expect(link({ "query", "labels", "http://prometheus2:9090", "job" }, LAB).error).toBe("nothing to query")
	end)
end)

return nil
