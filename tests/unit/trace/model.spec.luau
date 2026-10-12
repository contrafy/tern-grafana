--!strict
-- The waterfall must show a trace the way it happened even when the data is
-- imperfect: spans whose parent never arrived stay visible (as extra roots),
-- a service whose clock runs behind does not draw its spans before their
-- caller, a parent cycle cannot hang the block, and self time and the
-- critical path say where the time actually went.
local Fixtures = require("../../lib/fixtures")
local Model = require("../../../plugin/lib/trace/model")
local Nanos = require("../../../plugin/lib/trace/nanos")
local Otlp = require("../../../plugin/lib/trace/otlp")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local env = { now_ms = 0, decode = json.decode, encode = json.encode, null = json.null } :: any

local MS = 1000000
local BASE = { sec = 1700000000, nsec = 0 }

-- A span `ms` milliseconds into the trace lasting `dur` ms.
local function span(id: string, parent: string?, service: string, at: number, dur: number, extra: any?): any
	local s: any = {
		trace_id = string.rep("ab", 16),
		span_id = id,
		parent_id = parent,
		name = "op-" .. id,
		service = service,
		kind = "internal",
		status = "unset",
		start = Nanos.add(BASE, at * MS),
		stop = Nanos.add(BASE, (at + dur) * MS),
		attributes = {},
		resource = { { key = "service.name", value = service, kind = "string" } },
		events = {},
		links = {},
	}
	if extra then
		for k, v in extra do
			s[k] = v
		end
	end
	return s
end

local function names(trace: any): { string }
	local out: { string } = {}
	for _, s in trace.spans do
		table.insert(out, string.rep(".", s.depth) .. s.raw.span_id)
	end
	return out
end

local function byId(trace: any, id: string): any
	return trace.spans[trace.by_id[id]]
end

