--!strict
-- The one rule every credential path shares: a token reaches exactly two
-- places, the stdin of the command that stores it and the Authorization
-- header of a request (on curl's stdin when curl sends it). It never reaches
-- argv (readable by every local user through ps), plans, error messages,
-- hints or anything else a view, log or screenshot could show. This walks
-- every effect the auth code produces for one test token.
local Auth = require("../../../plugin/lib/auth/auth")
local Curl = require("../../../plugin/lib/transport/curl")
local Http = require("../../../plugin/lib/transport/http")
local Keychain = require("../../../plugin/lib/auth/keychain")
local LoginEnv = require("../../../plugin/lib/auth/login_env")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local TOKEN = 'glsa_T0k3n "q" \\b'

-- Every string anywhere inside `v`.
local function strings(v: any, out: { string }?): { string }
	local acc = out or {}
	if type(v) == "string" then
		table.insert(acc, v)
	elseif type(v) == "table" then
		for k, x in v do
			strings(k, acc)
			strings(x, acc)
		end
	end
	return acc
end

local function leaks(v: any): boolean
	for _, s in strings(v) do
		if string.find(s, "glsa_T0k3n", 1, true) then
			return true
		end
	end
	return false
end

local SOURCES: { any } = {
	{ from = "keychain", field = "token_keychain", item = "cloud/grafana" },
	{ from = "env", field = "token_env", name = "GRAFANA_TOKEN" },
	{ from = "cmd", field = "token_cmd", argv = { "op", "read", "op://Work/Grafana/token" } },
	{ from = "file", field = "token_file", path = "~/.config/tern-grafana/token" },
}

-- Outcomes that carry the token where the host saw it, for every way a
-- resolution can end.
local OUTCOMES: { any } = {
	{ text = TOKEN .. "\n", status = 0, lookup = "found" },
	{ text = TOKEN .. "\nmore", status = 0, lookup = "found" },
	{ text = TOKEN, status = 1, lookup = "failed" },
	{ text = TOKEN, status = 44, lookup = "missing" },
	{ text = TOKEN, timed_out = true, status = -1, lookup = "failed" },
	{ lookup = "unavailable" },
	{ text = "" },
	{ error = "runtime error: tern.process.run op: No such file or directory (os error 2)\nstack traceback:" },
}

describe("a test token", function()
	it("is only on the stdin of the store command, on every platform", function()
		for _, name in { "macos", "linux" } do
			local platform: Keychain.Platform = name :: any
			local store = Keychain.storePlan(platform, "cloud/grafana", TOKEN) :: Keychain.Plan
			expect(leaks(store.argv)).toBe(false)
			expect(leaks(store.stdin)).toBe(true)
			expect(leaks(Keychain.lookupPlan(platform, "cloud/grafana"))).toBe(false)
			expect(leaks(Keychain.deletePlan(platform, "cloud/grafana"))).toBe(false)
		end
	end)

	it("never appears in a resolution plan or a login-shell command", function()
		for _, source in SOURCES do
			expect(leaks((Auth.plan({ type = "bearer", token = source }, "/home/u")))).toBe(false)
		end
		expect(leaks(LoginEnv.plan("/bin/zsh", "GRAFANA_TOKEN"))).toBe(false)
	end)

	it("never appears in an explanation, whatever the host observed", function()
		for _, source in SOURCES do
			local plan = Auth.plan({ type = "bearer", token = source }, "/home/u") :: Auth.Plan
			for _, outcome in OUTCOMES do
				local secret, err = Auth.secret(plan, outcome, { context = "cloud", os = "macos" })
				if secret == nil then
					expect(leaks(err)).toBe(false)
				end
			end
		end
	end)

	it("reaches a request only as the Authorization header, and curl only on stdin", function()
		local endpoint: any = {
			url = "https://example.grafana.net",
			path_prefix = "",
			headers = { ["X-Scope-OrgID"] = "1" },
			auth = { type = "bearer", token = SOURCES[1] },
			tls = { insecure = true },
			timeout_ms = 15000,
		}
		local request: any = { method = "GET", path = "/api/search", query = { { "type", "dash-db" } } }
		local auth = Auth.headers(endpoint.auth, TOKEN)
		expect(auth).toEqual({ Authorization = "Bearer " .. TOKEN })
		local headers = Http.headers(endpoint, request, auth)
		expect(leaks(Http.url(endpoint, request))).toBe(false)
		local plan = Curl.curlPlan(endpoint, request, headers, "/home/u") :: Curl.CurlPlan
		expect(leaks(plan.argv)).toBe(false)
		expect(leaks(plan.stdin)).toBe(true)
	end)
end)

return nil
