--!strict
-- Builds a trace from its raw spans: the span tree in depth-first order
-- (children by start time), orphans (a parent id the trace lacks: the parent
-- was not sampled, was dropped or has not arrived yet) shown as extra roots,
-- clock skew correction, self time and the critical path.
--
-- Clock skew: spans recorded by another service (or host) run on another
-- clock. A child that starts before its parent is impossible, so such a child
-- is shifted into its parent (centred when it fits, start-aligned when it is
-- longer), and its same-clock descendants move with it. Unlike Jaeger, a
-- child that only ends after its parent is left alone: that is asynchronous
-- work (a producer's message consumed later), not skew.
--
-- Critical path (Jaeger's algorithm): from the end of the root, walk back
-- through the child that finished last before the current point, recursing
-- into it; the gaps between are the parent's own time. Children are clipped
-- to their parent first.

local Nanos = require("./nanos")
local Types = require("./types")

type RawSpan = Types.RawSpan
type Span = Types.Span
type Trace = Types.Trace
type Attr = Types.Attr

local M = {}

local function attr(attrs: { Attr }, key: string): string?
	for _, a in attrs do
		if a.key == key then
			return a.value
		end
	end
	return nil
end

-- Spans sharing this key share a clock.
local function clockKey(raw: RawSpan): string
	local host = attr(raw.resource, "host.name") or attr(raw.resource, "host.id") or ""
	return raw.service .. "\0" .. host
end

type Work = {
	raw: RawSpan,
	parent: number?,
	children: { number },
	orphan: boolean,
	raw_start: number,
	dur: number,
	start: number,
	skew: number,
	own_skew: boolean,
	depth: number,
	order: number,
	self: number,
	critical: number,
	on_critical: boolean,
}

local function byStart(work: { Work }): (number, number) -> boolean
	return function(a: number, b: number): boolean
		local wa, wb = work[a], work[b]
		if wa.raw_start ~= wb.raw_start then
			return wa.raw_start < wb.raw_start
		end
		return a < b
	end
end

-- The skew shift of `w` against its (already adjusted) parent `p`.
local function skewAgainst(w: Work, p: Work): number
	if w.raw_start >= p.start then
		return 0
	end
	if w.dur <= p.dur then
		return p.start + (p.dur - w.dur) / 2 - w.raw_start
	end
	return p.start - w.raw_start
end

-- Total length of the union of [lo, hi) intervals clipped to [from, to).
local function covered(intervals: { { number } }, from: number, to: number): number
	table.sort(intervals, function(a, b)
		return a[1] < b[1]
	end)
	local total, curLo, curHi = 0, nil :: number?, 0
	for _, iv in intervals do
		local lo, hi = math.max(iv[1], from), math.min(iv[2], to)
		if hi <= lo then
			continue
		end
		if curLo == nil or lo > curHi then
			if curLo ~= nil then
				total += curHi - (curLo :: number)
			end
			curLo, curHi = lo, hi
		elseif hi > curHi then
			curHi = hi
		end
	end
	if curLo ~= nil then
		total += curHi - (curLo :: number)
	end
	return total
end

local function criticalPath(work: { Work }, i: number, lo: number, hi: number)
	local w = work[i]
	w.on_critical = true
	local kids: { { number } } = {}
	for _, c in w.children do
		local cw = work[c]
		local clo, chi = math.max(cw.start, lo), math.min(cw.start + cw.dur, hi)
		if chi > clo then
			table.insert(kids, { c, clo, chi })
		end
	end
	table.sort(kids, function(a, b)
		if a[3] ~= b[3] then
			return a[3] > b[3]
		end
		return a[1] < b[1]
	end)
	local cursor = hi
	for _, k in kids do
		if k[3] <= cursor then
			w.critical += cursor - k[3]
			criticalPath(work, k[1], k[2], k[3])
			cursor = k[2]
		end
	end
	w.critical += math.max(0, cursor - lo)
end

-- nil when there is no span to show.
function M.build(raw: { RawSpan }, trace_id: string?): Trace?
	local work: { Work } = {}
	local byId: { [string]: number } = {}
	local duplicates = 0
	local first: Types.Nano? = nil
	for _, r in raw do
		if byId[r.span_id] then
			duplicates += 1
			continue
		end
		table.insert(work, {
			raw = r,
			parent = nil,
			children = {},
			orphan = false,
			raw_start = 0,
			dur = math.max(0, Nanos.diff(r.stop, r.start)),
			start = 0,
			skew = 0,
			own_skew = false,
			depth = 0,
			order = 0,
			self = 0,
			critical = 0,
			on_critical = false,
		})
		byId[r.span_id] = #work
		if first == nil or Nanos.less(r.start, first :: Types.Nano) then
			first = r.start
		end
	end
	if #work == 0 or first == nil then
		return nil
	end
	local base = first :: Types.Nano
	local roots: { number } = {}
	for i, w in work do
		w.raw_start = Nanos.diff(w.raw.start, base)
		local pid = w.raw.parent_id
		local p = if pid then byId[pid] else nil
		if p and p ~= i then
			w.parent = p
			table.insert(work[p].children, i)
		else
			w.orphan = pid ~= nil
			table.insert(roots, i)
		end
	end
	local cmp = byStart(work)
	for _, w in work do
		table.sort(w.children, cmp)
	end
	table.sort(roots, cmp)

	-- Depth-first order, skew, depth. Spans in a parent cycle are never
	-- reached from a root; they become orphan roots.
	local order: { number } = {}
	local function visit(i: number, depth: number)
		local w = work[i]
		w.depth = depth
		w.order = #order + 1
		table.insert(order, i)
		local p = if w.parent then work[w.parent :: number] else nil
		if p == nil then
			w.skew = 0
		elseif clockKey(w.raw) == clockKey(p.raw) then
			w.skew = p.skew
		else
			w.skew = skewAgainst(w, p)
			w.own_skew = w.skew ~= 0
		end
		w.start = w.raw_start + w.skew
		for _, c in w.children do
			visit(c, depth + 1)
		end
	end
	for _, r in roots do
		visit(r, 0)
	end
	for i, w in work do
		if w.order == 0 then
			-- Cut the cycle at this span: it leaves its parent's children.
			local p = work[w.parent :: number]
			local at = table.find(p.children, i)
			if at then
				table.remove(p.children, at)
			end
			w.parent = nil
			w.orphan = true
			table.insert(roots, i)
			visit(i, 0)
		end
	end

	-- Re-base on the earliest adjusted start.
	local minStart, maxEnd = math.huge, -math.huge
	for _, w in work do
		minStart = math.min(minStart, w.start)
		maxEnd = math.max(maxEnd, w.start + w.dur)
	end
	for _, w in work do
		w.start -= minStart
	end

	for _, w in work do
		local intervals: { { number } } = {}
		for _, c in w.children do
			local cw = work[c]
			table.insert(intervals, { cw.start, cw.start + cw.dur })
		end
		w.self = w.dur - covered(intervals, w.start, w.start + w.dur)
	end

	-- The critical path runs through the root that ends last (true roots
	-- before orphans).
	local main: number? = nil
	for _, r in roots do
		local w = work[r]
		if main == nil then
			main = r
		else
			local m = work[main :: number]
			if (m.orphan and not w.orphan) or (m.orphan == w.orphan and w.start + w.dur > m.start + m.dur) then
				main = r
			end
		end
	end
	if main then
		local m = work[main :: number]
		criticalPath(work, main :: number, m.start, m.start + m.dur)
	end

	local serviceStats: { [string]: Types.Service } = {}
	local names: { string } = {}
	local errors, orphans, skewed, maxDepth = 0, 0, 0, 0
	for _, w in work do
		local name = w.raw.service
		local st = serviceStats[name]
		if st == nil then
			st = { name = name, spans = 0, errors = 0 }
			serviceStats[name] = st
			table.insert(names, name)
		end
		st.spans += 1
		if w.raw.status == "error" then
			st.errors += 1
			errors += 1
		end
		if w.orphan then
			orphans += 1
		end
		if w.own_skew then
			skewed += 1
		end
		maxDepth = math.max(maxDepth, w.depth)
	end
	table.sort(names)
	local services: { Types.Service } = {}
	local serviceIndex: { [string]: number } = {}
	for i, name in names do
		services[i] = serviceStats[name]
		serviceIndex[name] = i
	end

	local spans: { Span } = table.create(#order)
	local outById: { [string]: number } = {}
	for pos, i in order do
		local w = work[i]
		local children = table.create(#w.children)
		for k, c in w.children do
			children[k] = work[c].order
		end
		spans[pos] = {
			raw = w.raw,
			index = pos,
			depth = w.depth,
			parent = if w.parent then work[w.parent :: number].order else nil,
			children = children,
			orphan = w.orphan,
			start_ns = w.start,
			dur_ns = w.dur,
			skew_ns = w.skew,
			self_ns = w.self,
			critical_ns = w.critical,
			on_critical_path = w.on_critical,
			service_index = serviceIndex[w.raw.service],
			error = w.raw.status == "error",
		}
		outById[w.raw.span_id] = pos
	end
	local outRoots: { number } = {}
	for _, r in roots do
		table.insert(outRoots, work[r].order)
	end
	table.sort(outRoots)
	local head = work[roots[1]]
	for _, r in roots do
		if not work[r].orphan then
			head = work[r]
			break
		end
	end
	return {
		trace_id = trace_id or work[1].raw.trace_id,
		spans = spans,
		by_id = outById,
		roots = outRoots,
		start = Nanos.add(base, minStart),
		start_ms = Nanos.toMs(Nanos.add(base, minStart)),
		duration_ns = maxEnd - minStart,
		services = services,
		errors = errors,
		orphans = orphans,
		skewed = skewed,
		duplicates = duplicates,
		max_depth = maxDepth,
		root_name = head.raw.name,
		root_service = head.raw.service,
	}
end

-- A span's position as fractions of the trace: offset of its start and its
-- width, both in [0, 1]. A zero-length trace puts every span at 0 with no
-- width.
function M.fractions(trace: Trace, span: Span): (number, number)
	local total = trace.duration_ns
	if total <= 0 then
		return 0, 0
	end
	local left = math.clamp(span.start_ns / total, 0, 1)
	local width = math.clamp(span.dur_ns / total, 0, 1 - left)
	return left, width
end

-- Ancestors of `index`, nearest first.
function M.ancestors(trace: Trace, index: number): { number }
	local out: { number } = {}
	local p = trace.spans[index].parent
	while p do
		table.insert(out, p)
		p = trace.spans[p].parent
	end
	return out
end

return M