describe("trace model", function()
	it("builds the recorded trace: tree order, durations, self time, critical path", function()
		local raw = Otlp.parse(json.decode(Fixtures.read("tempo/2.10.8/trace.json")), env) :: { any }
		local tr = Model.build(raw) :: any
		expect(tr.trace_id).toBe("0082c9f1c2bda850d878e52762cc0816")
		expect(names(tr)).toEqual({ "fd222e3b400b8c5e", ".a0f1187d5c9dc4d6", ".93f869ac82c50e2b" })
		expect(tr.duration_ns).toBe(240 * MS)
		expect(tr.root_name).toBe("lets-go")
		expect(tr.root_service).toBe("payments")
		expect(tr.errors).toBe(3)
		expect(tr.orphans).toBe(0)
		expect(tr.services).toEqual({ { name = "payments", spans = 3, errors = 3 } })
		local root, a, b = tr.spans[1], tr.spans[2], tr.spans[3]
		expect(root.children).toEqual({ 2, 3 })
		expect(a.parent).toBe(1)
		-- The two children cover the root back to back: it does nothing itself.
		expect(root.self_ns).toBe(0)
		expect(a.self_ns).toBe(120 * MS)
		expect(root.on_critical_path).toBe(true)
		expect(root.critical_ns).toBe(0)
		expect(a.critical_ns).toBe(120 * MS)
		expect(b.critical_ns).toBe(120 * MS)
		expect(math.abs(tr.start_ms - 1791577563622.704346) < 1e-3).toBe(true)
	end)

	it("places bars as fractions of the trace", function()
		local tr = Model.build({
			span("r", nil, "api", 0, 200),
			span("a", "r", "api", 50, 100),
			span("z", "r", "api", 190, 0),
		}) :: any
		expect({ Model.fractions(tr, byId(tr, "r")) }).toEqual({ 0, 1 })
		expect({ Model.fractions(tr, byId(tr, "a")) }).toEqual({ 0.25, 0.5 })
		expect({ Model.fractions(tr, byId(tr, "z")) }).toEqual({ 0.95, 0 })
		local zero = Model.build({ span("x", nil, "api", 0, 0) }) :: any
		expect({ Model.fractions(zero, zero.spans[1]) }).toEqual({ 0, 0 })
	end)

	it("orders children by start time whatever order the spans arrived in", function()
		local tr = Model.build({
			span("c2", "r", "api", 60, 10),
			span("r", nil, "api", 0, 100),
			span("c1", "r", "api", 10, 10),
			span("g", "c1", "api", 12, 2),
		}) :: any
		expect(names(tr)).toEqual({ "r", ".c1", "..g", ".c2" })
		expect(tr.max_depth).toBe(2)
	end)

	it("keeps spans whose parent is missing as extra roots, in start order", function()
		local tr = Model.build({
			span("lost", "gone", "worker", 0, 10),
			span("r", nil, "api", 5, 100),
			span("kid", "lost", "worker", 1, 2),
		}) :: any
		expect(names(tr)).toEqual({ "lost", ".kid", "r" })
		expect(tr.orphans).toBe(1)
		expect(byId(tr, "lost").orphan).toBe(true)
		expect(byId(tr, "kid").orphan).toBe(false)
		-- The summary names the real root, not the orphan that started first.
		expect(tr.root_name).toBe("op-r")
		expect(tr.roots).toEqual({ 1, 3 })
	end)

	it("moves a child whose clock runs behind into its caller, with its own subtree", function()
		local tr = Model.build({
			span("r", nil, "api", 100, 100),
			-- db's clock is 80 ms behind: it seems to start before its caller.
			span("q", "r", "db", 40, 40),
			span("q2", "q", "db", 45, 10),
		}) :: any
		local r, q, q2 = byId(tr, "r"), byId(tr, "q"), byId(tr, "q2")
		expect(tr.skewed).toBe(1)
		-- Centred in the parent: 100 + (100 - 40) / 2 = 130, a 90 ms shift.
		expect(q.skew_ns).toBe(90 * MS)
		expect(q.start_ns - r.start_ns).toBe(30 * MS)
		expect(q2.start_ns - q.start_ns).toBe(5 * MS)
		expect(q2.skew_ns).toBe(90 * MS)
		expect(tr.duration_ns).toBe(100 * MS)
	end)

	it("leaves a same-service child alone and lets async work outlive its parent", function()
		local tr = Model.build({
			span("r", nil, "api", 10, 50),
			span("early", "r", "api", 0, 5),
			span("async", "r", "queue", 40, 100),
		}) :: any
		expect(byId(tr, "early").skew_ns).toBe(0)
		expect(byId(tr, "async").skew_ns).toBe(0)
		expect(tr.duration_ns).toBe(140 * MS)
	end)

	it("counts self time without double counting overlapping children", function()
		local tr = Model.build({
			span("r", nil, "api", 0, 100),
			span("a", "r", "api", 10, 40),
			span("b", "r", "api", 30, 40),
			span("c", "r", "api", 90, 30),
		}) :: any
		-- Covered: 10..70 and 90..100 (c is clipped to the parent) = 70 ms.
		expect(byId(tr, "r").self_ns).toBe(30 * MS)
	end)

	it("follows the last-finishing child back through the trace for the critical path", function()
		local tr = Model.build({
			span("r", nil, "api", 0, 100),
			span("a", "r", "api", 10, 50),
			span("b", "r", "api", 20, 70),
			span("b1", "b", "db", 30, 20),
		}) :: any
		local r, a, b, b1 = byId(tr, "r"), byId(tr, "a"), byId(tr, "b"), byId(tr, "b1")
		-- r: 90..100 and 0..20; b: 50..90 and 20..30; b1: 30..50; a overlaps b and is off the path.
		expect(r.critical_ns).toBe(30 * MS)
		expect(b.critical_ns).toBe(50 * MS)
		expect(b1.critical_ns).toBe(20 * MS)
		expect(a.on_critical_path).toBe(false)
		expect(a.critical_ns).toBe(0)
	end)

	it("survives duplicate span ids and parent cycles", function()
		local tr = Model.build({
			span("r", nil, "api", 0, 10),
			span("r", nil, "api", 0, 10),
			span("x", "y", "api", 1, 2),
			span("y", "x", "api", 2, 2),
			span("self", "self", "api", 3, 1),
		}) :: any
		expect(tr.duplicates).toBe(1)
		expect(#tr.spans).toBe(4)
		expect(tr.orphans).toBe(2)
		local seen: { [string]: boolean } = {}
		for _, s in tr.spans do
			expect(seen[s.raw.span_id]).toBeNil()
			seen[s.raw.span_id] = true
		end
		expect(byId(tr, "self").orphan).toBe(true)
	end)

	it("lists ancestors nearest first and has nothing to build from no spans", function()
		local tr = Model.build({
			span("r", nil, "api", 0, 10),
			span("a", "r", "api", 1, 5),
			span("b", "a", "api", 2, 1),
		}) :: any
		expect(Model.ancestors(tr, 3)).toEqual({ 2, 1 })
		expect(Model.build({})).toBeNil()
	end)
end)

return nil
