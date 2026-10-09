--!strict
-- A backtracking regular expression engine for the common subset of
-- JavaScript RegExp (Grafana: field override `byRegexp`, regex value
-- mappings, variable regex filters) and RE2 (Prometheus and Alertmanager
-- label matchers). Luau has no regex library and Lua patterns lack
-- alternation, groups and counted repetition.
--
-- Syntax: literals and escapes (\n \r \t \f \v \0 \xHH \uHHHH \u{H...}, any
-- other escaped punctuation), `.`, classes `[...]` / `[^...]` with ranges,
-- \d \D \w \W \s \S and POSIX `[:alpha:]`-style items (RE2), anchors ^ $
-- \b \B, groups `(...)`, `(?:...)`, named `(?<n>...)` / `(?P<n>...)`,
-- alternation, quantifiers * + ? {n} {n,} {n,m} and their lazy forms,
-- backreferences \1..\N, lookahead (?=...) (?!...), inline flags (?i) (?s)
-- (?m) (?-i) and flag groups (?i:...) (RE2). Flags: i (ASCII case folding),
-- m (^ and $ at line breaks), s (dot matches newlines), g (replace all),
-- u (accepted; matching is always UTF-8 aware). Not supported (compile
-- error): lookbehind, \p{...} classes, the sticky flag.
--
-- Matching walks UTF-8 code points, so `.` and classes consume a whole
-- character. Positions are byte indices like string.find. Every match
-- attempt runs under a step budget (M.STEP_BUDGET): a pattern such as
-- (a+)+b against a long run of "a" returns an error instead of hanging the
-- host past its 2 s budget.

export type Match = {
	-- Byte range of the whole match, inclusive (finish = start - 1 when empty).
	start: number,
	finish: number,
	-- Capture groups by number; an unset group is absent.
	groups: { [number]: string },
	named: { [string]: string },
}

type Cont = (number) -> number?
type Matcher = (number, Cont) -> number?

type Ctx = { s: string, n: number, caps: { [number]: number }, steps: number, budget: number }

export type Regex = {
	source: string,
	flags: string,
	global: boolean,
	ignore_case: boolean,
	multiline: boolean,
	dotall: boolean,
	-- Number of capture groups and the numbers of named ones.
	groups: number,
	names: { [string]: number },
	_m: Matcher,
	_ctx: Ctx,
	-- The pattern can only match at the start of the subject.
	_anchored: boolean,
}

type CharSet = { ranges: { number }, subs: { CharSet }?, negate: boolean }

type Node = {
	t: string,
	set: CharSet?,
	ci: boolean?,
	items: { Node }?,
	node: Node?,
	index: number?,
	min: number?,
	max: number?,
	greedy: boolean?,
	negate: boolean?,
	multiline: boolean?,
}

type Flags = { i: boolean, m: boolean, s: boolean }

type Parser = {
	src: string,
	pos: number,
	ncap: number,
	names: { [string]: number },
	backrefs: { Node },
}

local M = {}

-- Steps (character tests and branch attempts) one exec/test/fullMatch call
-- may spend before giving up with an error.
M.STEP_BUDGET = 200000

local PARSE_TAG = "\0regex:"
local BUDGET = newproxy(false)
local MAX_REPEAT = 1000

local byte = string.byte

-- Set builders ---------------------------------------------------------------

local function set(ranges: { number }, negate: boolean?): CharSet
	return { ranges = ranges, negate = negate == true }
end

local DIGIT = { 48, 57 }
local WORD = { 48, 57, 65, 90, 95, 95, 97, 122 }
-- JavaScript \s: WhiteSpace and LineTerminator.
local SPACE = {
	9,
	13,
	32,
	32,
	0xA0,
	0xA0,
	0x1680,
	0x1680,
	0x2000,
	0x200A,
	0x2028,
	0x2029,
	0x202F,
	0x202F,
	0x205F,
	0x205F,
	0x3000,
	0x3000,
	0xFEFF,
	0xFEFF,
}
local LINE_BREAKS = { 10, 10, 13, 13, 0x2028, 0x2029 }

