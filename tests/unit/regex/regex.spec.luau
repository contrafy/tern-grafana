--!strict
-- The shared engine behind Grafana's JavaScript regexes (override byRegexp,
-- regex value mappings, variable regex filters: stringToJsRegex in
-- packages/grafana-data/src/text/string.ts) and RE2 label matchers
-- (Prometheus/Alertmanager `=~`, fully anchored).
local t = require("../../lib/test")
local Regex = require("../../../plugin/lib/regex")
local describe, it, expect = t.describe, t.it, t.expect

local function re(src: string, flags: string?): Regex.Regex
	local r, err = Regex.compile(src, flags)
	assert(r, err)
	return r
end

local function matched(src: string, s: string, flags: string?): string?
	local m = Regex.exec(re(src, flags), s)
	return if m then string.sub(s, m.start, m.finish) else nil
end

local function full(src: string, s: string): boolean
	local ok, err = Regex.fullMatch(re(src), s)
	assert(err == nil, err)
	return ok
end

describe("regex syntax", function()
	it("finds the leftmost match, preferring earlier alternatives like JavaScript", function()
		expect(matched("cat|category", "category")).toBe("cat")
		expect(matched("b+", "aabbbc")).toBe("bbb")
		expect(matched("x", "abc")).toBeNil()
	end)

	it("supports classes, ranges, negation and escape classes", function()
		expect(matched("[a-c]+", "xxabcabd")).toBe("abcab")
		expect(matched("[^0-9]+", "123abc456")).toBe("abc")
		expect(matched("\\d{3}-\\d{4}", "call 555-1234 now")).toBe("555-1234")
		expect(matched("\\w+", "  foo_bar1 ")).toBe("foo_bar1")
		expect(matched("\\s+", "a \t\nb")).toBe(" \t\n")
		expect(matched("[\\D]+", "12ab34")).toBe("ab")
		expect(matched("[a\\-z]+", "q-az")).toBe("-az")
	end)

	-- Prometheus users write RE2 POSIX classes in label matchers.
	it("supports RE2 POSIX classes", function()
		expect(matched("[[:alpha:]]+", "12abc34")).toBe("abc")
		expect(matched("[[:digit:][:upper:]]+", "abA1Bc")).toBe("A1B")
	end)

	it("treats a brace that is not a quantifier as a literal", function()
		expect(matched("a{x}", "a{x}")).toBe("a{x}")
		expect(matched("{", "x{")).toBe("{")
	end)

	it("supports counted and lazy quantifiers", function()
		expect(matched("a{2,3}", "aaaa")).toBe("aaa")
		expect(matched("a{2,}", "aaaaa")).toBe("aaaaa")
		expect(matched("a{2}", "aaaa")).toBe("aa")
		expect(matched("<.+?>", "<a><b>")).toBe("<a>")
		expect(matched("(?:ab)+?c", "ababc")).toBe("ababc")
		expect(matched("a*?b", "aaab")).toBe("aaab")
	end)

	it("backtracks through groups and alternation", function()
		expect(matched("(a|ab)(c|bcd)(d*)", "abcd")).toBe("abcd")
		expect(matched("^(\\w+)\\s+\\1$", "hello hello")).toBe("hello hello")
		expect(matched("^(\\w+)\\s+\\1$", "hello world")).toBeNil()
	end)

	it("returns numbered and named captures", function()
		local m = Regex.exec(re("(?<job>[a-z]+):(\\d+)"), "host=node:9100")
		assert(m, "no match")
		expect(m.groups[1]).toBe("node")
		expect(m.groups[2]).toBe("9100")
		expect(m.named.job).toBe("node")
		local p = Regex.exec(re("(?P<x>a)(b)?"), "a")
		assert(p, "no match")
		expect(p.named.x).toBe("a")
		expect(p.groups[2]).toBeNil()
	end)

	it("supports anchors, word boundaries and multiline mode", function()
		expect(matched("^b", "ab")).toBeNil()
		expect(matched("^b", "a\nb", "m")).toBe("b")
		expect(matched("a$", "a\nb")).toBeNil()
		expect(matched("a$", "a\nb", "m")).toBe("a")
		expect(matched("\\bcat\\b", "concat cat")).toBe("cat")
		expect(matched("\\bcat\\b", "concatenate")).toBeNil()
	end)

	it("supports lookahead", function()
		expect(matched("\\w+(?=:)", "key: v")).toBe("key")
		expect(matched("foo(?!bar)\\w*", "foobar foobaz")).toBe("foobaz")
	end)

	it("folds ASCII case with the i flag and RE2 inline flags", function()
		expect(matched("error", "An ERROR here", "i")).toBe("ERROR")
		expect(matched("(?i)warn", "WARNING")).toBe("WARN")
		expect(matched("a(?i:b)c", "aBc")).toBe("aBc")
		expect(matched("a(?i:b)c", "aBC")).toBeNil()
	end)

	it("lets dot cross newlines only with the s flag", function()
		expect(matched("a.b", "a\nb")).toBeNil()
		expect(matched("a.b", "a\nb", "s")).toBe("a\nb")
	end)

	-- Label values are UTF-8; one `.` is one character, not one byte.
	it("matches whole UTF-8 characters", function()
		expect(full("caf.", "café")).toBe(true)
		expect(full("[é]+", "éé")).toBe(true)
		expect(matched(".", "é")).toBe("é")
	end)

	it("reports syntax errors instead of raising", function()
		local _, e1 = Regex.compile("(a")
		expect(e1 and string.find(e1, "missing )", 1, true) ~= nil).toBe(true)
		local _, e2 = Regex.compile("a)")
		expect(e2 ~= nil).toBe(true)
		local _, e3 = Regex.compile("*a")
		expect(e3 ~= nil).toBe(true)
		local _, e4 = Regex.compile("(?<=a)b")
		expect(e4 and string.find(e4, "lookbehind", 1, true) ~= nil).toBe(true)
		local _, e5 = Regex.compile("[z-a]")
		expect(e5 ~= nil).toBe(true)
		local _, e6 = Regex.compile("(a)\\2")
		expect(e6 ~= nil).toBe(true)
		local _, e7 = Regex.compile("a", "y")
		expect(e7 ~= nil).toBe(true)
	end)
end)

