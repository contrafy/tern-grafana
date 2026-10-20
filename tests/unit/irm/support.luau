--!strict
-- Shared helpers for the IRM specs: a config with one Grafana context, the
-- scrubbed fixtures captured from a Grafana Cloud stack running IRM 0.128.0
-- (tests/fixtures/irm/0.128.0) and the docs-based write responses
-- (tests/fixtures/irm/docs), and a driver that answers a machine's requests.
local Fixtures = require("../../lib/fixtures")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")

local M = {}

M.NOW = 1792440000000 -- 2026-10-19T20:00:00Z, after every capture
M.V = "irm/0.128.0/"
M.DOCS = "irm/docs/"
M.GRAFANA = "https://stack.example.grafana.net"
-- The scrubbed settings fixture's onCallApiUrl.
M.ONCALL = "https://example.invalid/irm/2"

function M.config(extra: string?): any
	local cfg, problems = Validate.parseFile(
		string.format(
			[[{"default_context": "cloud", "contexts": {
			"cloud": {"grafana": {"url": "%s", "auth": {"type": "bearer", "token_env": "GRAFANA_TOKEN"}}},
			"lab": {"grafana": {"url": "http://localhost:3000"}},
			"prom": {"prometheus": {"url": "http://p:9090"}}}%s}]],
			M.GRAFANA,
			if extra then ", " .. extra else ""
		),
		json.decode
	)
	assert(cfg, problems[1] and Validate.format(problems[1]))
	return cfg
end

function M.env(cfg: any?): any
	return {
		now_ms = M.NOW,
		local_offset_min = 0,
		decode = json.decode,
		encode = json.encode,
		null = json.null,
		config = cfg or M.config(),
	}
end

function M.ok(path: string, status: number?): any
	return { status = status or 200, headers = {}, body = Fixtures.read(path), timed_out = false }
end

function M.raw(body: string, status: number): any
	return { status = status, headers = {}, body = body, timed_out = false }
end

function M.key(text: string, name: string?): any
	return {
		name = name or text,
		text = if name then nil else text,
		ctrl = false,
		alt = false,
		shift = false,
		meta = false,
	}
end

-- Whether an http effect writes: any OnCall POST, or an Incident API call
-- that is not a query.
function M.isWrite(e: any): boolean
	if e.kind ~= "http" then
		return false
	end
	local path: string = e.request.path
	local method = string.match(path, "/api/v1/[%a]+%.(%a+)$")
	if method then
		return not (string.find(method, "^Query") or string.find(method, "^Get"))
	end
	return e.request.method ~= "GET"
end

function M.writes(effects: { any }): { any }
	local out = {}
	for _, e in effects do
		if M.isWrite(e) then
			table.insert(out, e)
		end
	end
	return out
end

function M.find(effects: { any }, kind: string): any
	for _, e in effects do
		if e.kind == kind then
			return e
		end
	end
	return nil
end

-- Answers every read request among `effects` (and the ones their answers
-- trigger) with `respond(name, effect)`, the tag without its generation
-- prefix; returns every effect the answers produced. Writes are never
-- answered here.
function M.drive(update: any, s: any, effects: { any }, env: any, respond: (string, any) -> any): { any }
	local out = {}
	local queue = table.clone(effects)
	local i = 1
	while i <= #queue do
		local e = queue[i]
		i += 1
		if e.kind == "http" and not M.isWrite(e) then
			local name = string.match(e.tag, "^%d+:(.+)$") or e.tag
			local response = respond(name, e)
			if response then
				local _, more = update(s, { kind = "http_done", tag = e.tag, response = response }, env)
				for _, m in more do
					table.insert(out, m)
					table.insert(queue, m)
				end
			end
		end
	end
	return out
end

-- The view as JSON text, for "the user can read X" checks.
function M.text(view: any): string
	return json.encode(view)
end

function M.has(text: string, needle: string): boolean
	return string.find(text, needle, 1, true) ~= nil
end

return M
