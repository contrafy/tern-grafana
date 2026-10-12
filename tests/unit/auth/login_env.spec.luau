--!strict
-- Tern opened from the Dock does not see variables exported in ~/.zshrc, so
-- token_env asks the login shell. Startup files print banners, prompts and
-- warnings around the answer, so only the text between the markers counts;
-- the script names the variable but never holds its value.
local LoginEnv = require("../../../plugin/lib/auth/login_env")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local B, E = LoginEnv.BEGIN, LoginEnv.END

describe("shell", function()
	it("uses $SHELL when it is an absolute path", function()
		expect(LoginEnv.shell("/opt/homebrew/bin/fish", "macos")).toBe("/opt/homebrew/bin/fish")
	end)

	it("falls back to the platform's login shell", function()
		expect(LoginEnv.shell(nil, "macos")).toBe("/bin/zsh")
		expect(LoginEnv.shell("zsh", "macos")).toBe("/bin/zsh")
		expect(LoginEnv.shell("", "linux")).toBe("/bin/sh")
	end)
end)

describe("plan", function()
	it("runs a login, interactive shell that prints only the named variable", function()
		local plan = LoginEnv.plan("/bin/zsh", "GRAFANA_TOKEN") :: LoginEnv.Plan
		expect(plan.argv[1]).toBe("/bin/zsh")
		expect({ plan.argv[2], plan.argv[3], plan.argv[4] }).toEqual({ "-l", "-i", "-c" })
		expect(plan.argv[5]).toContain('"$GRAFANA_TOKEN"')
		expect(plan.timeout_ms).toBe(5000)
		expect(plan.stdin).toBe("")
	end)

	it("never writes a whole marker into the script, so an echoing shell cannot fake the answer", function()
		local plan = LoginEnv.plan("/bin/zsh", "GRAFANA_TOKEN") :: LoginEnv.Plan
		local script = plan.argv[5]
		expect((string.find(script, B, 1, true))).toBeNil()
		expect((string.find(script, E, 1, true))).toBeNil()
		-- A shell that echoes its input (set -x in an rc file) yields no value.
		expect(LoginEnv.parse("+ " .. script .. "\n")).toBeNil()
	end)

	it("refuses names that would inject shell syntax", function()
		for _, bad in { "A B", "A;id", "$(id)", "1A", "" } do
			expect(LoginEnv.plan("/bin/zsh", bad)).toBeNil()
		end
	end)
end)

describe("parse", function()
	it("takes the value between the markers despite rc noise before and after", function()
		local out = "Last login: Mon\n[ERROR] starship: dumb terminal\n" .. B .. "glsa_x y" .. E .. "\nbye\n"
		expect(LoginEnv.parse(out)).toBe("glsa_x y")
	end)

	it("reports an unset variable as empty", function()
		expect(LoginEnv.parse("motd\n" .. B .. E)).toBe("")
	end)

	it("returns nil when the shell failed before printing the markers", function()
		expect(LoginEnv.parse("zsh: command not found: printf")).toBeNil()
		expect(LoginEnv.parse(B .. "half")).toBeNil()
	end)
end)

return nil
