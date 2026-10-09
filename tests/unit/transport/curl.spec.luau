--!strict
-- curl carries requests tern.fetch cannot (custom CA, client certs, insecure
-- TLS). Its argv is visible to every local user through ps, so secrets must
-- only travel on stdin; the user's ~/.curlrc must not alter requests; and the
-- status must be recovered exactly from curl's output.
local Curl = require("../../../plugin/lib/transport/curl")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local SECRET = "glsa_s3cr3t_token"

local function ep(tls: any?): any
	return {
		url = "https://prom.internal:9090",
		path_prefix = "",
		headers = { ["X-Scope-OrgID"] = "tenant-1" },
		auth = { type = "bearer" },
		tls = tls,
		timeout_ms = 15000,
	}
end

local QUERY = { method = "GET", path = "/api/v1/query", query = { { "query", "up" } } }
local HEADERS = { ["X-Scope-OrgID"] = "tenant-1", Authorization = "Bearer " .. SECRET }

local function argvHas(argv: { string }, needle: string): boolean
	for _, a in argv do
		if string.find(a, needle, 1, true) then
			return true
		end
	end
	return false
end

local function after(argv: { string }, flag: string): string?
	for i, a in argv do
		if a == flag then
			return argv[i + 1]
		end
	end
	return nil
end

describe("needsCurl", function()
	it("is false without tls so tern.fetch is used", function()
		expect(Curl.needsCurl(ep(nil))).toBe(false)
		expect(Curl.needsCurl(ep({ insecure = false }))).toBe(false)
	end)

	it("is true when any tls field is set", function()
		expect(Curl.needsCurl(ep({ ca_file = "/ca.pem", insecure = false }))).toBe(true)
		expect(Curl.needsCurl(ep({ cert_file = "/c.pem", insecure = false }))).toBe(true)
		expect(Curl.needsCurl(ep({ key_file = "/k.pem", insecure = false }))).toBe(true)
		expect(Curl.needsCurl(ep({ insecure = true }))).toBe(true)
	end)
end)

describe("curlPlan", function()
	it("never puts a secret header in argv; it goes through stdin config", function()
		local plan = Curl.curlPlan(ep({ ca_file = "/ca.pem", insecure = false }), QUERY, HEADERS, "/home/u") :: any
		expect(argvHas(plan.argv, SECRET)).toBe(false)
		expect(argvHas(plan.argv, "Authorization")).toBe(false)
		expect(after(plan.argv, "--config")).toBe("-")
		expect(plan.stdin).toContain('header = "Authorization: Bearer ' .. SECRET .. '"\n')
		expect(plan.stdin).toContain('header = "X-Scope-OrgID: tenant-1"\n')
	end)

	it("ignores the user's .curlrc, which could redirect or log requests", function()
		local plan = Curl.curlPlan(ep({ insecure = true }), QUERY, {}, nil) :: any
		expect(plan.argv[1]).toBe("curl")
		expect(plan.argv[2]).toBe("--disable")
	end)

	it("bounds the request time and reports errors on stderr only", function()
		local plan = Curl.curlPlan(ep({ insecure = true }), QUERY, {}, nil) :: any
		expect(argvHas(plan.argv, "--silent")).toBe(true)
		expect(argvHas(plan.argv, "--show-error")).toBe(true)
		expect(after(plan.argv, "--max-time")).toBe("15")
		local fast = ep({ insecure = true })
		fast.timeout_ms = 1500
		expect(after((Curl.curlPlan(fast, QUERY, {}, nil) :: any).argv, "--max-time")).toBe("1.5")
	end)

	it("gives the process more time than curl so curl reports the timeout itself", function()
		local plan = Curl.curlPlan(ep({ insecure = true }), QUERY, {}, nil) :: any
		expect(plan.timeout_ms > 15000).toBe(true)
	end)

	it("targets the joined URL with globbing off, so [] and {} reach the server", function()
		local plan = Curl.curlPlan(ep({ insecure = true }), QUERY, {}, nil) :: any
		expect(after(plan.argv, "--url")).toBe("https://prom.internal:9090/api/v1/query?query=up")
		expect(argvHas(plan.argv, "--globoff")).toBe(true)
		expect(after(plan.argv, "--request")).toBe("GET")
	end)

	it("maps tls options to curl flags with ~ expanded", function()
		local plan = Curl.curlPlan(
			ep({ ca_file = "~/ca.pem", cert_file = "/c.pem", key_file = "/k.pem", insecure = true }),
			QUERY,
			{},
			"/home/u"
		) :: any
		expect(after(plan.argv, "--cacert")).toBe("/home/u/ca.pem")
		expect(after(plan.argv, "--cert")).toBe("/c.pem")
		expect(after(plan.argv, "--key")).toBe("/k.pem")
		expect(argvHas(plan.argv, "--insecure")).toBe(true)
	end)

	it("fails when a ~ path cannot be expanded", function()
		local plan, err = Curl.curlPlan(ep({ ca_file = "~/ca.pem", insecure = false }), QUERY, {}, nil)
		expect(plan).toBeNil()
		expect(err).toBe("tls.ca_file ~/ca.pem: cannot expand ~ because HOME is not set")
	end)

	it("sends the body verbatim through stdin, escaped for the config syntax", function()
		local body = '{"queries":[{"expr":"a\\\\b \\"q\\""}]}\n@/etc/passwd\ttab\r'
		local plan = Curl.curlPlan(
			ep({ insecure = true }),
			{ method = "post", path = "/api/ds/query", body = body, headers = {} },
			{ ["Content-Type"] = "application/json" },
			nil
		) :: any
		expect(after(plan.argv, "--request")).toBe("POST")
		expect(argvHas(plan.argv, "passwd")).toBe(false)
		expect(plan.stdin).toContain(
			'data-raw = "{\\"queries\\":[{\\"expr\\":\\"a\\\\\\\\b \\\\\\"q\\\\\\"\\"}]}\\n@/etc/passwd\\ttab\\r"\n'
		)
	end)

	it("escapes quotes and backslashes in header values", function()
		local plan = Curl.curlPlan(ep({ insecure = true }), QUERY, { ["X-A"] = 'a"b\\c' }, nil) :: any
		expect(plan.stdin).toContain('header = "X-A: a\\"b\\\\c"\n')
	end)

	it("refuses header values with line breaks without echoing them", function()
		local plan, err =
			Curl.curlPlan(ep({ insecure = true }), QUERY, { Authorization = "Bearer " .. SECRET .. "\nX: y" }, nil)
		expect(plan).toBeNil()
		expect(err).toBe("header Authorization contains a line break")
	end)

	it("lists headers in a stable order", function()
		local plan = Curl.curlPlan(ep({ insecure = true }), QUERY, { B = "2", a = "1", C = "3" }, nil) :: any
		expect(plan.stdin).toBe('header = "a: 1"\nheader = "B: 2"\nheader = "C: 3"\n')
	end)
end)

