--!strict
-- Host adapter for lib/hosts: resolves this host's hostname once per host VM
-- (HOSTNAME from the daemon's environment, else `hostname`) and hands pure
-- code the config with the per-host default context applied. On a remote
-- daemon this runs on the remote machine, so its own hostname decides.
-- Until `hostname` answers (milliseconds after the host starts) no host
-- default applies.

local Hosts = require("./lib/hosts/hosts")
local Types = require("./lib/config/types")
local Validate = require("./lib/config/validate")

type Config = Types.Config

local M = {}

M.HOSTNAME_TIMEOUT_MS = 2000

local hostname: string? = nil
local lastIn: Config? = nil
local lastOut: Config? = nil
local warnedFor: Config? = nil

local function resolve()
	local okEnv, env = pcall(tern.getenv, "HOSTNAME")
	if okEnv and Hosts.normalize(env) then
		hostname = Hosts.normalize(env)
		return
	end
	local ok, err = pcall(function()
		tern.process.run({ "hostname" }, { timeout_ms = M.HOSTNAME_TIMEOUT_MS }, function(r: ProcessResult)
			if r.status == 0 then
				hostname = Hosts.normalize(r.stdout)
				lastIn, lastOut = nil, nil
			else
				pcall(tern.log.warn, "tern-grafana hosts: `hostname` failed", r.status)
			end
		end)
	end)
	if not ok then
		pcall(tern.log.warn, "tern-grafana hosts: `hostname` failed", tostring(err))
	end
end

-- This host's hostname, lower-cased; nil until resolved.
function M.hostname(): string?
	return hostname
end

-- `config` with default_context set to this host's default; cached per config.
function M.apply(config: Config?): Config?
	if config == nil then
		return nil
	end
	if config == lastIn then
		return lastOut
	end
	if warnedFor ~= config then
		warnedFor = config
		local _, problems = Hosts.read(config)
		for _, p in problems do
			pcall(tern.log.warn, "tern-grafana config: " .. Validate.format(p))
		end
	end
	local out = Hosts.apply(config, hostname)
	if hostname ~= nil then
		lastIn, lastOut = config, out
	end
	return out
end

resolve()

return M
