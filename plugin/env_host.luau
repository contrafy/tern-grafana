--!strict
-- Builds the Env pure code receives instead of the `tern` global. Cheap: no
-- I/O (the config is ConfigHost's cached copy), so it is made per call. The
-- config carries this host's default context (config `hosts`, hosts_host), so
-- every reader of default_context honors it.

local ConfigHost = require("./config_host")
local HostsHost = require("./hosts_host")
local Env = require("./lib/env")

local M = {}

-- tern.now() is monotonic and gives sub-second resolution, but a monotonic
-- clock may stop while the machine sleeps, and window code compares host
-- times with os.time(). So the offset is re-anchored whenever now_ms drifts
-- from the wall clock by more than DRIFT_MS (os.time() has 1 s resolution,
-- so a smaller bound would re-anchor on rounding alone). Correct whether or
-- not tern.now() pauses during sleep.
local DRIFT_MS = 1500
local offset = os.time() * 1000 - tern.now()

local function kvGet(key: string): any
	local ok, value = pcall(tern.kv.get, key)
	return if ok then value else nil
end

function M.nowMs(): number
	local wall = os.time() * 1000
	local now = tern.now() + offset
	if math.abs(now - wall) > DRIFT_MS then
		offset = wall - tern.now()
		now = wall
	end
	return now
end

-- Minutes east of UTC on this machine now: the UTC wall fields read back as
-- local time (with the local DST flag) differ from now by the offset.
function M.localOffsetMin(): number
	local t = os.time()
	local utc: any = os.date("!*t", t)
	local here: any = os.date("*t", t)
	utc.isdst = here.isdst
	return math.floor(os.difftime(t, os.time(utc)) / 60 + 0.5)
end

function M.make(cx: BlockCx?): Env.Env
	local config = HostsHost.apply((ConfigHost.current()))
	return {
		now_ms = M.nowMs(),
		local_offset_min = M.localOffsetMin(),
		cols = if cx then cx.cols else nil,
		rows = if cx then cx.rows else nil,
		pane = if cx then cx.pane else nil,
		decode = tern.json.decode,
		encode = tern.json.encode,
		null = tern.json.null,
		array = tern.json.array,
		config = config,
		kv_get = kvGet,
	}
end

return M
