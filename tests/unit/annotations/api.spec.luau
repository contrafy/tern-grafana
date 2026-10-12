--!strict
-- The annotation body is what Grafana stores and shows on every dashboard of
-- the org (or the configured one): it must have the shape Grafana 11 and 12
-- accept (checked against the recorded create request), span the command's
-- run, carry the configured tags plus the kind, and hold only the redacted
-- line. The pairing decides the start time and cwd, so a finish whose start
-- was missed must still give a sane time range.
local Api = require("../../../plugin/lib/annotations/api")
local Command = require("../../../plugin/lib/annotations/command")
local Fixtures = require("../../lib/fixtures")
local Pairing = require("../../../plugin/lib/annotations/pairing")
local Settings = require("../../../plugin/lib/annotations/settings")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local VERSIONS = { "11.6.16", "12.4.12" }

local function list(...: any): { any }
	return { ... }
end

local function env(): any
	return { now_ms = 0, decode = json.decode, encode = json.encode, null = json.null }
end

local function settings(raw: any): Settings.Settings
	local s = Settings.read({ version = 1, contexts = { lab = {} }, annotations = raw } :: any)
	return s
end

local function sortedKeys(t_: { [string]: any }): { string }
	local out = {}
	for k in t_ do
		table.insert(out, k)
	end
	table.sort(out)
	return out
end

describe("annotations api body", function()
	for _, v in VERSIONS do
		it("matches the recorded create request on Grafana " .. v, function()
			local recorded = json.decode(Fixtures.read("grafana/" .. v .. "/annotation_create.request.json"))
			local d: Api.Draft = {
				context = "lab",
				kind = "kubectl-apply",
				line = recorded.text,
				status = 0,
				took_ms = 900,
				time_ms = recorded.time,
				time_end_ms = recorded.time + 900,
				tags = recorded.tags,
				dashboard_uid = recorded.dashboardUID,
				panel_id = recorded.panelId,
				text = recorded.text,
			}
			local req = Api.request(d, json.encode)
			expect(req.method).toBe("POST")
			expect(req.path).toBe("/api/annotations")
			expect((req.headers :: any)["Content-Type"]).toBe("application/json")
			local body = json.decode(req.body :: string)
			local expected = table.clone(recorded)
			expected.timeEnd = recorded.time + 900
			expect(body).toEqual(expected)
			expect(sortedKeys(body)).toEqual({ "dashboardUID", "panelId", "tags", "text", "time", "timeEnd" })
		end)

		it("reads the created id from Grafana " .. v, function()
			expect(Api.parseCreated(env(), Fixtures.read("grafana/" .. v .. "/annotation_create.json"))).toBe(9)
		end)
	end

	it("posts org-wide without dashboardUID/panelId when no dashboard is configured", function()
		local run = Pairing.finished(Pairing.new(), 1, "helm upgrade web ./chart", 0, 2000, 1791577900000)
		local m = Command.match(run.line, Command.compileAll(Command.DEFAULT_PATTERNS)) :: Command.Match
		local d = Api.draft(run, m, settings({ enabled = true }), "lab", {})
		expect(sortedKeys(Api.body(d))).toEqual({ "tags", "text", "time", "timeEnd" })
	end)
end)

