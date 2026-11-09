--!strict
-- Runs a pure block state machine (lib/effect.luau) as a Tern block: builds
-- the Env, executes the effects the machine returns, feeds results back as
-- messages, materializes view assets into blobs, renders and saves. It
-- decides nothing.
--
-- Every tern call and every machine call is pcalled: a raising machine shows
-- an error view and the block stays open. Blocks get no close callback, so one
-- host-wide liveness timer polls tern.pane.list; once a block's pane is gone
-- (or the machine asked to exit) its timers are cancelled and late callbacks
-- are ignored. Late http answers to a live block are delivered: the machine
-- drops stale ones by tag.

local BlobHost = require("./blob_host")
local ConfigHost = require("./config_host")
local Effect = require("./lib/effect")
local EnvHost = require("./env_host")
local TransportHost = require("./transport_host")
local Env = require("./lib/env")

type Effect = Effect.Effect
type Msg = Effect.Msg
type Machine = Effect.Machine<any>

export type Handler = (effect: any, send: (msg: any) -> ()) -> ()
export type Handlers = { [string]: Handler }
-- A machine, or a function returning it: the latter defers requiring the
-- machine's modules until a block of this kind first opens.
export type MachineSource = Machine | () -> Machine

type Run = {
	id: string,
	machine: Machine,
	handlers: Handlers,
	cx: BlockCx,
	state: any,
	-- The machine raised: what to show instead of its view.
	failure: Effect.Regions?,
	stopped: boolean,
	timers: { [TimerHandle]: true },
	-- The liveness sweep generation the block started in.
	born: number,
	-- The Env of the message being delivered (an Env.Env), reused by the
	-- render it causes.
	env: any,
}

local M = {}

-- How often the host checks that block panes still exist.
M.LIVENESS_MS = 5000

-- Live blocks, swept by one host-wide timer while any exist.
local live: { [Run]: true } = {}
local sweepGen = 0
local sweepTimer: TimerHandle? = nil

local function warn(run: Run, what: string, err: any)
	pcall(tern.log.warn, string.format("tern-grafana %s %s failed", run.id, what), tostring(err))
end

local function fail(run: Run, what: string, err: any)
	warn(run, what, err)
	run.failure = Effect.errorView("tern-grafana." .. run.id, what, err)
end

local function stop(run: Run)
	if run.stopped then
		return
	end
	run.stopped = true
	live[run] = nil
	for handle in run.timers do
		pcall(function()
			handle:cancel()
		end)
	end
	table.clear(run.timers)
end

local arm: () -> ()

-- A block is checked once it has existed for a full interval, as when each
-- block had its own timer: a pane just opened may not be listed yet.
local function sweep()
	sweepTimer = nil
	sweepGen += 1
	local ok, panes = pcall(tern.pane.list)
	if ok then
		local alive: { [any]: true } = {}
		for _, p in panes do
			alive[p.pane] = true
		end
		for run in live do
			if run.born <= sweepGen - 2 and not alive[run.cx.pane] then
				stop(run)
			end
		end
	end
	arm()
end

function arm()
	if sweepTimer ~= nil or next(live) == nil then
		return
	end
	local ok, handle = pcall(tern.timer, M.LIVENESS_MS, sweep)
	if ok then
		sweepTimer = handle
	end
end

local function watch(run: Run)
	run.born = sweepGen
	live[run] = true
	arm()
end

local function call(run: Run, what: string, fn: () -> ()): boolean
	local ok, err = pcall(fn :: any)
	if not ok then
		warn(run, what, err)
	end
	return ok
end

-- Executes an open, copy or toast effect on `cx` (blocks and lenses share
-- these); nil when `e` is another kind, else whether the call succeeded and
-- its error.
function M.execUi(cx: EffectCx, e: any): (boolean?, any)
	local kind = e.kind
	if kind == "toast" then
		return pcall(cx.toast, cx, Effect.toastLevel(e.level), e.text or "", e.sub)
	elseif kind == "open" then
		return pcall(cx.open, cx, e.target)
	elseif kind == "copy" then
		return pcall(cx.copy, cx, e.text or "")
	end
	return nil, nil
end

local exec: (run: Run, effects: { Effect }) -> ()

-- Applies a message and executes its effects. Returns whether it ran, and
-- the machine's `changed` (false: render and save may be skipped).
local function apply(run: Run, msg: Msg, env: Env.Env): (boolean, boolean?)
	if run.stopped or run.failure then
		return false, nil
	end
	local ok, state, effects, changed = pcall(run.machine.update, run.state, msg, env)
	if not ok then
		fail(run, "update(" .. tostring(msg.kind) .. ")", state)
		return true, nil
	end
	run.state = state
	exec(run, effects or {})
	return true, changed
end

local function refresh(run: Run)
	if run.stopped then
		return
	end
	call(run, "render", function()
		run.cx:render()
	end)
	call(run, "save", function()
		run.cx:save()
	end)
end

-- Delivers an asynchronous message, then renders and saves unless the
-- machine said nothing changed.
local function deliver(run: Run, msg: Msg)
	local env = EnvHost.make(run.cx)
	local ran, changed = apply(run, msg, env)
	if ran and changed ~= false then
		run.env = env
		refresh(run)
		run.env = nil
	end
end

