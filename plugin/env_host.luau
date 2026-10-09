--!strict
-- Builds the Env pure code receives instead of the `tern` global. Cheap: no
-- I/O (the config is ConfigHost's cached copy), so it is made per call.

local ConfigHost = require("./config_host")
local Env = require("./lib/env")

local M = {}

-- tern.now() is monotonic; anchor it to the wall clock once so now_ms is
-- epoch ms with sub-second resolution between calls.
local offset = os.time() * 1000 - tern.now()

local function kvGet(key: string): any
	local ok, value = pcall(tern.kv.get, key)
	return if ok then value else nil
end

function M.nowMs(): number
	return tern.now() + offset
end

function M.make(cx: BlockCx?): Env.Env
	local config = ConfigHost.current()
	return {
		now_ms = M.nowMs(),
		cols = if cx then cx.cols else nil,
		rows = if cx then cx.rows else nil,
		decode = tern.json.decode,
		encode = tern.json.encode,
		null = tern.json.null,
		config = config,
		kv_get = kvGet,
	}
end

return M
