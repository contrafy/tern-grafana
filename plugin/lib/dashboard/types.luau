--!strict
-- State types of the dashboard and panel blocks (lib/dashboard/state.luau)
-- and the fresh state `init` starts from.

local AlertStates = require("./alert_states")
local Annotations = require("./annotations")
local DashConfig = require("./config")
local DsRegistry = require("../datasources/registry")
local Env = require("../env")
local Interpolate = require("./interpolate")
local Ladder = require("./ladder")
local Model = require("./model")
local PanelTime = require("./panel_time")
local Queries = require("./queries")
local QueryOptions = require("../query/options")
local Range = require("../time/range")
local Repeat = require("./repeat")
local Route = require("../config/route")
local Search = require("./search")
local Shared = require("../time/shared")
local SvgAnnotations = require("../render/svg_annotations")
local Variables = require("./variables")

type Env = Env.Env
type Route = Route.Route

local M = {}

export type PanelStatus = "idle" | "loading" | "ready" | "error"

export type Drawn = { range: Range.Range, interval_ms: number }

export type PanelState = {
	status: PanelStatus,
	decision: Ladder.Decision,
	-- Identity of the last query sent (queries + range), to skip repeats.
	signature: string?,
	-- The query sent with `signature`; its answer is parsed against it.
	pq: Queries.PanelQuery?,
	-- The width in px the last query was sent for; a resize alone does not
	-- re-query, the next query takes the new width (SceneQueryRunner
	-- setContainerWidth).
	width_px: number?,
	gen: number,
	data: Queries.PanelData?,
	error: string?,
	-- PNG cache key of the picture shown (the previous one stays up while a
	-- refreshed render is pending).
	png: string?,
	-- PNG cache key the panel wants now.
	png_want: string?,
	-- The panel's range after timeFrom/timeShift and its header info.
	time: PanelTime.Override?,
	-- Module requests: parsed answers by request tag, the identity of the
	-- last batch sent, its generation, the request tag of each index, and a
	-- counter bumped by every answer (view memo).
	extra: { [string]: any }?,
	extra_sig: string?,
	req_gen: number,
	req_tags: { string },
	extra_gen: number,
	-- The module's live redraw period, nil when not live.
	live_ms: number?,
	-- The range and query interval of the query in flight, and of the one
	-- `data` answers (the range it is drawn over).
	asked: Drawn?,
	drawn: Drawn?,
	-- The last answer parsed: query signature, HTTP status and body; an
	-- identical answer keeps `data` (and its view memo).
	answer: { sig: string, status: number, body: string, panel_status: PanelStatus }?,
	-- A refresh skipped while the panel was behind the expanded view.
	stale: boolean?,
	-- `-- Dashboard --` panels: the query, the key of the panel state whose
	-- data this one reuses ("=<key>" for a source queried only for its
	-- consumers, nil without a source panel), and the source data the frames
	-- were derived from.
	source_query: Queries.DashboardQuery?,
	source: string?,
	source_data: Queries.PanelData?,
}

export type Picker = {
	kind: "search" | "vars" | "var" | "links",
	-- The variable a "var" picker edits; the panel key a "links" picker
	-- lists the links of.
	name: string?,
	query: string,
	selected: string?,
	-- Working selection of a multi-value variable (or of a one-of ad hoc
	-- filter's values).
	chosen: { string }?,
	-- An ad hoc variable's picker: the step, the filter edited (its index;
	-- nil adds one), the key and operator picked so far, and the keys or
	-- values listed with their load state (`list_gen` tags the request).
	step: ("filters" | "key" | "op" | "value")?,
	edit: number?,
	key: string?,
	op: string?,
	list: { Variables.Option }?,
	list_status: ("loading" | "ready" | "error")?,
	list_error: string?,
	list_gen: number?,
	-- A "links" picker's panel links, as built when it opened, or the
	-- dashboards of dashboard link `dash_link` (a "dashboards" dropdown).
	links: { PanelLink }?,
	dash_link: number?,
}

export type PickerItem = { id: string, label: string, detail: string? }

-- `uid`: a dashboard a "dashboards" dashboard link lists (`url` its folder).
export type PanelLink = { title: string, url: string, uid: string? }

export type SearchState = {
	gen: number,
	status: "loading" | "ready" | "error",
	hits: { Search.Hit },
	error: string?,
}

