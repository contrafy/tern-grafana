--!strict
-- Registers a pure lens (plugin/lib/lens/types.luau) with Tern. The lens
-- decides everything; this adapter only feeds it run/lines/status, hands it
-- an Env in view/event, and executes the effects `event` returns on the
-- EffectCx. Every call into the lens is pcalled: a raising lens shows the
-- raw output (view nil) and logs once, instead of failing the block.
--
-- open/line/finish stay side-effect free here too: Tern replays them when it
-- rehydrates a lens after a reload, so nothing below runs effects or reads
-- config in them.

local EnvHost = require("./env_host")
local LensTypes = require("./lib/lens/types")
local ui = require("./lib/ui")

type Effect = LensTypes.Effect

type HostState = {
	id: string,
	inner: any,
	-- The lens raised: show raw from now on.
	broken: boolean,
	warned: boolean,
}

local M = {}

local function warnOnce(state: HostState, what: string, err: any)
	if state.warned then
		return
	end
	state.warned = true
	pcall(tern.log.warn, "tern-grafana lens " .. state.id .. " " .. what .. " failed; showing raw", tostring(err))
end

local function guard(state: HostState, what: string, ok: boolean, err: any): boolean
	if not ok then
		state.broken = true
		warnOnce(state, what, err)
	end
	return ok
end

local function execute(state: HostState, effect: Effect, cx: EffectCx)
	local ok, err
	if effect.kind == "open" then
		ok, err = pcall(cx.open, cx, effect.target)
	elseif effect.kind == "copy" then
		ok, err = pcall(cx.copy, cx, effect.text)
	elseif effect.kind == "toast" then
		ok, err = pcall(cx.toast, cx, effect.level, effect.text, effect.sub)
	else
		ok, err = false, "unknown effect"
	end
	if not ok then
		warnOnce(state, "effect " .. tostring(effect.kind), err)
	end
end

function M.define<S>(id: string, lens: LensTypes.Lens<S>)
	local def: LensDef<HostState> = {
		open = function(run: LensRun, _cx: EffectCx): HostState
			local state: HostState = { id = id, inner = nil, broken = false, warned = false }
			local ok, inner = pcall(lens.open, {
				line = run.line,
				typed = run.typed,
				cwd = run.cwd,
				program = run.program,
				args = run.args,
			})
			if guard(state, "open", ok, inner) then
				state.inner = inner
			end
			return state
		end,
		line = function(state: HostState, l: LensLine)
			if not state.broken then
				local ok, err = pcall(function(): any
					lens.line(state.inner, l.text)
					return nil
				end)
				guard(state, "line", ok, err)
			end
		end,
		finish = function(state: HostState, status: number)
			if not state.broken then
				local ok, err = pcall(function(): any
					lens.finish(state.inner, status)
					return nil
				end)
				guard(state, "finish", ok, err)
			end
		end,
		view = function(state: HostState): Node?
			if state.broken then
				return nil
			end
			local ok, node = pcall(function(): ui.Node?
				return lens.view(state.inner, EnvHost.make())
			end)
			if not guard(state, "view", ok, node) then
				return nil
			end
			return node :: any
		end,
		event = function(state: HostState, ev: UiEvent, cx: EffectCx)
			local handler = lens.event
			if state.broken or handler == nil then
				return
			end
			local ok, effects = pcall(function(): { Effect }
				return handler(state.inner, ev :: any, EnvHost.make())
			end)
			if not ok then
				warnOnce(state, "event " .. tostring(ev.act), effects)
				return
			end
			for _, effect in effects :: { Effect } do
				execute(state, effect, cx)
			end
		end,
	}
	tern.lens.define(id, def)
end

return M
