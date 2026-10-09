--!strict
-- The error kind decides what the user sees and does next: an auth error
-- points at credentials, a timeout at the range or timeout_ms, a TLS failure
-- at tls.ca_file. The server's own explanation (Prometheus errorType/error,
-- Grafana message) is the most useful part and must survive.
local Classify = require("../../../plugin/lib/transport/classify")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function response(status: number, body: string?, extra: any?): any
	local r: any = { status = status, headers = {}, body = body or "", timed_out = false }
	if extra then
		for k, v in extra do
			r[k] = v
		end
	end
	return r
end

local function classify(r: any): any
	return Classify.classify(r, json.decode)
end

describe("success", function()
	it("is not an error for any 2xx", function()
		expect(classify(response(200, "{}"))).toBeNil()
		expect(classify(response(204))).toBeNil()
	end)
end)

describe("transport failures (status 0)", function()
	it("maps a timeout to timeout, before looking at the error text", function()
		expect(classify(response(0, "", { timed_out = true, error = "timeout: global" }))).toEqual({
			kind = "timeout",
			message = "the request timed out (timeout: global); try a shorter range or raise timeout_ms",
		})
	end)

	it("maps refused connections and DNS failures to network", function()
		expect(classify(response(0, "", { error = "io: Connection refused (os error 61)" }))).toEqual({
			kind = "network",
			message = "io: Connection refused (os error 61)",
		})
		expect(classify(response(0, "", { error = "curl: (6) Could not resolve host: prom" }))).toEqual({
			kind = "network",
			message = "curl: (6) Could not resolve host: prom",
		})
	end)

	it("points TLS verification failures at tls.ca_file", function()
		local hint = "; set tls.ca_file for a private CA (or tls.insecure for a lab)"
		expect(classify(response(0, "", { error = "io: invalid peer certificate: UnknownIssuer" }))).toEqual({
			kind = "network",
			message = "TLS verification failed: io: invalid peer certificate: UnknownIssuer" .. hint,
		})
		expect(classify(response(0, "", {
			error = "curl: (60) SSL certificate problem: unable to get local issuer certificate",
		}))).toEqual({
			kind = "network",
			message = "TLS verification failed: curl: (60) SSL certificate problem: unable to get local issuer certificate"
				.. hint,
		})
	end)

	it("asks to narrow a query whose response exceeds the body limit", function()
		expect(classify(response(0, "", { error = "the response body is larger than request limit: 16777216" }))).toEqual({
			kind = "query",
			message = "the response is larger than 16 MiB; narrow the query (shorter range, larger step or fewer series)",
		})
	end)

	it("never returns nil for a status 0 without detail", function()
		expect(classify(response(0))).toEqual({ kind = "network", message = "no response from the server" })
	end)

	it("passes through a failure computed before sending", function()
		local failure = { kind = "auth", message = "token_env GRAFANA_TOKEN is not set or is empty" }
		expect(classify(response(0, "", { failure = failure, error = "x" }))).toEqual(failure)
	end)
end)

describe("auth statuses", function()
	it("maps 401 to auth with Grafana's message", function()
		local body =
			'{"extra":null,"message":"Invalid API key","messageId":"api-key.invalid","statusCode":401,"traceID":""}'
		expect(classify(response(401, body))).toEqual({
			kind = "auth",
			status = 401,
			message = "authentication failed (HTTP 401): Invalid API key",
		})
	end)

	it("maps 403 to auth, distinct from a missing credential", function()
		expect(classify(response(403, '{"message":"Permission denied"}'))).toEqual({
			kind = "auth",
			status = 403,
			message = "permission denied (HTTP 403): Permission denied",
		})
	end)

	it("works without a body", function()
		expect(classify(response(401))).toEqual({
			kind = "auth",
			status = 401,
			message = "authentication failed (HTTP 401)",
		})
	end)
end)

describe("http statuses", function()
	it("carries Prometheus errorType and error", function()
		local body =
			'{"status":"error","errorType":"bad_data","error":"1:5: parse error: unexpected right parenthesis \')\'"}'
		expect(classify(response(400, body))).toEqual({
			kind = "http",
			status = 400,
			message = "HTTP 400: bad_data: 1:5: parse error: unexpected right parenthesis ')'",
		})
	end)

	it("carries Grafana /api/ds/query per-query errors", function()
		local body = '{"results":{"B":{"error":"second","status":400},"A":{"error":"bad query","status":400}}}'
		expect(classify(response(400, body))).toEqual({
			kind = "http",
			status = 400,
			message = "HTTP 400: A: bad query",
		})
	end)

	it("uses a plain-text body's first line (Loki, Alertmanager)", function()
		expect(classify(response(400, "\nparse error at line 1, col 5: syntax error\nsecond\n"))).toEqual({
			kind = "http",
			status = 400,
			message = "HTTP 400: parse error at line 1, col 5: syntax error",
		})
		expect(classify(response(404, '"silence not found"'))).toEqual({
			kind = "http",
			status = 404,
			message = "HTTP 404: silence not found",
		})
	end)

	it("drops HTML error pages, which are noise in a one-line message", function()
		expect(classify(response(502, "<html><body>Bad Gateway</body></html>"))).toEqual({
			kind = "http",
			status = 502,
			message = "HTTP 502",
		})
	end)

	it("shortens very long bodies", function()
		local err = classify(response(500, string.rep("x", 1000)))
		expect(#err.message <= 320).toBe(true)
		expect(string.sub(err.message, -3)).toBe("...")
	end)

	it("treats an unfollowed redirect as an http error", function()
		expect(classify(response(302))).toEqual({ kind = "http", status = 302, message = "HTTP 302" })
	end)
end)

return nil