local POSIX: { [string]: { number } } = {
	alnum = { 48, 57, 65, 90, 97, 122 },
	alpha = { 65, 90, 97, 122 },
	ascii = { 0, 127 },
	blank = { 9, 9, 32, 32 },
	cntrl = { 0, 31, 127, 127 },
	digit = DIGIT,
	graph = { 33, 126 },
	lower = { 97, 122 },
	print = { 32, 126 },
	punct = { 33, 47, 58, 64, 91, 96, 123, 126 },
	space = { 9, 13, 32, 32 },
	upper = { 65, 90 },
	word = WORD,
	xdigit = { 48, 57, 65, 70, 97, 102 },
}

local function setTest(cs: CharSet, cp: number): boolean
	local hit = false
	local r = cs.ranges
	for x = 1, #r, 2 do
		if cp >= r[x] and cp <= r[x + 1] then
			hit = true
			break
		end
	end
	if not hit and cs.subs then
		for _, sub in cs.subs do
			if setTest(sub, cp) then
				hit = true
				break
			end
		end
	end
	return hit ~= cs.negate
end

local function swapCase(cp: number): number
	if cp >= 65 and cp <= 90 then
		return cp + 32
	elseif cp >= 97 and cp <= 122 then
		return cp - 32
	end
	return cp
end

-- UTF-8 ----------------------------------------------------------------------

-- The code point at byte `i` and the index after it; a malformed sequence is
-- read as one byte.
local function decode(s: string, i: number): (number, number)
	local b = byte(s, i) :: number
	if b < 0x80 then
		return b, i + 1
	end
	local len, cp
	if b >= 0xF0 and b < 0xF8 then
		len, cp = 4, b - 0xF0
	elseif b >= 0xE0 then
		len, cp = 3, b - 0xE0
	elseif b >= 0xC0 then
		len, cp = 2, b - 0xC0
	else
		return b, i + 1
	end
	for k = 1, len - 1 do
		local c = byte(s, i + k)
		if c == nil or c < 0x80 or c >= 0xC0 then
			return b, i + 1
		end
		cp = cp * 64 + (c - 0x80)
	end
	return cp, i + len
end

local function isContinuation(s: string, i: number): boolean
	local b = byte(s, i)
	return b ~= nil and b >= 0x80 and b < 0xC0
end

-- Parser ---------------------------------------------------------------------

local function fail(p: Parser, msg: string): never
	error(string.format("%s%s at offset %d", PARSE_TAG, msg, p.pos - 1), 0)
end

local function peek(p: Parser): string
	return string.sub(p.src, p.pos, p.pos)
end

local function atEnd(p: Parser): boolean
	return p.pos > #p.src
end

local function hexAt(p: Parser, count: number): number?
	local digits = string.sub(p.src, p.pos, p.pos + count - 1)
	if #digits == count and string.match(digits, "^%x+$") then
		p.pos += count
		return tonumber(digits, 16)
	end
	return nil
end

