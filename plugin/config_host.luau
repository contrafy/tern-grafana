--!strict
-- Host adapter for lib/config/validate: finds and reads the user's config
-- file and keeps the parsed result. `load()` reads the file again (block
-- init, settings) but re-parses only when its text changed; `current()` never
-- touches the disk. A file that does not exist, cannot be read or does not
-- validate yields no config at all (lib/config/validate rejects a partial
-- one), with problems that say why.

local TransportHost = require("./transport_host")
local Types = require("./lib/config/types")
local Validate = require("./lib/config/validate")

type Config = Types.Config
type Problem = Types.Problem

local M = {}

-- Far above any real config; bounds what a mistaken path can make us read.
M.MAX_BYTES = 262144

type Snapshot = { config: Config?, problems: { Problem }, path: string?, text: string? }

local snapshot: Snapshot = { config = nil, problems = {}, path = nil, text = nil }

local function env(name: string): string?
	local ok, v = pcall(tern.getenv, name)
	return if ok and v ~= "" then v else nil
end

local function problem(message: string): { Problem }
	return { { path = "", message = message } }
end

-- (text, problems): text nil when the file could not be read.
local function read(path: string): (string?, { Problem })
	local okExists, exists = pcall(tern.fs.exists, path)
	if okExists and not exists then
		return nil,
			problem(
				string.format(
					"%s does not exist; create it (see docs/configuration.md) or use the settings block",
					path
				)
			)
	end
	local ok, text = pcall(tern.fs.read, path, M.MAX_BYTES)
	if not ok then
		return nil,
			problem(
				string.format(
					"could not read %s: %s (it must be a regular file of at most %d bytes)",
					path,
					tostring(text),
					M.MAX_BYTES
				)
			)
	end
	return text, {}
end

local function apply(path: string?, force: boolean): (Config?, { Problem }, string?)
	if path == nil then
		snapshot = {
			config = nil,
			problems = problem("neither XDG_CONFIG_HOME nor HOME is set, so the config file cannot be found"),
			path = nil,
			text = nil,
		}
		return snapshot.config, snapshot.problems, snapshot.path
	end
	local text, problems = read(path)
	if not force and text ~= nil and text == snapshot.text and path == snapshot.path then
		return snapshot.config, snapshot.problems, snapshot.path
	end
	local config: Config? = nil
	if text then
		config, problems = Validate.parseFile(text, tern.json.decode)
	end
	local changed = text ~= snapshot.text or path ~= snapshot.path
	snapshot = { config = config, problems = problems, path = path, text = text }
	if changed or force then
		-- Endpoints or credential sources may have changed: resolve again.
		TransportHost.forget()
		for _, p in problems do
			pcall(tern.log.warn, "tern-grafana config: " .. Validate.format(p))
		end
	end
	return config, problems, path
end

local function configPath(): string?
	return Validate.path({ XDG_CONFIG_HOME = env("XDG_CONFIG_HOME"), HOME = env("HOME") })
end

-- Reads the file; re-parses only when its text changed.
function M.load(): (Config?, { Problem }, string?)
	return apply(configPath(), false)
end

-- Reads and re-parses the file and drops cached credentials (after the
-- settings block wrote it, or when the user asks for a reload).
function M.reload(): (Config?, { Problem }, string?)
	return apply(configPath(), true)
end

-- The last loaded config; no I/O.
function M.current(): (Config?, { Problem }, string?)
	return snapshot.config, snapshot.problems, snapshot.path
end

M.load()

return M