local function http(run: Run, e: any)
	local tag = e.tag
	local ok, err = pcall(TransportHost.execute :: any, e.route, e.request, function(response)
		if not run.stopped then
			deliver(run, { kind = "http_done", tag = tag, response = response })
		end
	end)
	if not ok then
		warn(run, "http", err)
		-- transport_host never raises by design; keep the machine waiting no longer.
		deliver(run, {
			kind = "http_done",
			tag = tag,
			response = {
				status = 0,
				headers = {},
				body = "",
				timed_out = false,
				failure = { kind = "network", message = "request could not be sent: " .. Effect.firstLine(err) },
			},
		})
	end
end

local function timer(run: Run, e: any)
	local tag = e.tag
	local handle: TimerHandle? = nil
	local ok, err = pcall(function()
		handle = tern.timer(math.max(0, e.ms or 0), function()
			if handle then
				run.timers[handle :: TimerHandle] = nil
			end
			if not run.stopped then
				deliver(run, { kind = "tick", tag = tag })
			end
		end)
	end)
	if ok and handle then
		run.timers[handle :: TimerHandle] = true
	elseif not ok then
		warn(run, "timer", err)
	end
end

local function custom(run: Run, e: any)
	local handler = run.handlers[e.kind]
	if handler == nil then
		warn(run, "effect", "no handler for effect kind " .. tostring(e.kind))
		return
	end
	call(run, "effect " .. tostring(e.kind), function()
		handler(e, function(msg: any)
			if not run.stopped then
				deliver(run, msg)
			end
		end)
	end)
end

function exec(run: Run, effects: { Effect })
	for _, effect in effects do
		if run.stopped then
			return
		end
		local e: any = effect
		local kind = e.kind
		if kind == "http" then
			http(run, e)
		elseif kind == "timer" then
			timer(run, e)
		elseif kind == "kv_set" then
			call(run, "kv_set", function()
				tern.kv.set(e.key, e.value)
			end)
		elseif kind == "toast" or kind == "open" or kind == "copy" then
			local _, err = M.execUi(run.cx, e)
			if err ~= nil then
				warn(run, kind, err)
			end
		elseif kind == "reveal" then
			call(run, "reveal", function()
				run.cx:frame({ { "reveal", e.id, e.at or "nearest" } })
			end)
		elseif kind == "focus" then
			call(run, "focus", function()
				run.cx:frame({ { "focus", e.id } })
			end)
		elseif kind == "exit" then
			stop(run)
			call(run, "exit", function()
				run.cx:exit(0)
			end)
		else
			custom(run, e)
		end
	end
end

local function view(run: Run): BlockView
	if run.failure then
		return run.failure :: any
	end
	local env = run.env or EnvHost.make(run.cx)
	local ok, node, assets = pcall(run.machine.view, run.state, env)
	if not ok then
		fail(run, "view", node)
		return run.failure :: any
	end
	local regions = Effect.regions(node)
	local okBlob, err = pcall(function()
		BlobHost.materialize(regions, assets, run.cx)
	end)
	if not okBlob then
		warn(run, "materialize", err)
	end
	return regions :: any
end

function M.define(id: string, source: MachineSource, handlers: Handlers?)
	local machine: Machine? = if type(source) == "table" then source else nil
	local function load(): Machine
		if machine == nil then
			machine = (source :: () -> Machine)()
		end
		return machine :: Machine
	end
	tern.block.define(id, {
		init = function(cx: BlockCx, args: { string }, saved: any): Run
			pcall(ConfigHost.load)
			local run: Run = {
				id = id,
				machine = nil :: any,
				handlers = handlers or {},
				cx = cx,
				state = nil,
				failure = nil,
				stopped = false,
				timers = {},
				born = 0,
				env = nil,
			}
			local okLoad, loaded = pcall(load)
			if not okLoad then
				fail(run, "load", loaded)
				return run
			end
			run.machine = loaded
			local ok, state, effects = pcall(loaded.init, args or {}, saved, EnvHost.make(cx))
			if not ok then
				fail(run, "init", state)
				return run
			end
			run.state = state
			watch(run)
			exec(run, effects or {})
			return run
		end,
		view = function(run: Run, cx: BlockCx): BlockView
			run.cx = cx
			return view(run)
		end,
		title = function(run: Run): string?
			if run.failure or run.machine.title == nil then
				return nil
			end
			local ok, title = pcall(run.machine.title :: any, run.state)
			return if ok then title else nil
		end,
		key = function(run: Run, key: Key, cx: BlockCx): boolean?
			run.cx = cx
			if run.stopped or run.failure then
				return false
			end
			local env = EnvHost.make(cx)
			local fast = run.machine.key
			if fast == nil then
				apply(run, { kind = "key", key = key }, env)
				return true
			end
			local ok, state, effects, changed = pcall(fast, run.state, key, env)
			if not ok then
				fail(run, "key", state)
				return true
			end
			run.state = state
			local list: { Effect } = effects or {}
			exec(run, list)
			if changed == false and #list == 0 then
				return false
			end
			return true
		end,
		event = function(run: Run, ev: UiEvent, cx: BlockCx)
			run.cx = cx
			apply(run, { kind = "event", ev = ev }, EnvHost.make(cx))
		end,
		save = function(run: Run): any
			if run.failure or run.machine.save == nil then
				return nil
			end
			local ok, saved = pcall(run.machine.save :: any, run.state)
			if not ok then
				warn(run, "save", saved)
				return nil
			end
			return saved
		end,
	})
end

return M
