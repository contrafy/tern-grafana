--!strict
-- The contract every tern-grafana command lens implements, run by
-- plugin/lens_host.luau. A lens is pure: it never touches `tern`; the host
-- feeds it the run, the output lines and the exit status, and executes the
-- effects its `event` returns.
--
-- Tern rebuilds a lens after a reload by replaying `open`, `line` and
-- `finish` over the captured output (rehydration), so those three must
-- derive everything from the run and the lines alone: no clock, no config, no
-- effects. Config arrives with `env` in `view` and `event`, and every
-- clickable carries the whole view choice in its action name.

local Env = require("../env")
local ui = require("../ui")

-- What Tern reports for the claimed command: `args` are already unquoted,
-- with wrappers, `VAR=` prefixes and stderr/stdin redirections removed.
export type Run = {
	line: string,
	typed: string,
	cwd: string?,
	program: string,
	args: { string },
}

-- A view event: `{ev = "action", act, value?}` for custom actions.
export type Event = {
	ev: string,
	act: string?,
	value: string?,
	[string]: any,
}

export type ToastLevel = "success" | "info" | "error"

export type Effect =
	{ kind: "open", target: string }
	| { kind: "copy", text: string }
	| { kind: "toast", level: ToastLevel, text: string, sub: string? }

export type Lens<S> = {
	open: (run: Run) -> S,
	-- One output line (stdout and stderr interleaved, escapes applied).
	line: (state: S, text: string) -> (),
	finish: (state: S, status: number) -> (),
	-- nil shows the raw output.
	view: (state: S, env: Env.Env) -> ui.Node?,
	event: ((state: S, ev: Event, env: Env.Env) -> { Effect })?,
}

return nil
