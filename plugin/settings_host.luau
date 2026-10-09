--!strict
-- Host glue for the Settings block (`tern-grafana.settings`): runs the pure
-- machine (lib/settings) through block_runner and performs its two file
-- effects. The only file it writes is the config file, atomically: the text
-- the edit was computed from must still be on disk (same hash), the previous
-- file is copied to `<config>.bak`, the new text goes to a temporary file in
-- the same directory and is renamed over the config with `mv`.

local BlockRunner = require("./block_runner")
local ConfigHost = require("./config_host")
local Json = require("./lib/settings/json")
local State = require("./lib/settings/state")
local View = require("./lib/settings/view")

local M = {}

M.MV_TIMEOUT_MS = 5000

type Send = (msg: any) -> ()

local function dirOf(path: string): string?
	return string.match(path, "^(.*)/[^/]+$")
end

local function configPath(): string?
	local ok, _, _, path = pcall(ConfigHost.load)
	return if ok then path else nil
end

-- (exists, text, error)
local function readFile(path: string): (boolean, string?, string?)
	local okExists, exists = pcall(tern.fs.exists, path)
	if okExists and not exists then
		return false, nil, nil
	end
	local ok, text = pcall(tern.fs.read, path, ConfigHost.MAX_BYTES)
	if not ok then
		return true,
			nil,
			string.format(
				"could not read %s: %s (it must be a regular file, not a symlink, of at most %d bytes)",
				path,
				tostring(text),
				ConfigHost.MAX_BYTES
			)
	end
	return true, text, nil
end

local function onRead(_effect: any, send: Send)
	local path = configPath()
	if path == nil then
		send({ kind = "config_file", path = nil, text = nil, exists = false, error = nil })
		return
	end
	local exists, text, err = readFile(path)
	send({ kind = "config_file", path = path, text = text, exists = exists, error = err })
end

local function nonce(): string
	return string.format("%08x%04x", math.random(0, 0x7fffffff), math.floor(tern.now()) % 0x10000)
end

local function onWrite(e: State.WriteEffect, send: Send)
	local function finish(ok: boolean, err: string?, conflict: boolean?)
		send({ kind = "config_written", ok = ok, error = err, conflict = conflict })
	end
	local target = e.path
	if target ~= configPath() then
		finish(false, "refusing to write outside the config path")
		return
	end
	local dir = dirOf(target)
	if dir == nil or dir == "" then
		finish(false, "the config path has no directory")
		return
	end
	local exists, current, readErr = readFile(target)
	if readErr then
		finish(false, readErr)
		return
	end
	local same = if e.base_hash == nil then not exists else current ~= nil and Json.hash(current) == e.base_hash
	if not same then
		finish(false, nil, true)
		return
	end
	local tmp = string.format("%s/.%s.tern-grafana-%s.tmp", dir, string.match(target, "([^/]+)$") or "config", nonce())
	local ok, err = pcall(function()
		tern.fs.mkdir(dir)
		if current ~= nil then
			tern.fs.write(target .. ".bak", current)
		end
		tern.fs.write(tmp, e.text)
	end)
	if not ok then
		pcall(tern.fs.remove, tmp)
		finish(false, tostring(err))
		return
	end
	local spawned, spawnErr = pcall(function()
		tern.process.run({ "mv", "-f", "--", tmp, target }, { timeout_ms = M.MV_TIMEOUT_MS }, function(r: ProcessResult)
			if r.status ~= 0 then
				pcall(tern.fs.remove, tmp)
				finish(false, "mv failed: " .. (string.match(r.stderr, "^[^\n]*") or ""))
				return
			end
			local okBack, written = pcall(tern.fs.read, target, ConfigHost.MAX_BYTES)
			if not okBack or written ~= e.text then
				finish(false, "the file does not hold the new text after the rename; check " .. target)
				return
			end
			pcall(ConfigHost.reload)
			pcall(tern.log.info, "tern-grafana settings wrote", target)
			finish(true)
		end)
	end)
	if not spawned then
		pcall(tern.fs.remove, tmp)
		finish(false, "mv could not run: " .. tostring(spawnErr))
	end
end

local machine = {
	init = State.init,
	update = State.update,
	view = View.view,
	title = State.title,
	save = State.save,
	key = State.key,
}

function M.register()
	BlockRunner.define("settings", machine :: any, {
		config_read = onRead,
		config_write = onWrite :: any,
	})
end

return M
