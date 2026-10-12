--!strict
-- What pure code receives instead of the `tern` global: clock, pane size,
-- the JSON codec and its null sentinel, and the validated config.

local ConfigTypes = require("./config/types")

export type Env = {
	-- Wall-clock epoch milliseconds at the time of the call.
	now_ms: number,
	-- The viewer's local UTC offset at now_ms, minutes east (DST-aware);
	-- nil in specs that do not set it (read as UTC).
	local_offset_min: number?,
	cols: number?,
	rows: number?,
	decode: (string) -> any,
	encode: (any) -> string,
	-- tern.json.null in Tern; the test codec's sentinel in specs.
	null: any,
	-- tern.json.array in Tern: tags a fresh list so an empty one encodes as `[]`.
	array: (<T>(T) -> T)?,
	config: ConfigTypes.Config?,
	-- tern.kv.get in Tern; nil in specs that need no kv.
	kv_get: ((key: string) -> any)?,
}

local M = {}

function M.isNull(env: Env, v: any): boolean
	return v == nil or v == env.null
end

-- `v` with the JSON null sentinel turned into nil.
function M.value(env: Env, v: any): any
	return if v == env.null then nil else v
end

return M
