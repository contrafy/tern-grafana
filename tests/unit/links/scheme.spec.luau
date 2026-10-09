--!strict
-- tern-grafana:// links land in block args, saved state and terminal output,
-- so decoding must be strict (a bad link is an error, never a guess), must
-- refuse anything credential-shaped, and encode/decode must round-trip so a
-- block restored from its args shows exactly what was linked.
local Scheme = require("../../../plugin/lib/links/scheme")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function code(url: string): string?
	local _, err = Scheme.decode(url)
	return err and err.code
end

describe("scheme.decode", function()
	it("decodes a query link with percent-encoded PromQL", function()
		local l = Scheme.decode("tern-grafana://query?context=lab&expr=rate%28up%5B5m%5D%29&from=now-6h&to=now")
		expect(l).toEqual({
			action = "query",
			params = { context = "lab", expr = "rate(up[5m])", from = "now-6h", to = "now" },
			vars = {},
		})
	end)

	it("collects repeated dashboard variables in order", function()
		local l = Scheme.decode("tern-grafana://dashboard?uid=abc-1&var-job=api&var-job=web&panel=3")
		expect(l and l.vars).toEqual({ job = { "api", "web" } })
		expect(l and l.params.panel).toBe("3")
	end)

	it("rejects unknown actions with a typed error", function()
		expect(code("tern-grafana://explode?x=1")).toBe("unknown_action")
	end)

	it("rejects parameters the action does not allow", function()
		expect(code("tern-grafana://settings?uid=abc")).toBe("unknown_param")
		expect(code("tern-grafana://query?var-x=1")).toBe("unknown_param")
	end)

	it("rejects invalid values", function()
		expect(code("tern-grafana://dashboard?uid=a/b")).toBe("bad_param")
		expect(code("tern-grafana://panel?uid=a&panel=3x")).toBe("bad_param")
		expect(code("tern-grafana://query?from=yesterday")).toBe("bad_param")
		expect(code("tern-grafana://query?context=bad%20name")).toBe("bad_param")
		expect(code("tern-grafana://trace?id=zz")).toBe("bad_param")
		expect(code("tern-grafana://query?expr=up%07")).toBe("bad_param")
		expect(code("tern-grafana://query?expr=up&expr=down")).toBe("bad_param")
		expect(code("tern-grafana://query?expr=%zz")).toBe("bad_param")
	end)

	it("requires the parameters an action cannot work without", function()
		expect(code("tern-grafana://dashboard")).toBe("missing_param")
		expect(code("tern-grafana://panel?uid=a")).toBe("missing_param")
	end)

	it("accepts absolute and relative Grafana times", function()
		expect(code("tern-grafana://query?from=1710510330123&to=now%2Fd")).toBeNil()
	end)

	-- A token in a link would be written to state files and scrollback.
	it("refuses credential-shaped parameters and variables", function()
		expect(code("tern-grafana://query?token=x")).toBe("credential")
		expect(code("tern-grafana://query?Password=x")).toBe("credential")
		expect(code("tern-grafana://query?auth=x")).toBe("credential")
		expect(code("tern-grafana://dashboard?uid=a&var-api_token=x")).toBe("credential")
	end)

	it("browse only accepts http(s) URLs without userinfo", function()
		expect(code("tern-grafana://browse?url=https%3A%2F%2Fg.example%2Fd%2Fx")).toBeNil()
		expect(code("tern-grafana://browse?url=https%3A%2F%2Fu%3Ap%40g.example%2F")).toBe("bad_param")
		expect(code("tern-grafana://browse?url=file%3A%2F%2F%2Fetc%2Fpasswd")).toBe("bad_param")
		expect(code("tern-grafana://browse?url=javascript%3Aalert(1)")).toBe("bad_param")
	end)

	it("is not fooled by other schemes", function()
		expect(code("https://grafana.example/d/x")).toBe("not_link")
	end)
end)

describe("scheme.encode", function()
	it("raises on an invalid link instead of emitting one", function()
		expect(function()
			Scheme.encode({ action = "query", params = { token = "x" }, vars = {} })
		end).toThrow("credential")
	end)

	it("produces a canonical, sorted form", function()
		expect((Scheme.encode({ action = "query", params = { to = "now", expr = "a b", context = "lab" }, vars = {} }))).toBe(
			"tern-grafana://query?context=lab&expr=a%20b&to=now"
		)
	end)
end)

-- Deterministic pseudo-random generator so failures reproduce.
local seed = 12345
local function rand(n: number): number
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed % n + 1
end

local ALPHABET = "abcXYZ019 _-.~%&=+?#/[]{}()\"'\n\tä"
local function randomText(): string
	local out = {}
	for _ = 1, rand(20) do
		local i = rand(#ALPHABET)
		table.insert(out, string.sub(ALPHABET, i, i))
	end
	return table.concat(out)
end

local function utf8Safe(s: string): string
	-- Variable values are single-line: drop controls and split multibyte chars.
	return (string.gsub(s, "[%c\128-\255]", ""))
end

describe("scheme round trip", function()
	it("decode(encode(link)) == link for generated links", function()
		local times = { "now", "now-6h", "now-1d/d", "1710510330123" }
		for _ = 1, 300 do
			local params: { [string]: string } = { context = "ctx-" .. rand(9), uid = "u_" .. rand(999) }
			local action = if rand(2) == 1 then "dashboard" else "panel"
			params.panel = tostring(rand(99))
			params.from = times[rand(#times)]
			local vars = { job = { utf8Safe(randomText()), utf8Safe(randomText()) } }
			local link = { action = action, params = params, vars = vars }
			local decoded = Scheme.decode(Scheme.encode(link))
			expect(decoded).toEqual(link)

			local q = { action = "query", params = { expr = randomText() }, vars = {} }
			if string.find(q.params.expr, "%S") then
				expect((Scheme.decode(Scheme.encode(q)))).toEqual(q)
			end
		end
	end)
end)

return nil