-- A character escape after `\` that denotes one code point, or nil.
local function charEscape(p: Parser, c: string, inClass: boolean): number?
	if c == "n" then
		return 10
	elseif c == "r" then
		return 13
	elseif c == "t" then
		return 9
	elseif c == "f" then
		return 12
	elseif c == "v" then
		return 11
	elseif c == "0" and not string.match(peek(p), "%d") then
		return 0
	elseif c == "b" and inClass then
		return 8
	elseif c == "x" then
		return hexAt(p, 2) or fail(p, "invalid \\x escape")
	elseif c == "u" then
		if peek(p) == "{" then
			local hex = string.match(p.src, "^{(%x+)}", p.pos) or fail(p, "invalid \\u{} escape")
			p.pos += #hex + 2
			return tonumber(hex, 16)
		end
		return hexAt(p, 4) or fail(p, "invalid \\u escape")
	elseif c == "p" or c == "P" then
		fail(p, "unicode property classes are not supported")
	elseif string.match(c, "[%a]") then
		return nil
	end
	return byte(c)
end

-- \d \D \w \W \s \S as a set, or nil.
local function classEscape(c: string): CharSet?
	if c == "d" then
		return set(DIGIT)
	elseif c == "D" then
		return set(DIGIT, true)
	elseif c == "w" then
		return set(WORD)
	elseif c == "W" then
		return set(WORD, true)
	elseif c == "s" then
		return set(SPACE)
	elseif c == "S" then
		return set(SPACE, true)
	end
	return nil
end

-- One literal code point at the cursor (UTF-8 aware).
local function literalAt(p: Parser): number
	local cp, nextPos = decode(p.src, p.pos)
	p.pos = nextPos
	return cp
end

local function parseClass(p: Parser): CharSet
	-- p.pos is just after "[".
	local negate = false
	if peek(p) == "^" then
		negate = true
		p.pos += 1
	end
	local ranges: { number } = {}
	local subs: { CharSet } = {}
	-- One class item: a code point, or a set (escape class / POSIX class).
	local function item(): (number?, CharSet?)
		local c = peek(p)
		if c == "\\" then
			p.pos += 1
			if atEnd(p) then
				fail(p, "trailing backslash")
			end
			local e = peek(p)
			p.pos += 1
			local cls = classEscape(e)
			if cls then
				return nil, cls
			end
			local cp = charEscape(p, e, true)
			if cp == nil then
				if e == "B" then
					fail(p, "\\B in a class")
				end
				return byte(e), nil
			end
			return cp, nil
		elseif c == "[" and string.sub(p.src, p.pos + 1, p.pos + 1) == ":" then
			local name, neg = nil, false
			local s = string.match(p.src, "^%[:(%^?%a+):%]", p.pos)
			if s then
				neg = string.sub(s, 1, 1) == "^"
				name = if neg then string.sub(s, 2) else s
			end
			if name then
				local r = POSIX[name]
				if r == nil then
					fail(p, "unknown POSIX class " .. name)
				end
				p.pos += #(s :: string) + 4
				return nil, set(r, neg)
			end
		end
		return literalAt(p), nil
	end
	while true do
		if atEnd(p) then
			fail(p, "missing ]")
		end
		if peek(p) == "]" then
			p.pos += 1
			break
		end
		local lo, cls = item()
		if cls then
			if cls.negate or cls.subs then
				table.insert(subs, cls)
			else
				for _, v in cls.ranges do
					table.insert(ranges, v)
				end
			end
		elseif lo then
			local hi = lo
			if peek(p) == "-" and string.sub(p.src, p.pos + 1, p.pos + 1) ~= "]" and p.pos + 1 <= #p.src then
				p.pos += 1
				local upper, upperCls = item()
				if upperCls or upper == nil then
					-- [a-\d]: the dash is literal (JavaScript annex B).
					table.insert(ranges, lo)
					table.insert(ranges, lo)
					table.insert(ranges, 45)
					table.insert(ranges, 45)
					if upperCls then
						table.insert(subs, upperCls)
					end
					continue
				end
				hi = upper
				if hi < lo then
					fail(p, "range out of order in class")
				end
			end
			table.insert(ranges, lo)
			table.insert(ranges, hi)
		end
	end
	local cs = set(ranges, negate)
	if #subs > 0 then
		cs.subs = subs
	end
	return cs
end

local parseAlt: (p: Parser, flags: Flags) -> Node

local function charNode(cs: CharSet, flags: Flags): Node
	return { t = "set", set = cs, ci = flags.i }
end

-- Applies "imsU-ims" style flag letters; returns false on an unknown letter.
local function applyFlags(flags: Flags, spec: string): boolean
	local on = true
	for k = 1, #spec do
		local c = string.sub(spec, k, k)
		if c == "-" then
			on = false
		elseif c == "i" or c == "m" or c == "s" then
			(flags :: any)[c] = on
		else
			return false
		end
	end
	return true
end

-- An atom, or nil for an inline flag group that only changes `flags`.
local function parseAtom(p: Parser, flags: Flags): Node?
	local c = peek(p)
	if c == "." then
		p.pos += 1
		local cs = if flags.s then set({ 0, 0x10FFFF }) else set(LINE_BREAKS, true)
		return { t = "set", set = cs }
	elseif c == "^" then
		p.pos += 1
		return { t = "bol", multiline = flags.m }
	elseif c == "$" then
		p.pos += 1
		return { t = "eol", multiline = flags.m }
	elseif c == "[" then
		p.pos += 1
		return charNode(parseClass(p), flags)
	elseif c == "(" then
		p.pos += 1
		local inner = table.clone(flags)
		local node: Node
		if peek(p) == "?" then
			p.pos += 1
			local kind = peek(p)
			if kind == ":" then
				p.pos += 1
				node = { t = "group", node = parseAlt(p, inner) }
			elseif kind == "=" or kind == "!" then
				p.pos += 1
				node = { t = "look", node = parseAlt(p, inner), negate = kind == "!" }
			elseif string.sub(p.src, p.pos, p.pos + 1) == "<=" or string.sub(p.src, p.pos, p.pos + 1) == "<!" then
				fail(p, "lookbehind is not supported")
			elseif kind == "<" or (kind == "P" and string.sub(p.src, p.pos + 1, p.pos + 1) == "<") then
				p.pos += if kind == "P" then 2 else 1
				local name = string.match(p.src, "^([%a_][%w_]*)>", p.pos) or fail(p, "invalid group name")
				p.pos += #name + 1
				if p.names[name] then
					fail(p, "duplicate group name " .. name)
				end
				p.ncap += 1
				local index = p.ncap
				p.names[name] = index
				node = { t = "group", index = index, node = parseAlt(p, inner) }
			else
				local spec, close = string.match(p.src, "^([%-ims]*)([:%)])", p.pos)
				if spec == nil or close == nil or spec == "" then
					return fail(p, "invalid group")
				end
				p.pos += #spec + 1
				if close == ")" then
					-- (?i): the rest of the enclosing group.
					if not applyFlags(flags, spec) then
						fail(p, "invalid flags")
					end
					return nil
				end
				if not applyFlags(inner, spec) then
					fail(p, "invalid flags")
				end
				node = { t = "group", node = parseAlt(p, inner) }
			end
		else
			p.ncap += 1
			local index = p.ncap
			node = { t = "group", index = index, node = parseAlt(p, inner) }
		end
		if peek(p) ~= ")" then
			fail(p, "missing )")
		end
		p.pos += 1
		return node
	elseif c == ")" then
		fail(p, "unmatched )")
	elseif c == "*" or c == "+" or c == "?" then
		fail(p, "nothing to repeat")
	elseif c == "\\" then
		p.pos += 1
		if atEnd(p) then
			fail(p, "trailing backslash")
		end
		local e = peek(p)
		p.pos += 1
		if e == "b" then
			return { t = "wordb" }
		elseif e == "B" then
			return { t = "wordb", negate = true }
		elseif e == "A" then
			return { t = "bol", multiline = false }
		elseif e == "z" then
			return { t = "eol", multiline = false }
		end
		local cls = classEscape(e)
		if cls then
			return charNode(cls, flags)
		end
		if string.match(e, "[1-9]") then
			local digits = e .. (string.match(p.src, "^%d*", p.pos) or "")
			p.pos += #digits - 1
			local node: Node = { t = "backref", index = tonumber(digits), ci = flags.i }
			table.insert(p.backrefs, node)
			return node
		end
		local cp = charEscape(p, e, false)
		if cp == nil then
			fail(p, "unknown escape \\" .. e)
		end
		return charNode(set({ cp :: number, cp :: number }), flags)
	end
	local cp = literalAt(p)
	return charNode(set({ cp, cp }), flags)
end

-- {n}, {n,}, {n,m} at the cursor, or nil (then "{" is a literal).
local function parseBraces(p: Parser): (number?, number?)
	local a, b, len
	local body = string.match(p.src, "^{(%d*,?%d*)}", p.pos)
	if body == nil or body == "" or body == "," then
		return nil, nil
	end
	len = #body + 2
	local lo, comma, hi = string.match(body, "^(%d*)(,?)(%d*)$")
	if lo == nil or lo == "" then
		return nil, nil
	end
	a = tonumber(lo) :: number
	if comma == "" then
		b = a
	elseif hi == "" then
		b = math.huge
	else
		b = tonumber(hi) :: number
	end
	if b < a then
		fail(p, "numbers out of order in {} quantifier")
	end
	if a > MAX_REPEAT or (b ~= math.huge and b > MAX_REPEAT) then
		fail(p, "repeat count over " .. MAX_REPEAT)
	end
	p.pos += len
	return a, b
end

local function parseSeq(p: Parser, flags: Flags): Node
	local items: { Node } = {}
	while not atEnd(p) do
		local c = peek(p)
		if c == "|" or c == ")" then
			break
		end
		local atom: Node?
		if c == "{" then
			local a = parseBraces(p)
			if a ~= nil then
				fail(p, "nothing to repeat")
			end
			p.pos += 1
			atom = charNode(set({ 123, 123 }), flags)
		else
			atom = parseAtom(p, flags)
		end
		if atom == nil then
			continue
		end
		while true do
			local q = peek(p)
			local lo: number?, hi: number? = nil, nil
			if q == "*" then
				lo, hi = 0, math.huge
				p.pos += 1
			elseif q == "+" then
				lo, hi = 1, math.huge
				p.pos += 1
			elseif q == "?" then
				lo, hi = 0, 1
				p.pos += 1
			elseif q == "{" then
				lo, hi = parseBraces(p)
			end
			if lo == nil then
				break
			end
			local greedy = true
			if peek(p) == "?" then
				greedy = false
				p.pos += 1
			end
			atom = { t = "quant", node = atom, min = lo, max = hi, greedy = greedy }
		end
		table.insert(items, atom)
	end
	if #items == 1 then
		return items[1]
	end
	return { t = "seq", items = items }
end

parseAlt = function(p: Parser, flags: Flags): Node
	local first = parseSeq(p, flags)
	if peek(p) ~= "|" then
		return first
	end
	local items = { first }
	while peek(p) == "|" do
		p.pos += 1
		table.insert(items, parseSeq(p, flags))
	end
	return { t = "alt", items = items }
end

-- Compiler -------------------------------------------------------------------

local function isWordAt(s: string, i: number): boolean
	local b = byte(s, i)
	return b ~= nil and ((b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95)
end

local function compileNode(node: Node, ctx: Ctx): Matcher
	local function tick()
		ctx.steps += 1
		if ctx.steps > ctx.budget then
			error(BUDGET, 0)
		end
	end
	local t = node.t
	if t == "set" then
		local cs = node.set :: CharSet
		local ci = node.ci == true
		return function(i: number, k: Cont): number?
			tick()
			if i > ctx.n then
				return nil
			end
			local cp, j = decode(ctx.s, i)
			if setTest(cs, cp) or (ci and setTest(cs, swapCase(cp))) then
				return k(j)
			end
			return nil
		end
	elseif t == "seq" then
		local ms: { Matcher } = {}
		for x, item in node.items :: { Node } do
			ms[x] = compileNode(item, ctx)
		end
		local function build(idx: number): Matcher
			if idx == #ms then
				return ms[idx]
			end
			local head, rest = ms[idx], build(idx + 1)
			return function(i: number, k: Cont): number?
				return head(i, function(j: number): number?
					return rest(j, k)
				end)
			end
		end
		if #ms == 0 then
			return function(i: number, k: Cont): number?
				return k(i)
			end
		end
		return build(1)
	elseif t == "alt" then
		local ms: { Matcher } = {}
		for x, item in node.items :: { Node } do
			ms[x] = compileNode(item, ctx)
		end
		return function(i: number, k: Cont): number?
			for _, m in ms do
				tick()
				local r = m(i, k)
				if r then
					return r
				end
			end
			return nil
		end
	elseif t == "group" then
		local inner = compileNode(node.node :: Node, ctx)
		local index = node.index
		if index == nil then
			return inner
		end
		local a, b = 2 * index - 1, 2 * index
		return function(i: number, k: Cont): number?
			return inner(i, function(j: number): number?
				local caps = ctx.caps
				local os, oe = caps[a], caps[b]
				caps[a], caps[b] = i, j
				local r = k(j)
				if r == nil then
					caps[a], caps[b] = os, oe
				end
				return r
			end)
		end
	elseif t == "quant" then
		local sub = node.node :: Node
		local lo, hi, greedy = node.min :: number, node.max :: number, node.greedy == true
		if sub.t == "set" then
			-- One character per iteration: scan iteratively, then back off.
			local cs = sub.set :: CharSet
			local ci = sub.ci == true
			return function(i: number, k: Cont): number?
				local positions = { i }
				local pos, count = i, 0
				local s, n = ctx.s, ctx.n
				while count < hi and pos <= n do
					tick()
					local cp, j = decode(s, pos)
					if not (setTest(cs, cp) or (ci and setTest(cs, swapCase(cp)))) then
						break
					end
					count += 1
					pos = j
					positions[count + 1] = pos
					if not greedy and count >= lo then
						-- Lazy: stop scanning once the rest can be tried.
						break
					end
				end
				if count < lo then
					return nil
				end
				if greedy then
					for c = count, lo, -1 do
						tick()
						local r = k(positions[c + 1])
						if r then
							return r
						end
					end
					return nil
				end
				-- Lazy: try the fewest first, extending one at a time.
				local c = lo
				local at = positions[c + 1]
				while true do
					tick()
					local r = k(at)
					if r then
						return r
					end
					if c >= hi or at > n then
						return nil
					end
					local cp, j = decode(s, at)
					if not (setTest(cs, cp) or (ci and setTest(cs, swapCase(cp)))) then
						return nil
					end
					c += 1
					at = j
				end
			end
		end
		local inner = compileNode(sub, ctx)
		local function rec(i: number, count: number, k: Cont): number?
			tick()
			if count < lo then
				return inner(i, function(j: number): number?
					return rec(j, count + 1, k)
				end)
			end
			local function more(): number?
				if count >= hi then
					return nil
				end
				return inner(i, function(j: number): number?
					-- An empty iteration cannot make progress.
					if j == i then
						return nil
					end
					return rec(j, count + 1, k)
				end)
			end
			if greedy then
				local r = more()
				if r then
					return r
				end
				return k(i)
			end
			local r = k(i)
			if r then
				return r
			end
			return more()
		end
		return function(i: number, k: Cont): number?
			return rec(i, 0, k)
		end
	elseif t == "bol" then
		local multi = node.multiline == true
		return function(i: number, k: Cont): number?
			if i == 1 or (multi and byte(ctx.s, i - 1) == 10) then
				return k(i)
			end
			return nil
		end
	elseif t == "eol" then
		local multi = node.multiline == true
		return function(i: number, k: Cont): number?
			if i == ctx.n + 1 or (multi and byte(ctx.s, i) == 10) then
				return k(i)
			end
			return nil
		end
	elseif t == "wordb" then
		local negate = node.negate == true
		return function(i: number, k: Cont): number?
			local at = (i > 1 and isWordAt(ctx.s, i - 1)) ~= isWordAt(ctx.s, i)
			if at ~= negate then
				return k(i)
			end
			return nil
		end
	elseif t == "backref" then
		local index = node.index :: number
		local ci = node.ci == true
		return function(i: number, k: Cont): number?
			tick()
			local a, b = ctx.caps[2 * index - 1], ctx.caps[2 * index]
			if a == nil or b == nil then
				return k(i)
			end
			local want = string.sub(ctx.s, a, b - 1)
			local got = string.sub(ctx.s, i, i + #want - 1)
			if got == want or (ci and string.lower(got) == string.lower(want)) then
				return k(i + #want)
			end
			return nil
		end
	elseif t == "look" then
		local inner = compileNode(node.node :: Node, ctx)
		local negate = node.negate == true
		local function stop(j: number): number?
			return j
		end
		return function(i: number, k: Cont): number?
			local hit = inner(i, stop) ~= nil
			if hit ~= negate then
				return k(i)
			end
			return nil
		end
	end
	error("regex: unknown node " .. t)
end

local function anchoredAtStart(node: Node): boolean
	if node.t == "bol" then
		return node.multiline ~= true
	elseif node.t == "seq" then
		local items = node.items :: { Node }
		return #items > 0 and anchoredAtStart(items[1])
	elseif node.t == "group" then
		return anchoredAtStart(node.node :: Node)
	elseif node.t == "alt" then
		for _, item in node.items :: { Node } do
			if not anchoredAtStart(item) then
				return false
			end
		end
		return true
	end
	return false
end

-- Public API -----------------------------------------------------------------

function M.compile(source: string, flags: string?): (Regex?, string?)
	local f = flags or ""
	local fl: Flags = { i = false, m = false, s = false }
	local global = false
	for k = 1, #f do
		local c = string.sub(f, k, k)
		if c == "i" or c == "m" or c == "s" then
			(fl :: any)[c] = true
		elseif c == "g" then
			global = true
		elseif c ~= "u" then
			return nil, "regex: unsupported flag " .. c
		end
	end
	local initial = table.clone(fl)
	local p: Parser = { src = source, pos = 1, ncap = 0, names = {}, backrefs = {} }
	local ok, res = pcall(function(): Node
		local node = parseAlt(p, fl)
		if not atEnd(p) then
			fail(p, if peek(p) == ")" then "unmatched )" else "unexpected character")
		end
		for _, ref in p.backrefs do
			if (ref.index :: number) > p.ncap then
				fail(p, "invalid backreference \\" .. tostring(ref.index))
			end
		end
		return node
	end)
	if not ok then
		local msg = tostring(res)
		if string.sub(msg, 1, #PARSE_TAG) == PARSE_TAG then
			return nil, "regex: " .. string.sub(msg, #PARSE_TAG + 1)
		end
		error(res, 0)
	end
	local ctx: Ctx = { s = "", n = 0, caps = {}, steps = 0, budget = M.STEP_BUDGET }
	local node = res :: Node
	return {
		source = source,
		flags = f,
		global = global,
		ignore_case = initial.i,
		multiline = initial.m,
		dotall = initial.s,
		groups = p.ncap,
		names = p.names,
		_m = compileNode(node, ctx),
		_ctx = ctx,
		_anchored = anchoredAtStart(node),
	},
		nil
end

-- Grafana's stringToJsRegex (packages/grafana-data/src/text/string.ts): text
-- not starting with "/" matches whole values (`^text$`); "/body/flags" with
-- flags in g?i?m?y?s? order is the body with those flags.
function M.parseJs(text: string): (Regex?, string?)
	if string.sub(text, 1, 1) ~= "/" then
		return M.compile("^" .. text .. "$")
	end
	for j = 2, #text do
		if string.sub(text, j, j) == "/" then
			local flags = string.sub(text, j + 1)
			if string.match(flags, "^g?i?m?y?s?$") then
				if string.find(flags, "y", 1, true) then
					return nil, "regex: unsupported flag y"
				end
				return M.compile(string.sub(text, 2, j - 1), flags)
			end
		end
	end
	return nil, string.format("regex: '%s' is not a valid regular expression", text)
end

local function finalCont(j: number): number?
	return j
end

local function run(re: Regex, s: string, init: number, finish: Cont, anchored: boolean): (Match?, string?)
	local ctx = re._ctx
	ctx.s, ctx.n, ctx.steps, ctx.budget = s, #s, 0, M.STEP_BUDGET
	local ok, res = pcall(function(): Match?
		for start = init, #s + 1 do
			if start > init and isContinuation(s, start) then
				continue
			end
			ctx.caps = {}
			local r = re._m(start, finish)
			if r then
				local groups: { [number]: string } = {}
				local caps = ctx.caps
				for g = 1, re.groups do
					local a, b = caps[2 * g - 1], caps[2 * g]
					if a and b then
						groups[g] = string.sub(s, a, b - 1)
					end
				end
				local named: { [string]: string } = {}
				for name, g in re.names do
					named[name] = groups[g]
				end
				return { start = start, finish = r - 1, groups = groups, named = named }
			end
			if anchored or re._anchored then
				return nil
			end
		end
		return nil
	end)
	ctx.s = ""
	if not ok then
		if res == BUDGET then
			return nil, string.format("regex: step budget exceeded matching /%s/", re.source)
		end
		error(res, 0)
	end
	return res, nil
end

function M.exec(re: Regex, s: string, init: number?): (Match?, string?)
	return run(re, s, init or 1, finalCont, false)
end

-- Like string.find: start, finish and the captures, plus an error message
-- when the step budget ran out.
function M.find(re: Regex, s: string, init: number?): (number?, number?, { [number]: string }?, string?)
	local m, err = M.exec(re, s, init)
	if m == nil then
		return nil, nil, nil, err
	end
	return m.start, m.finish, m.groups, nil
end

function M.test(re: Regex, s: string): (boolean, string?)
	local m, err = M.exec(re, s)
	return m ~= nil, err
end

-- The whole of `s` matches, as `^(?:re)$` (Prometheus and Alertmanager
-- label matchers are fully anchored).
function M.fullMatch(re: Regex, s: string): (boolean, string?)
	local n = #s
	local m, err = run(re, s, 1, function(j: number): number?
		return if j == n + 1 then j else nil
	end, true)
	return m ~= nil, err
end

local function expand(template: string, m: Match, s: string, re: Regex): string
	if not string.find(template, "$", 1, true) then
		return template
	end
	local out: { string } = {}
	local i = 1
	local n = #template
	while i <= n do
		local c = string.sub(template, i, i)
		if c ~= "$" or i == n then
			table.insert(out, c)
			i += 1
			continue
		end
		local nextC = string.sub(template, i + 1, i + 1)
		if nextC == "$" then
			table.insert(out, "$")
			i += 2
		elseif nextC == "&" then
			table.insert(out, string.sub(s, m.start, m.finish))
			i += 2
		elseif nextC == "`" then
			table.insert(out, string.sub(s, 1, m.start - 1))
			i += 2
		elseif nextC == "'" then
			table.insert(out, string.sub(s, m.finish + 1))
			i += 2
		elseif string.match(nextC, "%d") then
			-- Two digits when that group exists, else one (JavaScript).
			local two = tonumber(string.sub(template, i + 1, i + 2))
			local one = tonumber(nextC) :: number
			if two and two >= 10 and two <= re.groups then
				table.insert(out, m.groups[two] or "")
				i += 3
			elseif one >= 1 and one <= re.groups then
				table.insert(out, m.groups[one] or "")
				i += 2
			else
				table.insert(out, "$")
				i += 1
			end
		elseif nextC == "<" and next(re.names) ~= nil then
			local name = string.match(template, "^<([^>]*)>", i + 1)
			if name then
				table.insert(out, m.named[name] or "")
				i += #name + 3
			else
				table.insert(out, "$")
				i += 1
			end
		else
			table.insert(out, "$")
			i += 1
		end
	end
	return table.concat(out)
