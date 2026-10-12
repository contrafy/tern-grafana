--!strict
-- The keychain is where a Grafana Cloud token lives once the user connects.
-- The commands must find the item the Settings flow stored, must never put
-- the secret in argv (any user on the machine can read argv with ps), and
-- must keep a secret with quotes, backslashes or spaces byte-exact through
-- `security -i`, which splits its input line like a shell. A secret that
-- cannot travel intact (line breaks) is refused before anything runs.
local Keychain = require("../../../plugin/lib/auth/keychain")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

describe("platform", function()
	it("uses the macOS login keychain through /usr/bin/security", function()
		expect(Keychain.platform({ os = "macos", security = true, secret_tool = false })).toBe("macos")
		expect(Keychain.platform({ os = "macos", security = false, secret_tool = true })).toBeNil()
	end)

	it("uses the Secret Service on Linux only when secret-tool is installed", function()
		expect(Keychain.platform({ os = "linux", security = false, secret_tool = true })).toBe("linux")
		expect(Keychain.platform({ os = "linux", security = false, secret_tool = false })).toBeNil()
	end)

	it("offers no keychain elsewhere", function()
		expect(Keychain.platform({ os = "windows", security = true, secret_tool = true })).toBeNil()
		expect(Keychain.platform({ os = nil, security = true, secret_tool = true })).toBeNil()
	end)
end)

describe("item names", function()
	it("names an item after its context and endpoint", function()
		expect(Keychain.itemName("cloud", "grafana")).toBe("cloud/grafana")
		expect(Keychain.validItem(Keychain.itemName("team-a.prod_1", "prometheus"))).toBe(true)
	end)

	it("accepts only names that are safe as argv words and inside quotes", function()
		expect(Keychain.validItem("a")).toBe(true)
		expect(Keychain.validItem(string.rep("a", 128))).toBe(true)
		for _, bad in { "", "/cloud", "-cloud", ".x", "a b", 'a"b', "a\\b", "a\nb", string.rep("a", 129), "ä" } do
			expect(Keychain.validItem(bad)).toBe(false)
		end
		expect(Keychain.validItem(42)).toBe(false)
	end)
end)

describe("lookup", function()
	it("reads the password of service tern-grafana, account item", function()
		expect(Keychain.lookupPlan("macos", "cloud/grafana")).toEqual({
			argv = { "/usr/bin/security", "find-generic-password", "-s", "tern-grafana", "-a", "cloud/grafana", "-w" },
		})
		expect(Keychain.lookupPlan("linux", "cloud/grafana")).toEqual({
			argv = { "secret-tool", "lookup", "service", "tern-grafana", "account", "cloud/grafana" },
		})
	end)

	it("tells a missing item from a failed lookup", function()
		expect(Keychain.lookupStatus("macos", 0, "tok\n")).toBe("found")
		expect(Keychain.lookupStatus("macos", 44, "")).toBe("missing")
		expect(Keychain.lookupStatus("macos", 51, "")).toBe("failed")
		expect(Keychain.lookupStatus("linux", 0, "tok")).toBe("found")
		expect(Keychain.lookupStatus("linux", 1, "")).toBe("missing")
		expect(Keychain.lookupStatus("linux", 0, "")).toBe("missing")
		expect(Keychain.lookupStatus("linux", 2, "")).toBe("failed")
	end)
end)

-- What `security -i` makes of one quoted word: inside double quotes a
-- backslash escapes the next character (verified: `"s3cr et\"x"` stores
-- `s3cr et"x`, `"a\\b"` stores `a\b`).
local function unquote(word: string): string
	local inner = string.match(word, '^"(.*)"$') :: string
	return (string.gsub(inner, "\\(.)", "%1"))
end

