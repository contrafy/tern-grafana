--!strict
-- Runs a pure block state machine (lib/effect.luau) as a Tern block: builds
-- the Env, executes the effects the machine returns, feeds results back as
-- messages, materializes view assets into blobs, renders and saves. It
-- decides nothing.
--
-- Every tern call and every machine call is pcalled: a raising machine shows
-- an error view and the block stays open. Blocks get no close callback, so a
-- liveness timer polls tern.pane.list; once the pane is gone (or the machine
-- asked to exit) timers are cancelled and late callbacks are ignored. Late
-- http answers to a live block are delivered: the machine drops stale ones
-- by tag.

local BlobHost = require("./blob_host")
local ConfigHost = require("./config_host")
local Effect = require("./lib/effect")
local EnvHost = require("./env_host")
local TransportHost = require("./transport_host")
local ui = require("./lib/ui")

type Effect = Effect.Effect
type Msg = Effect.Msg
type Machine = Effect.Machine<any>

export type Handler = (effect: any, send: (msg: any) -> ()) -> ()
export type Handlers = { [string]: Handler }

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
	liveness: TimerHandle?,
}

local M = {}

-- How often a block checks that its pane still exists.
M.LIVENESS_MS = 5000

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
	for handle in run.timers do
		pcall(function()
			handle:cancel()
		end)
	end
	table.clear(run.timers)
	if run.liveness then
		local handle = run.liveness :: TimerHandle
		pcall(function()
			handle:cancel()
		end)
		run.liveness = nil
	end
end

local function call(run: Run, what: string, fn: () -> ()): boolean
	local ok, err = pcall(fn :: any)
	if not ok then
		warn(run, what, err)
	end
	return ok
end

local exec: (run: Run, effects: { Effect }) -> ()

-- Applies a message and executes its effects; true when it ran.
local function apply(run: Run, msg: Msg): boolean
	if run.stopped or run.failure then
		return false
	end
	local ok, state, effects = pcall(run.machine.update, run.state, msg, EnvHost.make(run.cx))
	if not ok then
		fail(run, "update(" .. tostring(msg.kind) .. ")", state)
		return true
	end
	run.state = state
	exec(run, effects or {})
	return true
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

-- Delivers an asynchronous message, then renders and saves.
local function deliver(run: Run, msg: Msg)
	if apply(run, msg) then
		refresh(run)
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
		-- transport_host never raises by design; keep the machine waiting no longer.
		deliver(run, {
			kind = "http_done",
			tag = tag,
			response = {
				status = 0,
				headers = {},
				body = "",
				timed_out = false,
				failure = { kind = "network", message = "request could not be sent: " .. tostring(err) },
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
		elseif kind == "toast" then
			call(run, "toast", function()
				run.cx:toast(e.level or "info", e.text or "", e.sub)
			end)
		elseif kind == "open" then
			call(run, "open", function()
				run.cx:open(e.target)
			end)
		elseif kind == "copy" then
			call(run, "copy", function()
				run.cx:copy(e.text or "")
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

local function watch(run: Run)
	local function tick()
		run.liveness = nil
		if run.stopped then
			return
		end
		local ok, panes = pcall(tern.pane.list)
		if ok then
			local alive = false
			for _, p in panes do
				if p.pane == run.cx.pane then
					alive = true
					break
				end
			end
			if not alive then
				stop(run)
				return
			end
		end
		local okTimer, handle = pcall(tern.timer, M.LIVENESS_MS, tick)
		if okTimer then
			run.liveness = handle
		end
	end
	local ok, handle = pcall(tern.timer, M.LIVENESS_MS, tick)
	if ok then
		run.liveness = handle
	end
end

local function view(run: Run): BlockView
	if run.failure then
		return run.failure :: any
	end
	local env = EnvHost.make(run.cx)
	local ok, node, assets = pcall(run.machine.view, run.state, env)
	if not ok then
		fail(run, "view", node)
		return run.failure :: any
	end
	local regions = Effect.regions(node)
	local okBlob, err = pcall(function()
		for _, region in { regions.main, regions.dock, regions.layer } do
			if region then
				BlobHost.materialize(region :: ui.Node, assets or {}, run.cx)
			end
		end
	end)
	if not okBlob then
		warn(run, "materialize", err)
	end
	return regions :: any
end

function M.define(id: string, machine: Machine, handlers: Handlers?)
	tern.block.define(id, {
		init = function(cx: BlockCx, args: { string }, saved: any): Run
			pcall(ConfigHost.load)
			local run: Run = {
				id = id,
				machine = machine,
				handlers = handlers or {},
				cx = cx,
				state = nil,
				failure = nil,
				stopped = false,
				timers = {},
				liveness = nil,
			}
			local ok, state, effects = pcall(machine.init, args or {}, saved, EnvHost.make(cx))
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
			local fast = run.machine.key
			if fast == nil then
				apply(run, { kind = "key", key = key })
				return true
			end
			local ok, state, effects, changed = pcall(fast, run.state, key, EnvHost.make(cx))
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
			apply(run, { kind = "event", ev = ev })
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
