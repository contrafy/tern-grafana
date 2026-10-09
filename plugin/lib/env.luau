--!strict
-- What pure code receives instead of the `tern` global: clock, pane size,
-- the JSON codec and its null sentinel, and the validated config.

local ConfigTypes = require("./config/types")

export type Env = {
	-- Wall-clock epoch milliseconds at the time of the call.
	now_ms: number,
	cols: number?,
	rows: number?,
	decode: (string) -> any,
	encode: (any) -> string,
	-- tern.json.null in Tern; the test codec's sentinel in specs.
	null: any,
	config: ConfigTypes.Config?,
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