export type Settings = {
	status: "loading" | "ready" | "error",
	renderer: boolean?,
	datasources: { Queries.Datasource },
	-- Grafana's frontend feature toggles that are on.
	features: { [string]: boolean },
	-- Grafana's major version (buildInfo.version); nil while unknown.
	major: number?,
	-- OpenFeature flag evaluations still unanswered (Queries.flagRequest).
	pending_flags: number?,
	error: string?,
}

-- A query variable answered by a datasource module's job
-- (lib/datasources): the variable generation (`var_gen`) it was started in.
export type VarRun = { gen: number, run: DsRegistry.Run }

export type Phase = "search" | "loading" | "ready" | "error"

-- Interpolation scopes derived from the variables and the range, valid while
-- `rev`, `vars` and the range are those they were built from. `insts` (the
-- dashboard scope with an instance's repeat values) and `titles` are keyed
-- weakly by panel instance.
export type ScopeMemo = {
	rev: number,
	vars: { Variables.Variable },
	from_ms: number?,
	to_ms: number?,
	scope: Interpolate.Scope,
	signature: string?,
	plain: Interpolate.Scope?,
	insts: { [Repeat.Instance]: Interpolate.Scope },
	titles: { [Repeat.Instance]: string },
	descriptions: { [Repeat.Instance]: string | false },
}

export type State = {
	-- Panel block: the one panel id it shows.
	solo: number?,
	context: string?,
	route: Route?,
	org: string?,
	uid: string?,
	-- `var-` values from the link, applied once the dashboard loads.
	link_vars: { [string]: { string } },
	-- Panel to open expanded (link `panel`).
	link_panel: number?,
	-- Range as Grafana strings; nil until the dashboard default applies.
	from: string?,
	to: string?,
	range: Range.Range?,
	phase: Phase,
	error: string?,
	gen: number,
	dashboard: Model.Dashboard?,
	vars: { Variables.Variable },
	vars_error: string?,
	var_gen: number,
	-- Datasource module jobs of the variables loading, by name.
	var_runs: { [string]: VarRun },
	-- Bumped by every change to the variables or the dashboard model: keys
	-- the scope memo and the repeat expansion.
	rev: number,
	scope_memo: ScopeMemo?,
	settings: Settings,
	-- The signed-in Grafana user's login (`${__user.login}`); nil until known.
	user: { status: "loading" | "ready" | "error", login: string? },
	cfg: DashConfig.Settings,
	sections: { Repeat.SectionInstance },
	-- The `rev` and dashboard `sections` were expanded from (nil: not yet).
	sections_rev: number?,
	-- Instances and their sections by key, and the panel `-- Dashboard --`
	-- queries read by panel id (lib/dashboard/core.luau setSections).
	index: { [string]: Repeat.Instance },
	index_sec: { [string]: Repeat.SectionInstance },
	sources: { [number]: Repeat.Instance },
	collapsed: { [string]: boolean },
	panels: { [string]: PanelState },
	-- Every gen and req_gen a pruned panel state reached: new panel states
	-- start there, so no request tag is ever issued twice.
	gen_floor: number,
	-- Visible panel keys in reading order.
	order: { string },
	focus: string?,
	expanded: boolean,
	cursor: number?,
	-- Sorted sample times of the focused panel's data (cursor moves).
	sample_times: { data: Queries.PanelData, times: { number } }?,
	pngs: { [string]: string },
	png_order: { string },
	png_tags: { [string]: string },
	png_gen: number,
	-- Why a render failed, by cache key; a refresh or range change makes a new key.
	png_errors: { [string]: string },
	-- The renderer said it is busy (429/503): no render until the retry tick.
	png_wait: boolean,
	png_backoff_ms: number,
	-- Bumped by every refresh: part of the PNG cache key.
	refresh_gen: number,
	-- Generation of the auto-refresh timer; older ticks are dropped.
	timer_gen: number,
	refresh_ms: number?,
	auto: boolean,
	picker: Picker?,
	-- Bumped by every ad hoc key or value list request (Picker.list_gen).
	picker_gen: number,
	search: SearchState,
	-- The dashboards each "dashboards" dashboard link lists, by link index.
	dash_hits: { [number]: { Search.Hit } },
	updated_ms: number?,
	-- View id of each panel card in the grid, recorded by the view, so a
	-- focus move can scroll the card into view.
	card_ids: { [string]: string },
	-- Logs panels whose label toggle (`l`) overrides the panel's showLabels.
	labels: { [string]: boolean },
	-- Table panels flipped past their first page (Table pager `tpage`).
	pages: { [string]: number },
	-- Table panels showing another frame (Table frame selector `tframe`).
	frames: { [string]: number },
	-- View memo (lib/dashboard/view.luau): rendered native panels by key.
	memo: { [string]: any },
	-- Selected exemplar of the focused time series (single view): index
	-- into SvgTimeseries.drawnExemplars of its data, and the cursor time `x`
	-- cycling began at.
	exemplar: number?,
	ex_anchor: number?,
	-- Config query.exemplars and query.exemplar_trace_label.
	exemplars_on: boolean,
	trace_label: string?,
	-- Shared time range and cursor (key S).
	sync: Shared.Sync,
	-- Live redraw timer: its generation, period and tick count.
	live_gen: number,
	live_ms: number?,
	live_tick: number,
	-- Dashboard data layers: annotations and alert states.
	layers: Layers,
	-- Annotation layers switched in the variable bar, by layer name (saved
	-- with the block, like the variables in its link).
	layer_on: { [string]: boolean },
}

-- An annotation layer of the dashboard (lib/dashboard/annotations.luau):
-- a Prometheus layer's query (its answer is parsed against it), the
-- events of its last answer (nil until one arrived) and why it failed.
export type AnnotationLayer = {
	def: Annotations.Def,
	pq: Queries.PanelQuery?,
	events: { Annotations.Event }?,
	error: string?,
}

-- lib/dashboard/layers.luau.
export type Layers = {
	-- Bumped by every batch of layer requests; older answers are dropped.
	gen: number,
	-- Identity of the last batch (its requests).
	sig: string?,
	-- The dashboard width in px the batch was sent for: annotation queries
	-- ask for at most that many points (executeAnnotationQuery), the width
	-- kept like a panel's (PanelState.width_px).
	width_px: number?,
	annotations: { AnnotationLayer },
	-- The variable bar's annotation layer switches (Annotations.toggles).
	toggles: { Annotations.Toggle },
	-- Alert state per panel id; nil while unknown or when the range does
	-- not end now.
	alert_states: { [number]: AlertStates.State }?,
	-- The dashboard has no rules linked to its panels: not asked again
	-- until it loads anew (AlertStatesDataLayer hasAlertRules).
	no_rules: boolean,
	-- Marks by panel id from the answered layers, built on demand and kept
	-- (same table) while they stay equal: the view memo keys on their
	-- identity. `stamp` is bumped by every change to the events.
	marks: { [number]: { stamp: number, list: { SvgAnnotations.Mark } } },
	stamp: number,
}

function M.newLayers(): Layers
	return {
		gen = 0,
		sig = nil,
		annotations = {},
		toggles = {},
		alert_states = nil,
		no_rules = false,
		marks = {},
		stamp = 0,
	}
end

function M.new(env: Env): State
	local queryOptions = QueryOptions.read(if env.config then env.config.query else nil)
	return {
		solo = nil,
		context = nil,
		route = nil,
		org = nil,
		uid = nil,
		link_vars = {},
		link_panel = nil,
		from = nil,
		to = nil,
		range = nil,
		phase = "loading",
		error = nil,
		gen = 0,
		dashboard = nil,
		vars = {},
		vars_error = nil,
		var_gen = 0,
		var_runs = {},
		rev = 0,
		scope_memo = nil,
		settings = { status = "loading", renderer = nil, datasources = {}, features = {} },
		user = { status = "loading" },
		cfg = DashConfig.read(env.config),
		sections = {},
		sections_rev = nil,
		index = {},
		index_sec = {},
		sources = {},
		collapsed = {},
		panels = {},
		gen_floor = 0,
		order = {},
		focus = nil,
		expanded = false,
		cursor = nil,
		sample_times = nil,
		pngs = {},
		png_order = {},
		png_tags = {},
		png_gen = 0,
		png_errors = {},
		png_wait = false,
		png_backoff_ms = 0,
		refresh_gen = 0,
		timer_gen = 0,
		refresh_ms = nil,
		auto = true,
		picker = nil,
		picker_gen = 0,
		search = { gen = 0, status = "ready", hits = {} },
		dash_hits = {},
		updated_ms = nil,
		labels = {},
		pages = {},
		frames = {},
		card_ids = {},
		memo = {},
		exemplar = nil,
		ex_anchor = nil,
		exemplars_on = queryOptions.exemplars,
		trace_label = queryOptions.exemplar_trace_label,
		sync = Shared.new("dashboard", env.now_ms, false),
		live_gen = 0,
		live_ms = nil,
		live_tick = 0,
		layers = M.newLayers(),
		layer_on = {},
	}
end

return M
