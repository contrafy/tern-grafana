--!strict
-- The annotation a finished deploy command becomes, and Grafana's
-- `POST /api/annotations` request for it (same body on Grafana 11 and 12).
-- The draft holds only the redacted command line: it is shown in the approve
-- block, kept in host memory until the user decides, and sent to Grafana.

local Command = require("./command")
local Env = require("../env")
local Pairing = require("./pairing")
local Settings = require("./settings")
local TransportTypes = require("../transport/types")

type Env = Env.Env
type Request = TransportTypes.Request

export type Facts = {
	-- Login name on the machine that ran the command.
	user: string?,
	-- Short commit of the cwd's git repository.
	sha: string?,
}

export type Draft = {
	context: string,
	-- "helm-upgrade", "kubectl-rollout-restart", ...
	kind: string,
	-- The redacted command line.
	line: string,
	status: number,
	took_ms: number,
	cwd_basename: string?,
	user: string?,
	sha: string?,
	namespace: string?,
	service: string?,
	time_ms: number,
	time_end_ms: number,
	tags: { string },
	dashboard_uid: string?,
	panel_id: number?,
	text: string,
}

local M = {}

M.PATH = "/api/annotations"
M.JSON_HEADERS = table.freeze({ ["Content-Type"] = "application/json" })
-- Grafana stores any length; a pasted script line should not become a wall.
M.MAX_LINE = 1000

-- "12.3s", "4m 05s", "1h 02m".
function M.duration(ms: number): string
	local s = ms / 1000
	if s < 60 then
		return string.format("%.1fs", s)
	end
	local total = math.floor(s)
	if total < 3600 then
		return string.format("%dm %02ds", total // 60, total % 60)
	end
	return string.format("%dh %02dm", total // 3600, (total % 3600) // 60)
end

local function oneLine(s: string): string
	return (string.gsub(s, "[%c]+", " "))
end

local function clip(s: string, n: number): string
	if #s <= n then
		return s
	end
	return string.sub(s, 1, n - 3) .. "..."
end

-- The annotation text: the command, then how it ended and where it ran.
function M.text(d: Draft): string
	local outcome = if d.status == 0
		then string.format("succeeded after %s", M.duration(d.took_ms))
		else string.format("failed (exit %d) after %s", d.status, M.duration(d.took_ms))
	local facts = { outcome }
	if d.cwd_basename then
		table.insert(facts, "dir " .. d.cwd_basename)
	end
	if d.sha then
		table.insert(facts, "git " .. d.sha)
	end
	if d.user then
		table.insert(facts, "by " .. d.user)
	end
	return d.line .. "\n" .. table.concat(facts, ", ")
end

-- The tags: the configured ones, then the command kind (deduplicated).
function M.tags(settings: Settings.Settings, kind: string): { string }
	local out: { string } = {}
	for _, t in settings.tags do
		if not table.find(out, t) then
			table.insert(out, t)
		end
	end
	if not table.find(out, kind) then
		table.insert(out, kind)
	end
	return out
end

local function clean(v: string?): string?
	if v == nil then
		return nil
	end
	local s = string.match(oneLine(v), "^%s*(.-)%s*$") or ""
	return if s == "" then nil else clip(s, 128)
end

function M.draft(
	run: Pairing.Run,
	match: Command.Match,
	settings: Settings.Settings,
	context: string,
	facts: Facts
): Draft
	local d: Draft = {
		context = context,
		kind = match.kind,
		line = clip(oneLine(Command.redact(run.line)), M.MAX_LINE),
		status = run.status,
		took_ms = run.took_ms,
		cwd_basename = if run.cwd then clean(Command.basename(run.cwd :: string)) else nil,
		user = clean(facts.user),
		sha = if facts.sha and string.match(facts.sha, "^%x+$") then facts.sha else nil,
		namespace = match.namespace,
		service = match.service,
		time_ms = math.floor(run.started_ms),
		time_end_ms = math.floor(math.max(run.finished_ms, run.started_ms)),
		tags = M.tags(settings, match.kind),
		dashboard_uid = settings.dashboard_uid,
		panel_id = settings.panel_id,
		text = "",
	}
	d.text = M.text(d)
	return d
end

-- The JSON body of POST /api/annotations.
function M.body(d: Draft): { [string]: any }
	local body: { [string]: any } = {
		time = d.time_ms,
		timeEnd = d.time_end_ms,
		tags = table.clone(d.tags),
		text = d.text,
	}
	if d.dashboard_uid then
		body.dashboardUID = d.dashboard_uid
		if d.panel_id then
			body.panelId = d.panel_id
		end
	end
	return body
end

function M.request(d: Draft, encode: (any) -> string): Request
	return { method = "POST", path = M.PATH, headers = M.JSON_HEADERS :: any, body = encode(M.body(d)) }
end

-- Grafana answers `{"id": 9, "message": "Annotation added"}`.
function M.parseCreated(env: Env, body: string): number?
	local ok, doc = pcall(env.decode, body)
	if not ok or type(doc) ~= "table" then
		return nil
	end
	local id = Env.value(env, doc.id)
	return if type(id) == "number" then id else nil
end

-- `git rev-parse --short HEAD` in `cwd` (never through a shell).
function M.gitArgv(cwd: string): { string }
	return { "git", "-C", cwd, "rev-parse", "--short", "HEAD" }
end

-- The short SHA from git's stdout, or nil (not a repository, no commits).
function M.parseSha(status: number, stdout: string): string?
	if status ~= 0 then
		return nil
	end
	local sha = string.match(stdout, "^%s*(%x+)%s*$")
	return if sha and #sha >= 4 and #sha <= 40 then sha else nil
end

return M