describe("annotations draft", function()
	local p = Pairing.new()
	Pairing.started(p, 7, "DB_PASSWORD=x helm upgrade web ./chart -n shop", "/home/me/src/shop-deploy", 1000000)
	local run = Pairing.finished(p, 7, "DB_PASSWORD=x helm upgrade web ./chart -n shop", 0, 61500, 1062000)
	local m = Command.match(run.line, Command.compileAll(Command.DEFAULT_PATTERNS)) :: Command.Match
	local d = Api.draft(
		run,
		m,
		settings({ enabled = true, tags = { "tern", "deploy", "prod" }, dashboard_uid = "ops", panel_id = 4 }),
		"lab",
		{ user = "ahmad", sha = "abc1234" }
	)

	it("spans the command from its start to its finish", function()
		expect(d.time_ms).toBe(1000000)
		expect(d.time_end_ms).toBe(1062000)
	end)

	it("tags with the configured tags plus the command kind", function()
		expect(d.tags).toEqual({ "tern", "deploy", "prod", "helm-upgrade" })
	end)

	it("writes the redacted line, outcome, dir, sha and user into the text", function()
		expect(d.text).toBe(
			"DB_PASSWORD=*** helm upgrade web ./chart -n shop\nsucceeded after 1m 01s, dir shop-deploy, git abc1234, by ahmad"
		)
		expect((string.find(d.text, "=x ", 1, true))).toBeNil()
	end)

	it("says how a failed command ended", function()
		local failed = table.clone(run)
		failed.status = 2
		local fd = Api.draft(failed, m, settings({ enabled = true }), "lab", {})
		expect(fd.text).toBe(
			"DB_PASSWORD=*** helm upgrade web ./chart -n shop\nfailed (exit 2) after 1m 01s, dir shop-deploy"
		)
	end)

	it("keeps the dashboard and panel when configured", function()
		local body = Api.body(d)
		expect(body.dashboardUID).toBe("ops")
		expect(body.panelId).toBe(4)
	end)
end)

describe("annotations pairing", function()
	it("pairs start and finish per pane, so interleaved panes keep their own cwd", function()
		local p = Pairing.new()
		Pairing.started(p, 1, "helm upgrade a .", "/srv/a", 100)
		Pairing.started(p, 2, "kubectl apply -f b", "/srv/b", 150)
		local b = Pairing.finished(p, 2, "kubectl apply -f b", 0, 40, 190)
		local a = Pairing.finished(p, 1, "helm upgrade a .", 1, 300, 400)
		expect(list(b.cwd, b.started_ms, b.paired)).toEqual(list("/srv/b", 150, true))
		expect(list(a.cwd, a.started_ms, a.status, a.paired)).toEqual(list("/srv/a", 100, 1, true))
	end)

	it("derives the start from took_ms and drops the cwd when the start was missed", function()
		local p = Pairing.new()
		local r = Pairing.finished(p, 3, "terraform apply", 0, 5000, 20000)
		expect(list(r.cwd, r.started_ms, r.paired)).toEqual(list(nil, 15000, false))
	end)

	it("does not pair a finish with a different line's start", function()
		local p = Pairing.new()
		Pairing.started(p, 4, "ls", "/tmp", 100)
		local r = Pairing.finished(p, 4, "helm upgrade x .", 0, 10, 500)
		expect(r.paired).toBe(false)
		expect(r.cwd).toBeNil()
		-- The stale start is consumed: the next finish on the pane is unpaired too.
		expect(Pairing.finished(p, 4, "ls", 0, 1, 600).paired).toBe(false)
	end)

	it("bounds the panes it remembers", function()
		local p = Pairing.new()
		for i = 1, Pairing.MAX_PANES + 10 do
			Pairing.started(p, i, "x", nil, i)
		end
		expect(p.count).toBe(Pairing.MAX_PANES)
		expect(Pairing.finished(p, 1, "x", 0, 0, 1000).paired).toBe(false)
		expect(Pairing.finished(p, Pairing.MAX_PANES + 10, "x", 0, 0, 1000).paired).toBe(true)
	end)
end)

describe("annotations git facts", function()
	it("reads git's short sha and ignores failures", function()
		expect(Api.gitArgv("/srv/a")).toEqual({ "git", "-C", "/srv/a", "rev-parse", "--short", "HEAD" })
		expect(Api.parseSha(0, "abc1234\n")).toBe("abc1234")
		expect(Api.parseSha(128, "fatal: not a git repository\n")).toBeNil()
		expect(Api.parseSha(0, "HEAD\n")).toBeNil()
	end)
end)

return nil
