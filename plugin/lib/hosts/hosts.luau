--!strict
-- Per-host default contexts (config `hosts`, docs/hosts.md): maps a hostname
-- or a glob to the context that blocks and pollers use on that machine when
-- no context is named. The host half resolves its hostname (hosts_host.luau);
-- this module only matches. Hostnames compare case-insensitively, against the
-- full name and its first label, so "web-1" and "web-1.prod.example.com" both
-- match a pattern written either way.
--
-- Precedence: an exact name beats every glob; among globs the longest pattern
-- wins (it is the more specific one), ties broken by fewer wildcards, then by
-- the pattern text, so the choice never depends on table order.

local Route = require("../config/route")
local Types = require("../config/types")

type Config = Types.Config
type Problem = Types.Problem

export type Rule = {
	-- Lower-cased pattern as matched.
	pattern: string,
	context: string,
	glob: boolean,
}

local M = {}

-- Bounds the work per match; a host map is a handful of entries.
M.MAX_RULES = 256
M.MAX_PATTERN = 253

local function problem(problems: { Problem }, path: string, message: string)
	table.insert(problems, { path = if path == "" then "hosts" else "hosts." .. path, message = message })
end

local function wildcards(pattern: string): number
	local _, n = string.gsub(pattern, "[%*%?]", "")
	return n
end

-- "*" matches any run of characters (dots included), "?" exactly one.
local function globToLua(pattern: string): string
	local parts: { string } = { "^" }
	for i = 1, #pattern do
		local c = string.sub(pattern, i, i)
		if c == "*" then
			table.insert(parts, ".*")
		elseif c == "?" then
			table.insert(parts, ".")
		elseif string.match(c, "[%w]") then
			table.insert(parts, c)
		else
			table.insert(parts, "%" .. c)
		end
	end
	table.insert(parts, "$")
	return table.concat(parts)
end

-- The hostname as matched: trimmed, lower-cased, without a trailing dot; nil
-- when empty.
function M.normalize(hostname: string?): string?
	if hostname == nil then
		return nil
	end
	local h = string.lower(string.match(hostname, "^%s*(.-)%s*$") or "")
	h = string.gsub(h, "%.$", "")
	return if h == "" then nil else h
end

-- (rules sorted by precedence, problems). A bad entry is skipped with a
-- problem naming it; the others still apply.
function M.read(config: Config?): ({ Rule }, { Problem })
	local problems: { Problem } = {}
	local rules: { Rule } = {}
	local raw = if config then config.hosts else nil
	if raw == nil or config == nil then
		return rules, problems
	end
	if type(raw) ~= "table" or (next(raw) ~= nil and type((next(raw))) ~= "string") then
		problem(problems, "", 'must be an object mapping hostnames or globs to context names ({"web-*": "prod"})')
		return rules, problems
	end
	local keys: { string } = {}
	for key in raw do
		table.insert(keys, key)
	end
	table.sort(keys)
	local seen: { [string]: string } = {}
	for _, key in keys do
		local value = raw[key]
		local pattern = M.normalize(key)
		if pattern == nil then
			problem(problems, key, "the hostname or glob must not be empty")
		elseif #pattern > M.MAX_PATTERN then
			problem(problems, key, string.format("is longer than %d characters", M.MAX_PATTERN))
		elseif type(value) ~= "string" then
			problem(problems, key, "must be a string naming a context")
		elseif config.contexts[value] == nil then
			local names: { string } = {}
			for name in config.contexts do
				table.insert(names, name)
			end
			table.sort(names)
			problem(problems, key, string.format("no context named %q (defined: %s)", value, table.concat(names, ", ")))
		elseif seen[pattern] then
			problem(problems, key, string.format("repeats %q (hostnames are not case-sensitive)", seen[pattern]))
		elseif #rules >= M.MAX_RULES then
			problem(problems, key, string.format("at most %d entries are read", M.MAX_RULES))
		else
			seen[pattern] = key
			table.insert(rules, { pattern = pattern, context = value, glob = wildcards(pattern) > 0 })
		end
	end
	table.sort(rules, function(a: Rule, b: Rule): boolean
		if a.glob ~= b.glob then
			return not a.glob
		end
		if #a.pattern ~= #b.pattern then
			return #a.pattern > #b.pattern
		end
		local wa, wb = wildcards(a.pattern), wildcards(b.pattern)
		if wa ~= wb then
			return wa < wb
		end
		return a.pattern < b.pattern
	end)
	return rules, problems
end

-- The first rule (in precedence order) matching the hostname, or nil.
function M.match(rules: { Rule }, hostname: string?): Rule?
	local full = M.normalize(hostname)
	if full == nil then
		return nil
	end
	local short = string.match(full, "^[^%.]+") or full
	for _, rule in rules do
		if rule.glob then
			local lua = globToLua(rule.pattern)
			if string.match(full, lua) or string.match(short, lua) then
				return rule
			end
		elseif rule.pattern == full or rule.pattern == short then
			return rule
		end
	end
	return nil
end

-- The context `hosts` assigns to this hostname, or nil.
function M.defaultContext(config: Config?, hostname: string?): string?
	local rules = M.read(config)
	local rule = M.match(rules, hostname)
	return if rule then rule.context else nil
end

-- The config pure code should see on this host: default_context replaced by
-- the host default (lib/config/route precedence), so every reader of
-- default_context (blocks, pollers, routes) honors it. The same table comes
-- back when nothing changes.
function M.apply(config: Config?, hostname: string?): Config?
	if config == nil then
		return nil
	end
	local effective = Route.defaultContext(config, M.defaultContext(config, hostname))
	if effective == config.default_context then
		return config
	end
	local out = table.clone(config)
	out.default_context = effective
	return out
end

return M
