--!strict
-- Shared by the lens specs: recorded CLI captures as Tern feeds them, Tern's
-- lens claim matching, and view-tree queries.
local Fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")

local M = {}

export type Capture = { path: string, command: string, lines: { string }, status: number }

local manifest: { [string]: { command: string, status: number } } = {}
for line in string.gmatch(Fixtures.read("MANIFEST.tsv"), "[^\n]+") do
	local path, method, command, status = string.match(line, "^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)")
	if path and method and command and status then
		manifest[path] = { command = command, status = tonumber(status) or 0 }
	end
end

-- The MANIFEST row of a capture: the command (or URL) and exit (or HTTP) status.
function M.manifest(path: string): { command: string, status: number }?
	return manifest[path]
end

local function splitLines(text: string): { string }
	local lines: { string } = {}
	for raw in string.gmatch(text, "([^\n]*)\n?") do
		table.insert(lines, (string.gsub(raw, "%s+$", "")))
	end
	while #lines > 0 and lines[#lines] == "" do
		table.remove(lines)
	end
	return lines
end

-- A CLI capture's lines as Tern feeds them (trailing blanks trimmed): stdout,
-- then stderr. With `stderrAfter`, the stderr lines are spliced in after that
-- many stdout lines instead: promtool writes both unbuffered, so the
-- terminal shows them in the order they were written, not grouped.
function M.capture(path: string, stderrAfter: number?): Capture
	local entry = manifest[path]
	assert(entry, "no MANIFEST row for " .. path)
	local out = splitLines(Fixtures.read(path))
	local errPath = string.gsub(path, "%.txt$", ".stderr")
	local err = if Fixtures.has(errPath) then splitLines(Fixtures.read(errPath)) else {}
	local at = math.min(stderrAfter or #out, #out)
	local lines: { string } = {}
	for i = 1, at do
		table.insert(lines, out[i])
	end
	for _, l in err :: { string } do
		table.insert(lines, l)
	end
	for i = at + 1, #out do
		table.insert(lines, out[i])
	end
	while #lines > 0 and lines[#lines] == "" do
		table.remove(lines)
	end
	return { path = path, command = entry.command, lines = lines, status = entry.status }
end

-- An HTTP body capture as curl prints it: one line per body line.
function M.body(path: string): { string }
	return splitLines(Fixtures.read(path))
end

-- Tern's claim test (docs: Command Lenses > Matching): the program and its
-- unquoted arguments joined by single spaces, against globs where `*` is any
-- run of characters (none included), `?` exactly one, anything else itself.
function M.globMatch(pattern: string, text: string): boolean
	local parts: { string } = { "^" }
	for i = 1, #pattern do
		local c = string.sub(pattern, i, i)
		if c == "*" then
			table.insert(parts, ".*")
		elseif c == "?" then
			table.insert(parts, ".")
		else
			table.insert(parts, (string.gsub(c, "%p", "%%%0")))
		end
	end
	table.insert(parts, "$")
	return string.find(text, table.concat(parts)) ~= nil
end

export type LensClaim = { id: string, match: { string } }

-- The lens that claims `program args...`: the first lens, in manifest order,
-- with a matching pattern; nil when none does.
function M.claim(lenses: { LensClaim }, program: string, args: { string }): string?
	local text = program
	if #args > 0 then
		text ..= " " .. table.concat(args, " ")
	end
	for _, lens in lenses do
		for _, pattern in lens.match do
			if M.globMatch(pattern, text) then
				return lens.id
			end
		end
	end
	return nil
end

function M.env(config: any?): any
	return { now_ms = 0, decode = json.decode, encode = json.encode, null = json.null, config = config }
end

function M.run(program: string, args: { string }, cwd: string?): any
	return { line = program .. " " .. table.concat(args, " "), typed = "", cwd = cwd, program = program, args = args }
end

-- Every node in a view tree matching `pred`.
function M.findAll(node: any, pred: (any) -> boolean, out: { any }?): { any }
	local acc = out or {}
	if type(node) ~= "table" then
		return acc
	end
	if pred(node) then
		table.insert(acc, node)
	end
	for _, child in node.c or {} do
		M.findAll(child, pred, acc)
	end
	return acc
end

local function always(_: any): boolean
	return true
end

-- Every visible string in a view tree, `|`-joined.
function M.textOf(node: any): string
	local parts: { string } = {}
	for _, n in M.findAll(node, always) do
		local p = n.p or {}
		if type(p.text) == "string" then
			table.insert(parts, p.text)
		end
		for _, key in { "spans", "head", "label" } do
			local list = p[key]
			if type(list) == "table" then
				for _, s in list do
					if type(s) == "table" and type(s.t) == "string" then
						table.insert(parts, s.t)
					end
				end
			end
		end
		for _, item in p.items or {} do
			for _, s in item.k do
				table.insert(parts, s.t)
			end
			for _, s in item.v do
				table.insert(parts, s.t)
			end
		end
	end
	return table.concat(parts, "|")
end

function M.contains(haystack: string, needle: string): boolean
	return string.find(haystack, needle, 1, true) ~= nil
end

function M.withAction(act: string): (any) -> boolean
	return function(n: any): boolean
		return n.p ~= nil and n.p.actions ~= nil and n.p.actions.click == act
	end
end

function M.ofKind(k: string): (any) -> boolean
	return function(n: any): boolean
		return n.k == k
	end
end

return M