-- The words of a `security -i` line: quoted words only, as storePlan writes.
local function words(line: string): { string }
	local out: { string } = {}
	local i = 1
	while i <= #line do
		local c = string.sub(line, i, i)
		if c == '"' then
			local j = i + 1
			while string.sub(line, j, j) ~= '"' do
				j += if string.sub(line, j, j) == "\\" then 2 else 1
			end
			table.insert(out, unquote(string.sub(line, i, j)))
			i = j + 1
		elseif c == " " or c == "\n" then
			i += 1
		else
			local j = string.find(line, "[ \n]", i) or (#line + 1)
			table.insert(out, string.sub(line, i, j - 1))
			i = j
		end
	end
	return out
end

describe("store", function()
	local NASTY = { 'glsa_a"b', "back\\slash\\", "with spaces  ", '\\"', "-w", "$(id)`x`'q'", "ünï" }

	it("sends the secret on stdin with security -i and keeps it byte-exact", function()
		for _, secret in NASTY do
			local plan = Keychain.storePlan("macos", "cloud/grafana", secret) :: Keychain.Plan
			expect(plan.argv).toEqual({ "/usr/bin/security", "-i" })
			local stdin = plan.stdin :: string
			expect(string.sub(stdin, -1)).toBe("\n")
			expect(select(2, string.gsub(stdin, "\n", ""))).toBe(1)
			expect(words(stdin)).toEqual({
				"add-generic-password",
				"-U",
				"-s",
				"tern-grafana",
				"-a",
				"cloud/grafana",
				"-l",
				"Tern Grafana (cloud/grafana)",
				"-w",
				secret,
			})
		end
	end)

	it("pipes the raw secret to secret-tool store on Linux", function()
		local plan = Keychain.storePlan("linux", "cloud/grafana", 'a "b" \\c') :: Keychain.Plan
		expect(plan).toEqual({
			argv = {
				"secret-tool",
				"store",
				"--label=Tern Grafana (cloud/grafana)",
				"service",
				"tern-grafana",
				"account",
				"cloud/grafana",
			},
			stdin = 'a "b" \\c',
		})
	end)

	it("refuses secrets that cannot travel as one line, without echoing them", function()
		for _, name in { "macos", "linux" } do
			local platform: Keychain.Platform = name :: any
			for _, bad in { "tok\nsecond", "tok\r", "tok\0", "\ttok" } do
				local plan, err = Keychain.storePlan(platform, "cloud/grafana", bad)
				expect(plan).toBeNil()
				expect(err).toBe("the token contains line breaks or control characters; paste only the token")
			end
			expect(select(2, Keychain.storePlan(platform, "cloud/grafana", ""))).toBe("the token is empty")
			expect(select(2, Keychain.storePlan(platform, 'x" -A "', "tok"))).toBe("invalid keychain item name")
		end
	end)
end)

describe("delete", function()
	it("removes the item and treats an already missing one as removed", function()
		expect(Keychain.deletePlan("macos", "cloud/grafana")).toEqual({
			argv = { "/usr/bin/security", "delete-generic-password", "-s", "tern-grafana", "-a", "cloud/grafana" },
		})
		expect(Keychain.deletePlan("linux", "cloud/grafana")).toEqual({
			argv = { "secret-tool", "clear", "service", "tern-grafana", "account", "cloud/grafana" },
		})
		expect(Keychain.deleted("macos", 0)).toBe(true)
		expect(Keychain.deleted("macos", 44)).toBe(true)
		expect(Keychain.deleted("macos", 1)).toBe(false)
		expect(Keychain.deleted("linux", 1)).toBe(false)
	end)
end)

describe("explain", function()
	it("says what is wrong and what to do, on one line", function()
		local e = Keychain.explain("item_missing", { field = "password_keychain", context = "cloud", os = "linux" })
		expect(Keychain.line(e)).toBe(
			"No password stored for cloud in the Secret Service keyring; "
				.. "open Grafana: Settings and use Connect or Update token"
		)
		for _, kind in
			{
				"item_missing",
				"keychain_unavailable",
				"keychain_failed",
				"keychain_timeout",
				"env_unset",
				"cmd_missing",
				"cmd_start",
				"cmd_failed",
				"cmd_timeout",
				"file_unreadable",
				"home_unset",
				"empty",
				"multiline",
			}
		do
			local x = Keychain.explain(kind :: any, { error = "boom\nstack traceback:\n x", os = "macos" })
			expect((string.find(Keychain.line(x), "\n", 1, true))).toBeNil()
			expect(x.hint ~= "").toBe(true)
		end
	end)

	it("names well-known password manager CLIs instead of a bare program name", function()
		expect(Keychain.explain("cmd_missing", { field = "token_cmd", program = "/usr/local/bin/op" }).message).toBe(
			"token_cmd runs `op`, but the 1Password CLI (op) is not installed or not on Tern's PATH"
		)
		expect(Keychain.explain("cmd_missing", { field = "token_cmd", program = "mytool" }).hint).toBe(
			"install it or put its absolute path in token_cmd; "
				.. "or store the token in the keychain: open Grafana: Settings and use Connect or Update token"
		)
	end)

	it("reports a failed command by exit code, never by its output", function()
		expect(Keychain.explain("cmd_failed", { field = "token_cmd", program = "pass", status = 2 })).toEqual({
			message = "token_cmd `pass` exited with status 2",
			hint = "run it in a terminal to see why",
		})
	end)
end)

describe("firstLine", function()
	it("drops Lua tracebacks and the runtime error prefix", function()
		expect(Keychain.firstLine("runtime error: tern.process.run op: No such file\nstack traceback:\n\t[C]")).toBe(
			"tern.process.run op: No such file"
		)
		expect(Keychain.firstLine(nil)).toBe("unknown error")
		expect(Keychain.firstLine("\n")).toBe("unknown error")
	end)
end)

return nil