end

-- String.prototype.replace: the first match, or every match when `all` (default:
-- the regex's g flag). A string replacement expands $1, $&, $$, $`, $', $<name>.
function M.replace(re: Regex, s: string, repl: string | (Match) -> string, all: boolean?): (string, string?)
	local every = if all == nil then re.global else all
	local out: { string } = {}
	local pos = 1
	local search = 1
	while search <= #s + 1 do
		local m, err = M.exec(re, s, search)
		if err then
			return s, err
		end
		if m == nil then
			break
		end
		table.insert(out, string.sub(s, pos, m.start - 1))
		table.insert(out, if type(repl) == "string" then expand(repl, m, s, re) else repl(m))
		pos = m.finish + 1
		if m.finish < m.start then
			-- Empty match: step over one character.
			if m.start > #s then
				break
			end
			local _, j = decode(s, m.start)
			table.insert(out, string.sub(s, m.start, j - 1))
			pos = j
			search = j
		else
			search = m.finish + 1
		end
		if not every then
			break
		end
	end
	table.insert(out, string.sub(s, pos))
	return table.concat(out), nil
end

-- Grafana's escapeRegex: every metacharacter backslash-escaped.
function M.escape(s: string): string
	return (string.gsub(s, "[\\%^%$%*%+%?%.%(%)|%[%]{}/]", "\\%0"))
end

return M
