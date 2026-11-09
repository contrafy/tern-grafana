--!strict
-- Datasource modules by type (lib/datasources/types.luau has the contract)
-- and the engine that runs their jobs. The Dashboard block consults the
-- registry before its built-in datasource rules: a registered type is
-- decided by its module alone.
--
-- A job run: the first step gets no answers and asks for requests; the
-- answers are collected by request tag until every request of the step is
-- answered, then the next step gets them all. A run ends with the module's
-- outcome, or with an error when the module asks for nothing, repeats or
-- misnames a tag, or takes more than MAX_STEPS steps. Callers drop answers
-- the run is not waiting for (a superseded run, a repeated tag).

local Env = require("../env")
local Interpolate = require("../dashboard/interpolate")
local Response = require("../source/response")
local TransportTypes = require("../transport/types")
local Types = require("./types")
local Url = require("../url")

type Env = Env.Env
type DsModule = Types.DsModule
type DsContext = Types.DsContext
type DsRequest = Types.DsRequest
type Outcome = Types.Outcome

local M = {}

local byType: { [string]: DsModule } = {}

-- Adds a module for every type it lists (a later module replaces an earlier
-- one of the same type).
function M.register(mod: DsModule)
	for _, t in mod.types do
		byType[t] = mod
	end
end

M.register(require("./incident"))

function M.module(dsType: string): DsModule?
	return byType[dsType]
end

-- Engine ----------------------------------------------------------------------

M.MAX_STEPS = 16

export type Run = {
	module: DsModule,
	-- The refIds of the targets a panel job runs (empty for variables).
	ref_ids: { string },
	job: Types.Job,
	-- Tags of the step's requests still unanswered, and the answers so far.
	pending: { [string]: boolean },
	answers: Types.Answers,
	steps: number,
	outcome: Outcome?,
}

local function fail(run: Run, message: string): { DsRequest }
	run.outcome = { error = message }
	run.pending = {}
	return {}
end

local function advance(run: Run, answers: Types.Answers, env: Env): { DsRequest }
	local step = run.module.step
	if step == nil then
		return fail(run, "the datasource module has no step")
	end
	if run.steps >= M.MAX_STEPS then
		return fail(run, string.format("the datasource needed more than %d request rounds", M.MAX_STEPS))
	end
	run.steps += 1
	local job, requests, outcome = step(run.job, answers, env)
	run.job = job
	run.answers = {}
	run.pending = {}
	if outcome then
		run.outcome = outcome
		return {}
	end
	if #requests == 0 then
		return fail(run, "the datasource module asked for nothing")
	end
	for _, r in requests do
		if not string.match(r.tag, "^[%w_%-%.:]+$") or run.pending[r.tag] then
			return fail(run, string.format("the datasource module asked with a bad request tag %q", r.tag))
		end
		run.pending[r.tag] = true
	end
	return requests
end

-- Starts a run of `job` (made by the module's start or variable): its first
-- requests, none when the run already ended.
function M.begin(mod: DsModule, job: Types.Job, refIds: { string }, env: Env): (Run, { DsRequest })
	local run: Run = { module = mod, ref_ids = refIds, job = job, pending = {}, answers = {}, steps = 0 }
	return run, advance(run, {}, env)
end

-- Records the answer to request `tag`. False when the run is not waiting for
-- it; else the next step's requests once the step is complete (none while
-- other answers are pending, or when the run ended).
function M.answer(run: Run, tag: string, response: TransportTypes.Response, env: Env): (boolean, { DsRequest })
	if run.outcome or not run.pending[tag] then
		return false, {}
	end
	run.pending[tag] = nil
	run.answers[tag] = response
	if next(run.pending) ~= nil then
		return true, {}
	end
	return true, advance(run, run.answers, env)
end

-- The panel data of an ended run: the module's, else its error on every
-- target.
function M.panelData(run: Run): Types.PanelData
	local outcome: Outcome = run.outcome or { error = "the datasource did not answer" }
	if outcome.data then
		return outcome.data :: Types.PanelData
	end
	local errors: { string } = {}
	for _, refId in run.ref_ids do
		table.insert(errors, refId .. ": " .. M.redact(outcome.error or "the datasource returned no data"))
	end
	return { frames = {}, errors = errors, warnings = {} }
end

-- Helpers for modules ---------------------------------------------------------

-- `text` with the query string of every URL or path removed (proxy URLs may
-- carry API keys from the datasource's jsonData).
function M.redact(text: string): string
	return (string.gsub(text, "([%w%-%._~/%%:]+)%?[^%s\"'<>%)]+", "%1?..."))
end

-- The decoded JSON body of an answer and the transport/HTTP error (the
-- server's own message when the body has one), redacted. A non-2xx JSON
-- body comes back with its error.
function M.json(response: TransportTypes.Response, env: Env, what: string): (any, string?)
	local doc, err = Response.json(response, env, what)
	return doc, if err then M.redact(err.message) else nil
end

-- The datasource proxy path of an instance (relative to Grafana), as its
-- frontend's `instanceSettings.url` names it; nil for browser (direct)
-- access, which Tern cannot reproduce.
function M.proxyPath(ds: Types.Datasource): string?
	local url = ds.url
	if url == nil or string.sub(url, 1, 1) ~= "/" then
		return nil
	end
	return "/api/datasources/proxy/uid/" .. Url.percentEncode(ds.uid)
end

-- The module's formatter as an interpolation default, nil without one.
function M.formatter(mod: DsModule, ctx: DsContext): Interpolate.Formatter?
	local format = mod.format
	if format == nil then
		return nil
	end
	local f = format :: Types.Formatter
	return function(values: { string }, var: Interpolate.Var, list: boolean): string
		return f(values, var, list, ctx)
	end
end

return M
