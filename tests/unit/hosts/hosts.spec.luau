--!strict
-- On a machine listed in `hosts`, blocks and pollers must default to that
-- machine's context: an exact hostname is the user's most specific statement
-- and beats any glob, a longer glob beats a shorter one, and the choice never
-- depends on table order or hostname case. A bad entry is reported and
-- ignored, never silently routed somewhere else.
local Hosts = require("../../../plugin/lib/hosts/hosts")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function config(hosts: string, default: string?): any
	local cfg, problems = Validate.parseFile(
		string.format(
			[[{%s"contexts": {
				"lab": {"prometheus": {"url": "http://lab"}},
				"prod": {"prometheus": {"url": "http://prod"}},
				"edge": {"prometheus": {"url": "http://edge"}},
				"web": {"prometheus": {"url": "http://web"}}}, "hosts": %s}]],
			if default then '"default_context": "' .. default .. '", ' else "",
			hosts
		),
		json.decode
	)
	assert(cfg, problems[1] and Validate.format(problems[1]))
	return cfg
end

describe("hostname matching", function()
	local cfg = config([[{
		"web-*": "web",
		"web-1.prod.example.com": "prod",
		"*.prod.example.com": "edge",
		"*": "lab"}]])

	it("prefers an exact hostname over every glob", function()
		expect(Hosts.defaultContext(cfg, "web-1.prod.example.com")).toBe("prod")
	end)

	it("prefers the longest glob among matching globs", function()
		-- "*.prod.example.com" and "web-*" and "*" all match web-2.prod.example.com.
		expect(Hosts.defaultContext(cfg, "web-2.prod.example.com")).toBe("edge")
		expect(Hosts.defaultContext(cfg, "web-2.staging")).toBe("web")
		expect(Hosts.defaultContext(cfg, "laptop")).toBe("lab")
	end)

	it("ignores case and a trailing dot", function()
		expect(Hosts.defaultContext(cfg, "WEB-1.Prod.Example.COM.")).toBe("prod")
	end)

	it("matches an exact short name against a fully qualified hostname", function()
		local short = config('{"build-box": "prod"}')
		expect(Hosts.defaultContext(short, "build-box.local")).toBe("prod")
		expect(Hosts.defaultContext(short, "build-box-2.local")).toBeNil()
	end)

	it("treats ? as exactly one character and escapes pattern magic", function()
		local q = config('{"db-?": "prod", "a.b%": "edge"}')
		expect(Hosts.defaultContext(q, "db-7")).toBe("prod")
		expect(Hosts.defaultContext(q, "db-77")).toBeNil()
		expect(Hosts.defaultContext(q, "axb%")).toBeNil()
	end)

	it("breaks equal-length glob ties by fewer wildcards, then pattern text", function()
		local tie = config('{"ab*?": "edge", "abc*": "prod", "ab?*": "web"}')
		expect(Hosts.defaultContext(tie, "abcd")).toBe("prod")
		local text = config('{"b*z": "edge", "a*z": "prod"}')
		local rules = Hosts.read(text)
		expect(rules[1].pattern).toBe("a*z")
	end)

	it("has no default without a hostname or a matching rule", function()
		expect(Hosts.defaultContext(cfg, nil)).toBeNil()
		expect(Hosts.defaultContext(config('{"web-*": "web"}'), "db-1")).toBeNil()
	end)
end)

describe("validation", function()
	it("reports and skips entries naming unknown contexts, keeping the others", function()
		local cfg = config('{"web-*": "nope", "db-*": "prod"}')
		local rules, problems = Hosts.read(cfg)
		expect(#rules).toBe(1)
		expect(problems).toEqual({
			{ path = "hosts.web-*", message = 'no context named "nope" (defined: edge, lab, prod, web)' },
		})
		expect(Hosts.defaultContext(cfg, "web-1")).toBeNil()
	end)

	it("rejects a list or a non-string value", function()
		local _, listProblems = Hosts.read(config('["web"]'))
		expect(listProblems[1].path).toBe("hosts")
		local _, valueProblems = Hosts.read(config('{"web": 3}'))
		expect(valueProblems).toEqual({ { path = "hosts.web", message = "must be a string naming a context" } })
	end)

	it("reports patterns that differ only in case", function()
		local _, problems = Hosts.read(config('{"Web": "prod", "web": "lab"}'))
		expect(problems).toEqual({
			{ path = "hosts.web", message = 'repeats "Web" (hostnames are not case-sensitive)' },
		})
	end)
end)

describe("apply", function()
	it("replaces default_context with the host default so every reader honors it", function()
		local cfg = config('{"web-*": "web"}', "lab")
		local applied = Hosts.apply(cfg, "web-3")
		expect(applied and applied.default_context).toBe("web")
		expect(cfg.default_context).toBe("lab")
	end)

	it("returns the config unchanged off the listed hosts or without `hosts`", function()
		local cfg = config('{"web-*": "web"}', "lab")
		expect(Hosts.apply(cfg, "db-1")).toBe(cfg)
		expect(Hosts.apply(cfg, nil)).toBe(cfg)
		expect(Hosts.apply(nil, "web-1")).toBeNil()
	end)
end)

return nil
