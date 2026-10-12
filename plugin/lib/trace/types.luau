--!strict
-- The trace model shared by the parsers (OTLP JSON from Tempo, Grafana's
-- Trace data frame), the model builder and the view. Ids are lowercase hex,
-- padded to their full width (32 digits for traces, 16 for spans). Times keep
-- full nanosecond precision as whole seconds plus nanoseconds: an epoch in
-- nanoseconds is beyond what a double holds exactly.

export type Nano = { sec: number, nsec: number }

-- Attribute values are kept as display strings; `kind` says what they were.
export type Attr = { key: string, value: string, kind: "string" | "number" | "boolean" | "other" }

export type Event = { time: Nano?, name: string, attributes: { Attr } }

export type SpanLink = { trace_id: string, span_id: string, attributes: { Attr } }

export type Kind = "server" | "client" | "producer" | "consumer" | "internal" | "unspecified"

export type Status = "unset" | "ok" | "error"

-- One span as the server sent it.
export type RawSpan = {
	trace_id: string,
	span_id: string,
	-- nil for a root (no parent, or an all-zero parent id).
	parent_id: string?,
	name: string,
	-- resource attribute service.name ("unknown" when absent).
	service: string,
	kind: Kind,
	status: Status,
	status_message: string?,
	start: Nano,
	stop: Nano,
	attributes: { Attr },
	resource: { Attr },
	scope: string?,
	scope_version: string?,
	events: { Event },
	links: { SpanLink },
}

-- A span placed in its trace. Times are nanoseconds from the trace start,
-- after clock skew adjustment.
export type Span = {
	raw: RawSpan,
	-- Position in Trace.spans (depth-first display order).
	index: number,
	depth: number,
	parent: number?,
	children: { number },
	-- Its parent id names a span the trace does not contain.
	orphan: boolean,
	start_ns: number,
	dur_ns: number,
	-- Shift applied to correct clock skew against its parent (0 = none).
	skew_ns: number,
	-- Duration not covered by any child.
	self_ns: number,
	-- Time this span itself spends on the trace's critical path.
	critical_ns: number,
	-- The span lies on the critical path (possibly with no time of its own).
	on_critical_path: boolean,
	-- 1-based index into Trace.services (stable service color).
	service_index: number,
	error: boolean,
}

export type Service = { name: string, spans: number, errors: number }

export type Trace = {
	trace_id: string,
	spans: { Span },
	by_id: { [string]: number },
	roots: { number },
	start: Nano,
	-- Epoch milliseconds of the trace start (display only).
	start_ms: number,
	duration_ns: number,
	services: { Service },
	errors: number,
	orphans: number,
	skewed: number,
	-- Spans that shared an id with an earlier one and were dropped.
	duplicates: number,
	max_depth: number,
	root_name: string,
	root_service: string,
}

return nil
