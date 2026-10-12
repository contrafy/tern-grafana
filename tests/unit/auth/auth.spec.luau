--!strict
-- Credentials are resolved on demand from a keychain item, an environment
-- variable, a command or a file. The plan must run exactly what the user
-- configured, the secret must arrive without the newline every CLI prints,
-- and every failure must be one actionable line that carries neither the
-- secret nor a host traceback, because errors end up in views, logs, Carly
-- answers and screenshots.
local Auth = require("../../../plugin/lib/auth/auth")
local Keychain = require("../../../plugin/lib/auth/keychain")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local SECRET = "glsa_s3cr3t_value"

local CMD = { from = "cmd", field = "token_cmd", argv = { "op", "read", "op://dev/grafana/token" } } :: any
local ENV = { from = "env", field = "token_env", name = "GRAFANA_TOKEN" } :: any
local FILE = { from = "file", field = "password_file", path = "~/.secrets/grafana" } :: any
local KEYCHAIN = { from = "keychain", field = "token_keychain", item = "cloud/grafana" } :: any

local function bearer(source: any): any
	return { type = "bearer", token = source }
end

local function hasSecret(s: string?): boolean
	return s ~= nil and string.find(s, "s3cr3t", 1, true) ~= nil
end

local function line(e: Auth.Explained?): string?
	return if e then Keychain.line(e) else nil
end

describe("plan", function()
	it("needs nothing for auth type none", function()
		local plan, err = Auth.plan({ type = "none" }, "/home/u")
		expect(plan).toBeNil()
		expect(err).toBeNil()
	end)

	it("looks up the configured keychain item", function()
		expect((Auth.plan(bearer(KEYCHAIN), nil))).toEqual({
			kind = "keychain",
			field = "token_keychain",
			item = "cloud/grafana",
		})
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
		expect(line(err)).toBe(
			"password_file ~/.secrets/grafana: cannot expand ~ because HOME is not set; use an absolute path"
		)
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
	local keychain = Auth.plan(bearer(KEYCHAIN), nil) :: any
	local cloud: Auth.Where = { context = "cloud", os = "macos" }

	it("trims the trailing newline CLIs print", function()
		expect((Auth.secret(process, { text = SECRET .. "\n", status = 0 }))).toBe(SECRET)
		expect((Auth.secret(process, { text = SECRET .. "\r\n", status = 0 }))).toBe(SECRET)
		expect((Auth.secret(file, { text = SECRET .. "\n\n" }))).toBe(SECRET)
		expect((Auth.secret(keychain, { text = SECRET .. "\n", status = 0, lookup = "found" }, cloud))).toBe(SECRET)
	end)

	it("keeps other whitespace, which may be part of a password", function()
		expect((Auth.secret(file, { text = " pass word \n" }))).toBe(" pass word ")
	end)

	it("tells the user to store a token when the keychain item is missing", function()
		local s, err = Auth.secret(keychain, { text = "", status = 44, lookup = "missing" }, cloud)
		expect(s).toBeNil()
		expect(line(err)).toBe(
			"No token stored for cloud in the macOS keychain; open Grafana: Settings and use Connect or Update token"
		)
	end)

	it("says the keychain is unavailable rather than missing on a machine without one", function()
		local _, err = Auth.secret(keychain, { lookup = "unavailable" }, { context = "cloud", os = "linux" })
		expect(line(err)).toBe(
			"token_keychain needs a system keychain, which is not available here; "
				.. "install secret-tool (package libsecret-tools) with a running keyring, or use token_env"
		)
	end)

	it("reports a failed or slow keychain lookup by exit code only", function()
		local _, err = Auth.secret(keychain, { text = SECRET, status = 51, lookup = "failed" }, cloud)
		expect(err and err.message).toBe("Reading keychain item cloud/grafana failed (exit 51)")
		expect(hasSecret(line(err))).toBe(false)
		local _, slow = Auth.secret(keychain, { timed_out = true, lookup = "failed" }, cloud)
		expect(slow and slow.hint).toBe("an unlock or access prompt may be waiting; answer it and retry")
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
		expect(line(err)).toBe(
			"token_cmd `op` exited with status 1; run the same `op read ...` in a terminal; "
				.. "1Password may need `op signin` or an unlocked app"
		)
		expect(hasSecret(line(err))).toBe(false)
	end)

	it("explains a missing password manager CLI without its arguments or Tern's traceback", function()
		local _, err = Auth.secret(process, {
			error = "runtime error: tern.process.run op: No such file or directory (os error 2)\n"
				.. "stack traceback:\n  [C] function run\n  plugin/transport_host.luau:95",
		})
		local text = line(err) :: string
		expect(err and err.message).toBe(
			"token_cmd runs `op`, but the 1Password CLI (op) is not installed or not on Tern's PATH"
		)
		expect(text).toContain("open Grafana: Settings and use Connect or Update token")
		expect((string.find(text, "traceback", 1, true))).toBeNil()
		expect((string.find(text, "op://", 1, true))).toBeNil()
	end)

	it("names only the program when it cannot start for another reason", function()
		local _, err = Auth.secret(
			{ kind = "process", field = "token_cmd", argv = { "/opt/bin/getter", SECRET } } :: any,
			{ error = "runtime error: tern.process.run /opt/bin/getter: Permission denied (os error 13)\nstack" }
		)
		expect(err and err.message).toBe(
			"token_cmd `getter` could not be started: tern.process.run /opt/bin/getter: Permission denied (os error 13)"
		)
		expect(hasSecret(line(err))).toBe(false)
	end)

	it("reports a timed-out command", function()
		local _, err = Auth.secret(process, { status = -1, timed_out = true, text = "" })
		expect(line(err)).toBe(
			"token_cmd `op` timed out after 30 s; an unlock prompt may be waiting; answer it and retry"
		)
	end)

	it("treats an unset or empty variable as missing and explains the Dock launch", function()
		local _, err = Auth.secret(env, {}, cloud)
		expect(err and err.message).toBe("Environment variable GRAFANA_TOKEN (token_env) is not set")
		expect(err and err.hint).toContain("launchctl setenv GRAFANA_TOKEN <token>")
		expect(err and err.hint).toContain("Dock")
		local _, empty = Auth.secret(env, { text = "" }, { os = "linux" })
		expect(empty and empty.message).toBe("Environment variable GRAFANA_TOKEN (token_env) is not set")
		expect((string.find((empty :: any).hint, "launchctl", 1, true))).toBeNil()
	end)

	it("reports an unreadable file with its path and the first line of the error", function()
		local _, err = Auth.secret(file, { error = "permission denied\nstack traceback: x" })
		expect(line(err)).toBe(
			"password_file /home/u/.secrets/grafana could not be read: permission denied; "
				.. "check that the file exists and is readable by you (chmod 600)"
		)
	end)

	it("rejects empty output", function()
		local _, err = Auth.secret(process, { text = "\n", status = 0 })
		expect(line(err)).toBe("token_cmd `op` output is empty; it must hold exactly the token")
	end)

	it("rejects multi-line or control-character output without echoing it", function()
		local s, err = Auth.secret(process, { text = SECRET .. "\nsecond line\n", status = 0 })
		expect(s).toBeNil()
		expect(line(err)).toBe(
			"token_cmd `op` output has line breaks or control characters; it must hold only the token on one line"
		)
		expect(hasSecret(line(err))).toBe(false)
		local _, err2 = Auth.secret(file, { text = SECRET .. "\0" })
		expect(hasSecret(line(err2))).toBe(false)
		expect(line(err2)).toContain("only the password")
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