describe("parseCurl", function()
	local function out(body: string, code: string, ctype: string): string
		return body .. "\n" .. Curl.MARKER .. " " .. code .. " " .. ctype .. "\n"
	end

	it("splits body and status from the marker line", function()
		local r = Curl.parseCurl(out('{"status":"success"}', "200", "application/json"), 0, "", false)
		expect(r).toEqual({
			status = 200,
			headers = { ["content-type"] = "application/json" },
			body = '{"status":"success"}',
			timed_out = false,
		})
	end)

	it("keeps a body that itself ends with newlines or mentions the marker", function()
		local body = "line1\n" .. Curl.MARKER .. " 999 fake\n\n"
		local r = Curl.parseCurl(out(body, "503", "text/plain; charset=utf-8"), 0, "", false)
		expect(r.status).toBe(503)
		expect(r.body).toBe(body)
		expect(r.headers).toEqual({ ["content-type"] = "text/plain; charset=utf-8" })
	end)

	it("handles an empty body and a missing content type", function()
		local r = Curl.parseCurl(out("", "204", ""), 0, "", false)
		expect(r.status).toBe(204)
		expect(r.body).toBe("")
		expect(r.headers).toEqual({})
	end)

	it("maps curl's timeout exit code to a timed-out response", function()
		local r = Curl.parseCurl("", 28, "curl: (28) Operation timed out after 15001 milliseconds\n", false)
		expect(r).toEqual({
			status = 0,
			headers = {},
			body = "",
			error = "curl: (28) Operation timed out after 15001 milliseconds",
			timed_out = true,
		})
	end)

	it("treats a killed curl as timed out", function()
		local r = Curl.parseCurl("", -1, "", true)
		expect(r.timed_out).toBe(true)
		expect(r.status).toBe(0)
		expect(r.error).toBe("curl was stopped after its time limit")
	end)

	it("reports connection and TLS failures from stderr", function()
		local r = Curl.parseCurl(
			"",
			60,
			"curl: (60) SSL certificate problem: unable to get local issuer certificate\nMore details here\n",
			false
		)
		expect(r.status).toBe(0)
		expect(r.timed_out).toBe(false)
		expect(r.error).toBe("curl: (60) SSL certificate problem: unable to get local issuer certificate")
		expect(Curl.parseCurl("", 7, "", false).error).toBe("curl exited with status 7")
	end)

	it("rejects output without a status line instead of guessing", function()
		local r = Curl.parseCurl("partial", 0, "", false)
		expect(r.status).toBe(0)
		expect(r.error).toBe("curl output had no status line")
	end)
end)

return nil