describe("regex fullMatch (Prometheus/Alertmanager matchers are anchored)", function()
	it("requires the whole value to match", function()
		expect(full("crit.*", "critical")).toBe(true)
		expect(full("crit", "critical")).toBe(false)
		expect(full("warning|critical", "critical")).toBe(true)
		expect(full("warning|critical", "critical2")).toBe(false)
	end)

	-- `a|ab` against "ab": a plain search stops at "a"; anchoring must
	-- backtrack into the second alternative.
	it("backtracks into later alternatives to reach the end", function()
		expect(full("a|ab", "ab")).toBe(true)
		expect(full("(a+)(a+)", "aaaa")).toBe(true)
	end)

	it("matches the empty value only when the pattern allows it", function()
		expect(full(".*", "")).toBe(true)
		expect(full(".+", "")).toBe(false)
	end)
end)

describe("regex step budget", function()
	-- The host has 2 s per call; a catastrophic pattern must fail fast.
	it("returns an error for catastrophic backtracking", function()
		local r = re("(a+)+b")
		local ok, err = Regex.fullMatch(r, string.rep("a", 40) .. "c")
		expect(ok).toBe(false)
		expect(err and string.find(err, "step budget", 1, true) ~= nil).toBe(true)
		-- The compiled regex stays usable afterwards.
		local good = Regex.fullMatch(r, "aab")
		expect(good).toBe(true)
	end)

	it("handles long subjects with simple patterns within budget", function()
		local s = string.rep("x", 50000) .. "level=error"
		local m, err = Regex.exec(re("level=(\\w+)"), s)
		expect(err).toBeNil()
		assert(m, "no match")
		expect(m.groups[1]).toBe("error")
	end)
end)

describe("regex parseJs (Grafana stringToJsRegex)", function()
	it("anchors a bare pattern to the whole value", function()
		local r = assert(Regex.parseJs("up"))
		expect((Regex.test(r, "up"))).toBe(true)
		expect((Regex.test(r, "upper"))).toBe(false)
	end)

	it("reads /body/flags and keeps slashes inside the body", function()
		local r = assert(Regex.parseJs("/API/i"))
		expect(r.ignore_case).toBe(true)
		expect((Regex.test(r, "/api/v1/query"))).toBe(true)
		local s = assert(Regex.parseJs("/api/v1/.*/"))
		expect(s.source).toBe("api/v1/.*")
		local g = assert(Regex.parseJs("/a/g"))
		expect(g.global).toBe(true)
	end)

	it("rejects a slash pattern without a closing slash and valid flags", function()
		local r, err = Regex.parseJs("/abc")
		expect(r).toBeNil()
		expect(err ~= nil).toBe(true)
	end)
end)

describe("regex replace (String.prototype.replace)", function()
	it("replaces the first match unless global, expanding $n and $&", function()
		expect((Regex.replace(re("(\\w+)@(\\w+)"), "a@b c@d", "$2 at $1"))).toBe("b at a c@d")
		expect((Regex.replace(re("o", "g"), "foo boo", "0"))).toBe("f00 b00")
		expect((Regex.replace(re("\\d+"), "id 42", "[$&]"))).toBe("id [42]")
		expect((Regex.replace(re("x"), "x", "$$"))).toBe("$")
	end)

	it("expands named groups and accepts a function", function()
		expect((Regex.replace(re("(?<v>\\d+)"), "v12", "<$<v>>"))).toBe("v<12>")
		local out = Regex.replace(re("\\d", "g"), "a1b2", function(m)
			return tostring(tonumber(m.groups[0] or "0") or 0) .. "!"
		end)
		expect(out).toBe("a0!b0!")
	end)

	it("steps over empty matches", function()
		expect((Regex.replace(re("x*", "g"), "abc", "-"))).toBe("-a-b-c-")
	end)
end)

describe("regex escape (Grafana escapeRegex)", function()
	it("escapes metacharacters so the value matches literally", function()
		local value = "a.b*c(d)[e]{f}|g/h^$+?\\"
		local r = re("^" .. Regex.escape(value) .. "$")
		expect((Regex.test(r, value))).toBe(true)
		expect((Regex.test(r, "aXb*c(d)[e]{f}|g/h^$+?\\"))).toBe(false)
	end)
end)

return nil
