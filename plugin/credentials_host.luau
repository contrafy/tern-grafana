--!strict
-- Runs the keychain and login-shell plans of lib/auth (keychain, login_env)
-- and hands back what happened. Used by transport_host (lookups, token_env)
-- and by the Settings block (store, delete). Decides nothing.
--
-- Secrets travel only on a child's stdin (store) or stdout (lookup, login
-- shell) and stay in this VM's memory. Nothing here logs a secret, a
-- command's output or stderr; user-facing errors are one line with no
-- traceback, details go to the log.

local Auth = require("./lib/auth/auth")
local Keychain = require("./lib/auth/keychain")
local LoginEnv = require("./lib/auth/login_env")

type Platform = Keychain.Platform

export type Done = (ok: boolean, err: string?) -> ()

local M = {}

local probed = false
local platformCache: Platform? = nil

-- name -> value from the login shell ("" when it does not set it).
local loginCache: { [string]: string } = {}
local loginPending: { [string]: { (string?) -> () } } = {}
local loginGeneration = 0

local listeners: { () -> () } = {}

local function warn(what: string, detail: string)
	pcall(tern.log.warn, "tern-grafana credentials: " .. what, detail)
end

local function exists(path: string): boolean
	local ok, yes = pcall(tern.fs.exists, path)
	return ok and yes == true
end

local function onPath(program: string): boolean
	for dir in string.gmatch(tern.getenv("PATH") or "", "[^:]+") do
		if exists(dir .. "/" .. program) then
			return true
		end
	end
	return false
end

function M.os(): string
	local ok, os = pcall(function()
		return tern.runtime.os
	end)
	return if ok and type(os) == "string" then os else "unknown"
end

-- The keychain this machine offers, probed once per VM.
function M.platform(): Platform?
	if not probed then
		local os = M.os()
		platformCache = Keychain.platform({
			os = os,
			security = os == "macos" and exists(Keychain.SECURITY),
			secret_tool = os == "linux" and onPath(Keychain.SECRET_TOOL),
		})
		probed = true
	end
	return platformCache
end

-- Runs argv; `cb(result, spawnError)` exactly once. spawnError is the
-- first line of the raised error (tern.process.run raises when the binary
-- is missing).
local function run(argv: { string }, opts: ProcessOptions, cb: (ProcessResult?, string?) -> ())
	local ok, err = pcall(function()
		tern.process.run(argv, opts, function(result: ProcessResult)
			cb(result, nil)
		end)
	end)
	if not ok then
		warn("could not start " .. argv[1], tostring(err))
		cb(nil, Keychain.firstLine(tostring(err)))
	end
end

local function changed()
	for _, fn in listeners do
		pcall(fn)
	end
end

-- Called after store or delete changed an item (transport_host drops its
-- cached secrets).
function M.onChange(fn: () -> ())
	table.insert(listeners, fn)
end

local function noKeychain(): string
	return Keychain.line(Keychain.explain("keychain_unavailable", { field = "token_keychain", os = M.os() }))
end

-- Adds or replaces `item` with `secret`. `cb(true)` or `cb(false, line)`.
function M.store(item: string, secret: string, cb: Done)
	local found = M.platform()
	if found == nil then
		cb(false, noKeychain())
		return
	end
	local platform: Platform = found :: Platform
	local plan, bad = Keychain.storePlan(platform, item, secret)
	if plan == nil then
		cb(false, bad)
		return
	end
	run(plan.argv, { stdin = plan.stdin, timeout_ms = Keychain.TIMEOUT_MS }, function(result, spawnErr)
		if result and result.status == 0 and not result.timed_out then
			changed()
			cb(true, nil)
		elseif result and result.timed_out then
			cb(false, "Storing the token timed out; an unlock prompt may be waiting, answer it and retry")
		else
			local why = if result then "exit " .. tostring(result.status) else spawnErr or "could not start"
			warn("store " .. item .. " failed", why)
			cb(
				false,
				string.format("Storing the token in the keychain failed (%s); unlock the keychain and retry", why)
			)
		end
	end)
end

-- Removes `item`; a missing item counts as removed.
function M.delete(item: string, cb: Done)
	local found = M.platform()
	if found == nil then
		cb(false, noKeychain())
		return
	end
	local platform: Platform = found :: Platform
	if not Keychain.validItem(item) then
		cb(false, "invalid keychain item name")
		return
	end
	local plan = Keychain.deletePlan(platform, item)
	run(plan.argv, { timeout_ms = Keychain.TIMEOUT_MS }, function(result, spawnErr)
		if result and not result.timed_out and Keychain.deleted(platform, result.status) then
			changed()
			cb(true, nil)
		else
			local why = if result
				then (if result.timed_out then "timed out" else "exit " .. tostring(result.status))
				else spawnErr or "could not start"
			warn("delete " .. item .. " failed", why)
			cb(false, string.format("Removing keychain item %s failed (%s)", item, why))
		end
	end)
end

-- Reads `item` for transport_host: `cb(outcome)` for Auth.secret.
function M.lookup(item: string, cb: (Auth.Outcome) -> ())
	local found = M.platform()
	if found == nil then
		cb({ lookup = "unavailable" })
		return
	end
	local platform: Platform = found :: Platform
	local plan = Keychain.lookupPlan(platform, item)
	run(plan.argv, { timeout_ms = Keychain.TIMEOUT_MS }, function(result, spawnErr)
		if result == nil then
			cb({ error = spawnErr, lookup = "failed" })
		elseif result.timed_out then
			cb({ timed_out = true, status = result.status, lookup = "failed" })
		else
			cb({
				text = result.stdout,
				status = result.status,
				lookup = Keychain.lookupStatus(platform, result.status, result.stdout),
			})
		end
	end)
end

local function settleLogin(name: string, gen: number, value: string?)
	if gen == loginGeneration then
		loginCache[name] = value or ""
	end
	local waiters = loginPending[name]
	loginPending[name] = nil
	if waiters then
		for _, waiter in waiters do
			waiter(value)
		end
	end
end

-- token_env: the daemon's variable, else the login shell's (asked once per
-- name until forget()). `cb(value)`, nil or "" when neither sets it.
function M.env(name: string, cb: (string?) -> ())
	local direct = tern.getenv(name)
	if direct and direct ~= "" then
		cb(direct)
		return
	end
	local hit = loginCache[name]
	if hit then
		cb(hit)
		return
	end
	local waiters = loginPending[name]
	if waiters then
		table.insert(waiters, cb)
		return
	end
	loginPending[name] = { cb }
	local gen = loginGeneration
	local plan = LoginEnv.plan(LoginEnv.shell(tern.getenv("SHELL"), M.os()), name)
	if plan == nil then
		settleLogin(name, gen, nil)
		return
	end
	run(plan.argv, { stdin = plan.stdin, timeout_ms = plan.timeout_ms }, function(result, spawnErr)
		local value = if result then LoginEnv.parse(result.stdout) else nil
		if value == nil then
			warn(
				"login shell did not report " .. name,
				if result
					then "exit " .. tostring(result.status) .. (if result.timed_out then " (timed out)" else "")
					else spawnErr or "could not start"
			)
		end
		settleLogin(name, gen, value)
	end)
end

-- Drops the login-shell answers (config reload).
function M.forget()
	table.clear(loginCache)
	loginGeneration += 1
end

return M
