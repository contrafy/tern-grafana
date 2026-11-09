--!strict
-- Host glue for the Settings block (`tern-grafana.settings`): runs the pure
-- machine (lib/settings) through block_runner and performs its file and
-- keychain effects. The only file it writes is the config file, following
-- the steps lib/settings/write.luau plans (backup, temporary file, `mv`,
-- read back). Keychain items go through CredentialsHost (secret on stdin
-- only).

local BlockRunner = require("./block_runner")
local ConfigHost = require("./config_host")
local CredentialsHost = require("./credentials_host")
local ReadFile = require("./lib/read_file")
local State = require("./lib/settings/state")
local View = require("./lib/settings/view")
local Write = require("./lib/settings/write")

local M = {}

M.MV_TIMEOUT_MS = 5000

type Send = (msg: any) -> ()

local function configPath(): string?
	local ok, _, _, path = pcall(ConfigHost.load)
	return if ok then path else nil
end

local function readFile(path: string): Write.Disk
	local okExists, exists = pcall(tern.fs.exists, path)
	if okExists and not exists then
		return { exists = false, text = nil, error = nil, linked = false }
	end
	local text, err, linked = ReadFile.read(tern.fs.read, path, ConfigHost.MAX_BYTES)
	if text == nil then
		return {
			exists = true,
			text = nil,
			error = string.format(
				"could not read %s: %s (it must be a file of at most %d bytes)",
				path,
				tostring(err),
				ConfigHost.MAX_BYTES
			),
			linked = false,
		}
	end
	return { exists = true, text = text, error = nil, linked = linked }
end

local function onRead(_effect: any, send: Send)
	local path = configPath()
	if path == nil then
		send({ kind = "config_file", path = nil, text = nil, exists = false, error = nil })
		return
	end
	local disk = readFile(path)
	send({ kind = "config_file", path = path, text = disk.text, exists = disk.exists, error = disk.error })
end

local function nonce(): string
	return string.format("%08x%04x", math.random(0, 0x7fffffff), math.floor(tern.now()) % 0x10000)
end

local function onWrite(e: State.WriteEffect, send: Send)
	local function finish(ok: boolean, err: string?, conflict: boolean?)
		send({ kind = "config_written", ok = ok, error = err, conflict = conflict })
	end
	local plan, refusal = Write.plan(e, configPath(), readFile, nonce)
	if plan == nil then
		local r = refusal :: Write.Refusal
		finish(false, r.error, r.conflict)
		return
	end
	local ok, err = pcall(function()
		tern.fs.mkdir(plan.dir)
		if plan.backup then
			tern.fs.write(plan.backup, plan.current :: string)
		end
		tern.fs.write(plan.tmp, plan.text)
	end)
	if not ok then
		pcall(tern.fs.remove, plan.tmp)
		finish(false, tostring(err))
		return
	end
	local spawned, spawnErr = pcall(function()
		tern.process.run(plan.argv, { timeout_ms = M.MV_TIMEOUT_MS }, function(r: ProcessResult)
			if r.status ~= 0 then
				pcall(tern.fs.remove, plan.tmp)
				finish(false, Write.renameFailed(r.stderr))
				return
			end
			local problem = Write.verify(plan, (ReadFile.read(tern.fs.read, plan.target, ConfigHost.MAX_BYTES)))
			if problem then
				finish(false, problem)
				return
			end
			pcall(ConfigHost.reload)
			pcall(tern.log.info, "tern-grafana settings wrote", plan.target)
			finish(true)
		end)
	end)
	if not spawned then
		pcall(tern.fs.remove, plan.tmp)
		finish(false, "mv could not run: " .. tostring(spawnErr))
	end
end

local function onProbe(_effect: any, send: Send)
	local ok, platform = pcall(CredentialsHost.platform)
	send({ kind = "credentials_platform", platform = if ok then platform else nil })
end

local function onStore(e: State.StoreEffect, send: Send)
	CredentialsHost.store(e.item, e.secret, function(ok: boolean, err: string?)
		send({ kind = "credential_stored", item = e.item, ok = ok, error = err })
	end)
end

local function onDelete(e: State.DeleteEffect, send: Send)
	CredentialsHost.delete(e.item, function(ok: boolean, err: string?)
		send({ kind = "credential_deleted", item = e.item, ok = ok, error = err })
	end)
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
		credentials_probe = onProbe,
		credential_store = onStore :: any,
		credential_delete = onDelete :: any,
	})
end

return M
