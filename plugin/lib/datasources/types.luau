--!strict
-- The datasource module contract (lib/datasources/registry.luau runs it):
-- what the Dashboard block asks a datasource plugin's Tern port for, in
-- place of the work Grafana's frontend does in the browser.
--
-- A module covers one or more datasource types (`types`). Every field but
-- `types` is optional:
-- - `blocker`: why one target cannot be reproduced (the ladder reason), nil
--   when it can. Without one every target of the type runs.
-- - Backend datasources (their targets still go to /api/ds/query):
--   `shape` builds a target as the plugin's frontend hands it to
--   DataSourceWithBackend.query (variables interpolated; refId, datasource,
--   intervalMs and maxDataPoints are added by the caller), `format` is the
--   plugin's custom variable formatter (used by the generic shaping when
--   there is no `shape`), and `postprocess` rewrites the answer's frames of
--   the module's targets as the plugin's frontend does after the query.
-- - Frontend datasources and browser request chains: `start` makes a job for
--   the visible targets of one datasource instance (hidden ones are dropped
--   before), and `step` advances it. The first
--   `step` gets no answers; each later one gets the answers of every request
--   the previous step asked for, by request tag. A step returns the job, the
--   next requests, and the outcome once there is one (requests are then
--   ignored). A job that asks for nothing and has no outcome fails.
-- - Query variables (the plugin's metricFindQuery): `variable` makes a job
--   for the variable's raw query, advanced by the same `step`, whose outcome
--   carries `options` (or `error`).
--
-- Modules are pure (lib/** never reads `tern`): no clocks but ctx.now_ms, no
-- I/O but the requests they return. Requests go to the dashboard's Grafana
-- (paths relative to it: datasource proxy, resources, API, /api/ds/query)
-- with the user's credentials.
--
-- Secrets: a datasource's `url` and `json_data` come from Grafana's frontend
-- settings and may hold credentials (JSON API keeps API keys in
-- jsonData.queryParams, appended to every proxy URL). Never put them, or a
-- request path with its query string, into saved state, logs, block args,
-- compat output or an error message: Registry.json and Registry.redact
-- strip query strings from error texts.

local Env = require("../env")
local Frame = require("../frame/types")
local FrameProm = require("../frame/prom")
local Interpolate = require("../dashboard/interpolate")
local TransportTypes = require("../transport/types")

type Env = Env.Env

-- A Grafana datasource as the frontend settings list it. `url`: the
-- instance URL the plugin's frontend uses (`/api/datasources/proxy/uid/<uid>`
-- for proxy access); `json_data`: its non-secure settings (a decoded copy).
-- manage_alerts: the data source manages alert rules (Grafana's
-- isDataSourceManagingAlerts). backend: the plugin has a backend
-- (meta.backend).
export type Datasource = {
	uid: string,
	type: string,
	name: string,
	is_default: boolean,
	manage_alerts: boolean?,
	backend: boolean?,
	url: string?,
	json_data: { [string]: any }?,
}

-- A panel's results: frames in target order, "A: <message>" per failed
-- target, warnings, and exemplars of time series targets (sorted by time).
export type PanelData = {
	frames: { Frame.Frame },
	errors: { string },
	warnings: { string },
	exemplars: { FrameProm.Exemplar }?,
}

-- A dashboard target as decoded from the panel JSON (never modify it).
export type Target = { [string]: any }

-- What a blocker sees: the variables in scope, Grafana's datasources, the
-- target's datasource instance, and Grafana's major version (nil: unknown).
export type BlockerContext = {
	scope: Interpolate.Scope,
	datasources: { Datasource },
	ds: Datasource,
	grafana_major: number?,
}

-- What `shape`, `postprocess`, `start` and `variable` see. `scope` holds the
-- variables and Grafana's built-ins (`$__interval` of the target group,
-- `$__from`, `$__to`, `$__range`, ...); `interval_ms` and `max_points` are
-- the query's (0 and the config's for variables).
export type DsContext = {
	scope: Interpolate.Scope,
	from_ms: number,
	to_ms: number,
	interval_ms: number,
	max_points: number,
	now_ms: number,
	datasources: { Datasource },
	ds: Datasource,
	grafana_major: number?,
	dashboard_uid: string?,
}

-- One request of a step. `tag` names its answer in the next step's answers:
-- unique within the step, letters, digits and `_ - . :` only.
export type DsRequest = { tag: string, request: TransportTypes.Request }

export type Answers = { [string]: TransportTypes.Response }

-- Module-owned job state; the engine only stores and passes it.
export type Job = { [string]: any }

export type Option = { text: string, value: string }

-- A finished job. Panel jobs: `data` (an "A: ..." error line per failed
-- target, like /api/ds/query results), or `error` for every target.
-- Variable jobs: `options` (before the variable's regex and sort), or
-- `error`.
export type Outcome = {
	data: PanelData?,
	options: { Option }?,
	error: string?,
}

-- Formats a variable's values (`list`: Grafana passes an array) the way the
-- plugin's custom formatter does.
export type Formatter = (values: { string }, var: Interpolate.Var, list: boolean, ctx: DsContext) -> string

export type DsModule = {
	types: { string },
	blocker: ((target: Target, ctx: BlockerContext, env: Env) -> string?)?,
	shape: ((target: Target, ctx: DsContext, env: Env) -> { [string]: any })?,
	postprocess: ((
		frames: { Frame.Frame },
		targets: { { [string]: any } },
		ctx: DsContext,
		env: Env
	) -> { Frame.Frame })?,
	start: ((targets: { Target }, ctx: DsContext, env: Env) -> Job)?,
	step: ((job: Job, answers: Answers, env: Env) -> (Job, { DsRequest }, Outcome?))?,
	variable: ((query: any, ctx: DsContext, env: Env) -> Job)?,
	format: Formatter?,
}

return nil
