--!strict
-- The Info tab's data: build (/status/buildinfo), runtime
-- (/status/runtimeinfo), command-line flags (/status/flags) and a summary of
-- the loaded configuration (/status/config). Prometheus redacts secrets in
-- the config as <secret>; the summary still keeps to structure and counts
-- (no URLs), so nothing credential-shaped reaches the view.

local Env = require("../env")
local Range = require("../time/range")

type Env = Env.Env

export type Build = {
	version: string?,
	revision: string?,
	branch: string?,
	build_date: string?,
	go_version: string?,
}

export type Runtime = {
	start_ms: number?,
	cwd: string?,
	hostname: string?,
	reload_ok: boolean?,
	last_config_ms: number?,
	corruptions: number?,
	goroutines: number?,
	gomaxprocs: number?,
	gomemlimit: number?,
	gogc: string?,
	retention: string?,
}

export type Flag = { name: string, value: string }

export type ConfigSummary = {
	lines: number,
	scrape_interval: string?,
	scrape_timeout: string?,
	evaluation_interval: string?,
	external_labels: { { name: string, value: string } },
	jobs: { string },
	rule_files: { string },
	alertmanagers: number,
	remote_write: number,
	remote_read: number,
}

local M = {}

-- Flags worth seeing first (most flags are defaults nobody changed).
M.KEY_FLAGS = table.freeze({
	"config.file",
	"storage.tsdb.path",
	"storage.tsdb.retention.time",
	"storage.tsdb.retention.size",
	"web.listen-address",
	"web.external-url",
	"web.enable-lifecycle",
	"web.enable-admin-api",
	"web.enable-remote-write-receiver",
	"enable-feature",
	"query.timeout",
	"query.max-concurrency",
	"log.level",
	"agent",
})

local function str(env: Env, v: any): string?
	v = Env.value(env, v)
	return if type(v) == "string" then v else nil
end

local function num(env: Env, v: any): number?
	v = Env.value(env, v)
	return if type(v) == "number" then v else nil
end

local function time(env: Env, v: any): number?
	local s = str(env, v)
	if s == nil or s == "" or string.sub(s, 1, 4) == "0001" then
		return nil
	end
	return (Range.parse(s, false, { now_ms = env.now_ms }))
end

function M.build(data: any, env: Env): Build
	local d = if type(data) == "table" then data else {}
	return {
		version = str(env, d.version),
		revision = str(env, d.revision),
		branch = str(env, d.branch),
		build_date = str(env, d.buildDate),
		go_version = str(env, d.goVersion),
	}
end

function M.runtime(data: any, env: Env): Runtime
	local d = if type(data) == "table" then data else {}
	local reload = Env.value(env, d.reloadConfigSuccess)
	-- GOGC is a string on current servers and was a number on older ones.
	local gogc = Env.value(env, d.GOGC)
	return {
		start_ms = time(env, d.startTime),
		cwd = str(env, d.CWD),
		hostname = str(env, d.hostname),
		reload_ok = if type(reload) == "boolean" then reload else nil,
		last_config_ms = time(env, d.lastConfigTime),
		corruptions = num(env, d.corruptionCount),
		goroutines = num(env, d.goroutineCount),
		gomaxprocs = num(env, d.GOMAXPROCS),
		gomemlimit = num(env, d.GOMEMLIMIT),
		gogc = if type(gogc) == "string" then gogc elseif type(gogc) == "number" then tostring(gogc) else nil,
		retention = str(env, d.storageRetention),
	}
end

-- Sorted by name.
function M.flags(data: any, env: Env): { Flag }
	local out: { Flag } = {}
	if type(data) == "table" then
		for name, value in data do
			local v = Env.value(env, value)
			if type(name) == "string" and type(v) == "string" then
				table.insert(out, { name = name, value = v })
			end
		end
	end
	table.sort(out, function(a: Flag, b: Flag): boolean
		return a.name < b.name
	end)
	return out
end

-- The key flags present in `flags`, in KEY_FLAGS order.
function M.keyFlags(flags: { Flag }): { Flag }
	local byName: { [string]: Flag } = {}
	for _, f in flags do
		byName[f.name] = f
	end
	local out: { Flag } = {}
	for _, name in M.KEY_FLAGS do
		local f = byName[name]
		if f then
			table.insert(out, f)
		end
	end
	return out
end

local function scalar(raw: string): string
	local v = string.gsub(raw, "^%s+", "")
	v = string.gsub(v, "%s+$", "")
	local quoted = string.match(v, '^"(.*)"$') or string.match(v, "^'(.*)'$")
	return quoted or v
end

-- Prometheus marshals its config back to YAML in one canonical layout (two
-- space indents, top-level keys at column 0, lists as `- ` at the parent's
-- indent), so a line scan is enough for a summary; nothing here is a
-- general YAML parser.
function M.configSummary(yaml: string): ConfigSummary
	local s: ConfigSummary = {
		lines = 0,
		external_labels = {},
		jobs = {},
		rule_files = {},
		alertmanagers = 0,
		remote_write = 0,
		remote_read = 0,
	}
	local top = ""
	local sub = ""
	for line in string.gmatch(yaml, "[^\n]+") do
		s.lines += 1
		local key = string.match(line, "^([%w_]+):")
		if key then
			top = key
			sub = ""
			continue
		end
		local indent, rest = string.match(line, "^( *)(.*)$")
		local depth = #(indent :: string)
		local body = rest :: string
		if top == "global" then
			local k, v = string.match(body, "^([%w_]+):%s*(.*)$")
			if depth == 2 and k then
				sub = k :: string
				if k == "scrape_interval" then
					s.scrape_interval = scalar(v :: string)
				elseif k == "scrape_timeout" then
					s.scrape_timeout = scalar(v :: string)
				elseif k == "evaluation_interval" then
					s.evaluation_interval = scalar(v :: string)
				end
			elseif depth == 4 and sub == "external_labels" and k then
				table.insert(s.external_labels, { name = k :: string, value = scalar(v :: string) })
			end
		elseif top == "scrape_configs" then
			local job = string.match(body, "^%- job_name:%s*(.*)$")
			if depth == 0 and job then
				table.insert(s.jobs, scalar(job))
			end
		elseif top == "rule_files" then
			local file = string.match(body, "^%- (.*)$")
			if depth == 0 and file then
				table.insert(s.rule_files, scalar(file))
			end
		elseif top == "alerting" then
			local k = string.match(body, "^([%w_]+):")
			if depth == 2 and k then
				sub = k :: string
			elseif sub == "alertmanagers" and depth == 2 and string.sub(body, 1, 2) == "- " then
				s.alertmanagers += 1
			end
		elseif top == "remote_write" and depth == 0 and string.sub(body, 1, 2) == "- " then
			s.remote_write += 1
		elseif top == "remote_read" and depth == 0 and string.sub(body, 1, 2) == "- " then
			s.remote_read += 1
		end
	end
	return s
end

-- The `yaml` member of /status/config data.
function M.configYaml(data: any, env: Env): string?
	return if type(data) == "table" then str(env, data.yaml) else nil
end

return M
