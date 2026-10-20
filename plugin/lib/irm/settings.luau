--!strict
-- The `irm` section of the config file (docs/configuration.md, docs/irm.md).
-- A bad value falls back to its default with a problem that names the path,
-- so one typo never turns the IRM status segment off.

local Types = require("../config/types")

type Config = Types.Config
type Problem = Types.Problem

export type Settings = {
	-- Seconds between background polls; 0 turns polling (and the segment) off.
	poll_s: number,
	-- Contexts the background poller reads (each needs a grafana endpoint).
	contexts: { string },
	-- Keep who is on call now (usernames) in the kv summary.
	names: boolean,
	-- The user's own email (lower-cased), matched against OnCall users'
	-- emails: the token is a service account, so IRM has no "you" of its own.
	user: string?,
}

local M = {}

M.DEFAULT_POLL_S = 60
-- OnCall allows 300 requests a minute per token, shared with every other
-- client of that token; one poll sends about six.
M.MIN_POLL_S = 30
M.MAX_CONTEXTS = 8

local KNOWN = { poll_s = true, contexts = true, names = true, user = true }

M.MAX_EMAIL = 254

local function problem(problems: { Problem }, path: string, message: string)
	table.insert(problems, { path = if path == "" then "irm" else "irm." .. path, message = message })
end

function M.read(config: Config?): (Settings, { Problem })
	local problems: { Problem } = {}
	local settings: Settings = { poll_s = M.DEFAULT_POLL_S, contexts = {}, names = true, user = nil }
	local default = if config then config.default_context else nil
	if default and config and config.contexts[default] and config.contexts[default].grafana then
		settings.contexts = { default }
	end
	local raw = if config then config.irm else nil
	if raw == nil then
		return settings, problems
	end
	if type(raw) ~= "table" then
		problem(problems, "", "must be an object")
		return settings, problems
	end
	for key in raw do
		if not KNOWN[key] then
			problem(problems, tostring(key), "unknown key (known: contexts, names, poll_s, user)")
		end
	end
	if raw.poll_s ~= nil then
		local n = raw.poll_s
		if type(n) ~= "number" or n ~= math.floor(n) or n < 0 then
			problem(problems, "poll_s", "must be a whole number of seconds (0 turns polling off)")
		elseif n > 0 and n < M.MIN_POLL_S then
			problem(problems, "poll_s", string.format("must be 0 or at least %d", M.MIN_POLL_S))
			settings.poll_s = M.MIN_POLL_S
		else
			settings.poll_s = n
		end
	end
	if raw.names ~= nil then
		if type(raw.names) == "boolean" then
			settings.names = raw.names
		else
			problem(problems, "names", "must be true or false")
		end
	end
	if raw.user ~= nil then
		local email = if type(raw.user) == "string" then string.match(raw.user, "^%s*(.-)%s*$") else nil
		if email and #email <= M.MAX_EMAIL and string.match(email, "^[^%s@]+@[^%s@]+%.[^%s@]+$") then
			settings.user = string.lower(email)
		else
			problem(problems, "user", "must be your email address as IRM knows it (name@example.com)")
		end
	end
	if raw.contexts ~= nil then
		if type(raw.contexts) ~= "table" then
			problem(problems, "contexts", "must be a list of context names")
		else
			local out: { string } = {}
			for _, name in raw.contexts do
				local ctx = if type(name) == "string" and config then config.contexts[name] else nil
				if type(name) ~= "string" then
					problem(problems, "contexts", "must be a list of context names")
				elseif ctx == nil then
					problem(problems, "contexts", string.format("no context named %q", name))
				elseif ctx.grafana == nil then
					problem(problems, "contexts", string.format("context %q has no grafana endpoint", name))
				elseif #out >= M.MAX_CONTEXTS then
					problem(problems, "contexts", string.format("at most %d contexts are polled", M.MAX_CONTEXTS))
					break
				elseif not table.find(out, name) then
					table.insert(out, name)
				end
			end
			settings.contexts = out
		end
	end
	return settings, problems
end

return M
