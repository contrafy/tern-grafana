--!strict
-- Credentials are resolved on demand from a command, an environment variable
-- or a file. The plan must run exactly what the user configured, the secret
-- must arrive without the newline every CLI prints, and no error message may
-- carry the secret, because errors end up in views, logs and screenshots.
local Auth = require("../../../plugin/lib/auth/auth")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local SECRET = "glsa_s3cr3t_value"

local CMD = { from = "cmd", field = "token_cmd", argv = { "op", "read", "op://dev/grafana/token" } } :: any
local ENV = { from = "env", field = "token_env", name = "GRAFANA_TOKEN" } :: any
local FILE = { from = "file", field = "password_file", path = "~/.secrets/grafana" } :: any

local function bearer(source: any): any
	return { type = "bearer", token = source }
end

local function hasSecret(s: string?): boolean
	return s ~= nil and string.find(s, "s3cr3t", 1, true) ~= nil
end

describe("plan", function()
	it("needs nothing for auth type none", function()
		local plan, err = Auth.plan({ type = "none" }, "/home/u")
		expect(plan).toBeNil()
		expect(err).toBeNil()
	end)

	it("runs the configured argv unchanged, without a shell", function()
		expect((Auth.plan(bearer(CMD), "/home/u"))).toEqual({
			kind = "process",
			field = "token_cmd",
			argv = { "op", "read", "op://dev/grafana/token" },
		})
	end)

	it("reads an environment variable", function()
		expect((Auth.plan(bearer(ENV), nil))).toEqual({ kind = "env", field = "token_env", name = "GRAFANA_TOKEN" })
	end)

	it("expands ~/ in file paths, since tern.fs does not", function()
		local basic: any = { type = "basic", username = "admin", password = FILE }
		expect((Auth.plan(basic, "/home/u"))).toEqual({
			kind = "file",
			field = "password_file",
			path = "/home/u/.secrets/grafana",
		})
	end)

	it("fails clearly when ~/ cannot be expanded", function()
		local plan, err = Auth.plan(bearer(FILE), nil)
		expect(plan).toBeNil()
		expect(err).toBe("password_file ~/.secrets/grafana: cannot expand ~ because HOME is not set")
	end)
end)

describe("expandHome", function()
	it("expands only a leading ~/ or a bare ~", function()
		expect((Auth.expandHome("~/a", "/home/u"))).toBe("/home/u/a")
		expect((Auth.expandHome("~", "/home/u"))).toBe("/home/u")
		expect((Auth.expandHome("~/a", "/home/u/"))).toBe("/home/u/a")
		expect((Auth.expandHome("/etc/~/a", "/home/u"))).toBe("/etc/~/a")
	end)
end)

describe("secret", function()
	local process = Auth.plan(bearer(CMD), nil) :: any
	local env = Auth.plan(bearer(ENV), nil) :: any
	local file = Auth.plan({ type = "basic", username = "u", password = FILE }, "/home/u") :: any

	it("trims the trailing newline CLIs print", function()
		expect((Auth.secret(process, { text = SECRET .. "\n", status = 0 }))).toBe(SECRET)
		expect((Auth.secret(process, { text = SECRET .. "\r\n", status = 0 }))).toBe(SECRET)
		expect((Auth.secret(file, { text = SECRET .. "\n\n" }))).toBe(SECRET)
	end)

	it("keeps other whitespace, which may be part of a password", function()
		expect((Auth.secret(file, { text = " pass word \n" }))).toBe(" pass word ")
	end)

	it("reports a failing command by exit status only, since stdout and stderr may hold the secret", function()
		local s, err = Auth.secret(
			process,
			{
				text = SECRET,
				status = 1,
				stderr = "warning: token is " .. SECRET .. "\n",
			} :: any
		)
		expect(s).toBeNil()
		expect(err).toBe("token_cmd `op` exited with status 1; run it in a terminal to see why")
		expect(hasSecret(err)).toBe(false)
	end)

	it("names only the program, not its arguments, when it cannot start", function()
		local _, err = Auth.secret(
			{ kind = "process", field = "token_cmd", argv = { "echo", SECRET } } :: any,
			{ error = "No such file or directory" }
		)
		expect(err).toBe("token_cmd `echo` could not be started: No such file or directory")
	end)

	it("reports a timed-out command", function()
		local _, err = Auth.secret(process, { status = -1, timed_out = true, text = "" })
		expect(err).toBe("token_cmd `op` timed out after 30 s (an unlock prompt may be waiting)")
	end)

	it("treats an unset or empty variable as missing", function()
		expect(select(2, Auth.secret(env, {}))).toBe("token_env GRAFANA_TOKEN is not set or is empty")
		expect(select(2, Auth.secret(env, { text = "" }))).toBe("token_env GRAFANA_TOKEN is not set or is empty")
	end)

	it("reports an unreadable file with its path", function()
		local _, err = Auth.secret(file, { error = "permission denied" })
		expect(err).toBe("password_file /home/u/.secrets/grafana could not be read: permission denied")
	end)

	it("rejects empty output", function()
		expect(select(2, Auth.secret(process, { text = "\n", status = 0 }))).toBe("token_cmd `op` printed nothing")
	end)

	it("rejects multi-line or control-character output without echoing it", function()
		local s, err = Auth.secret(process, { text = SECRET .. "\nsecond line\n", status = 0 })
		expect(s).toBeNil()
		expect(err).toBe("token_cmd `op` printed line breaks or control characters; it must print only the secret")
		expect(hasSecret(err)).toBe(false)
		local _, err2 = Auth.secret(file, { text = SECRET .. "\0" })
		expect(hasSecret(err2)).toBe(false)
		expect(err2).toContain("control characters")
	end)
end)

describe("headers", function()
	it("adds nothing without auth", function()
		expect(Auth.headers({ type = "none" }, nil)).toEqual({})
	end)

	it("builds a bearer header", function()
		expect(Auth.headers(bearer(ENV), SECRET)).toEqual({ Authorization = "Bearer " .. SECRET })
	end)

	it("builds a basic header from username and password", function()
		expect(Auth.headers({ type = "basic", username = "Aladdin", password = FILE }, "open sesame")).toEqual({
			Authorization = "Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==",
		})
	end)

	it("refuses to build credentials without a resolved secret", function()
		expect(function()
			Auth.headers(bearer(ENV), nil)
		end).toThrow("needs a resolved secret")
	end)
end)

describe("redact", function()
	it("hides secrets that contain pattern characters", function()
		local secret = "a-b%c.d[e]+"
		expect(Auth.redact("bad header: Bearer " .. secret .. " (twice: " .. secret .. ")", { secret })).toBe(
			"bad header: Bearer [redacted] (twice: [redacted])"
		)
	end)

	it("hides the longer of overlapping secrets whole", function()
		expect(Auth.redact("Authorization: Bearer tok", { "tok", "Bearer tok" })).toBe("Authorization: [redacted]")
	end)

	it("ignores empty secrets", function()
		expect(Auth.redact("text", { "" })).toBe("text")
	end)
end)

return nil
