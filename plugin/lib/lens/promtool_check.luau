--!strict
-- Lens for `promtool check rules`, `promtool check config` and `promtool test
-- rules`: reads promtool's report (cmd/promtool/main.go CheckConfig,
-- checkRules; unittest.go RulesUnitTestResult) into per-file verdicts and
-- renders check runs as diagnostics (file:line:col, rule group, rule, message)
-- and test runs as a pass/fail summary with each failure's expected and
-- actual output. Output it cannot place stays raw (view nil).
--
-- promtool writes verdicts to stdout and failures to stderr; Tern feeds both
-- as one stream in the order written. Prometheus 2.53 heads every test file
-- with `Unit Testing:  <file>`; 3.x prints no header, so its verdicts map onto
-- the file arguments in order.

local EnvModule = require("../env")
local LensTypes = require("./types")
local ui = require("../ui")

type Env = EnvModule.Env
type Node = ui.Node
type Run = LensTypes.Run

local M = {}

-- Claimed command lines (plugin.toml [[lenses]] id "promtool-check").
M.MATCH = {
	"promtool check rules",
	"promtool check rules *",
	"promtool check config *",
	"promtool test rules *",
}

-- Past these the capture stays raw (memory and the 2 s view budget).
M.MAX_LINES = 50000
M.MAX_BYTES = 8 * 1024 * 1024
-- Diagnostics or failures drawn before "N more".
M.MAX_ITEMS = 100
-- Lines of one failure's expected/got text drawn before it is cut.
M.MAX_DETAIL_LINES = 40

-- Invocation ---------------------------------------------------------------------

export type Command = "check-rules" | "check-config" | "test-rules"

export type Invocation = {
	-- nil: not a run this lens renders (`reason` says why).
	command: Command?,
	reason: string?,
	-- File arguments, as typed.
	files: { string },
}

-- Long flags that take a value (`--name value` or `--name=value`).
local VALUE_FLAGS: { [string]: boolean } = {
	lint = true,
	run = true,
	junit = true,
	["enable-feature"] = true,
}

local HELP_FLAGS: { [string]: boolean } = {
	help = true,
	["help-long"] = true,
	["help-man"] = true,
	version = true,
	["completion-script-bash"] = true,
	["completion-script-zsh"] = true,
}

local COMMANDS: { [string]: Command } = {
	["check rules"] = "check-rules",
	["check config"] = "check-config",
	["test rules"] = "test-rules",
}

local function unsupported(inv: Invocation, reason: string): Invocation
	inv.command = nil
	inv.reason = reason
	return inv
end

-- Kingpin rules: flags anywhere after the program, `--name=value`,
-- `--name value`; `--` ends flags; `-h` is help.
function M.parseArgs(program: string, args: { string }): Invocation
	local inv: Invocation = { command = nil, reason = nil, files = {} }
	if program ~= "promtool" then
		return unsupported(inv, "not promtool")
	end
	local positional: { string } = {}
	local afterDashes = false
	local i = 1
	while i <= #args do
		local a = args[i]
		if afterDashes or a == "-" or string.sub(a, 1, 1) ~= "-" then
			table.insert(positional, a)
		elseif a == "--" then
			afterDashes = true
		elseif string.sub(a, 1, 2) == "--" then
			local inline = string.match(a, "^%-%-([^=]+)=")
			local flag: string = inline or string.sub(a, 3)
			if HELP_FLAGS[flag] then
				return unsupported(inv, "help output")
			end
			if inline == nil and VALUE_FLAGS[flag] then
				i += 1
				if args[i] == nil then
					return unsupported(inv, "--" .. flag .. " has no value")
				end
			end
		elseif string.sub(a, 2, 2) == "h" then
			return unsupported(inv, "help output")
		end
		i += 1
	end
	local command: Command? = if #positional >= 2 then COMMANDS[positional[1] .. " " .. positional[2]] else nil
	if command == nil then
		return unsupported(inv, "not a promtool check or test run")
	end
	inv.command = command
	for k = 3, #positional do
		table.insert(inv.files, positional[k])
	end
	return inv
end

-- Report ---------------------------------------------------------------------------

export type Severity = "error" | "warning"

export type Diagnostic = {
	severity: Severity,
	message: string,
	-- Continuation lines (YAML error lists, duplicate-rule details).
	detail: { string },
	path: string?,
	line: number?,
	col: number?,
	group: string?,
	rule: number?,
	rule_name: string?,
}

export type Failure = {
	-- The first line (`alertname: X, time: 1m`), trimmed.
	title: string,
	-- The rest (exp/got), with the common indentation removed.
	detail: { string },
}

-- "warning": only lint findings (they fail the run only with --lint-fatal).
export type Verdict = "ok" | "warning" | "failed" | "pending"

export type FileReport = {
	-- As promtool printed it; nil for a 3.x test file whose name is not known.
	path: string?,
	verdict: Verdict,
	-- "4 rules found", "3 rule files found", "valid config syntax".
	summary: { string },
	diagnostics: { Diagnostic },
	failures: { Failure },
}

export type Report = {
	files: { FileReport },
	-- Warnings not tied to a file (unknown lint option, missing test globs).
	notes: { Diagnostic },
	-- Non-blank lines that were none of the above.
	unparsed: number,
}

local function newFile(path: string?): FileReport
	return { path = path, verdict = "pending", summary = {}, diagnostics = {}, failures = {} }
end

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") :: string
end

-- `L:C: group "g", rule N, "name": message` (rulefmt.Error), optionally with
-- the alternative node's `L:C: ` too; anything else is the message whole.
local function readRuleError(d: Diagnostic, text: string)
	local line, col, rest = string.match(text, "^(%d+):(%d+): (.*)$")
	if line and col and rest then
		local l = tonumber(line) :: number
		local c = tonumber(col) :: number
		-- 0:0 is "no position" (an unset field).
		if l > 0 then
			d.line = l
			d.col = if c > 0 then c else nil
		end
		local _, _, alt = string.match(rest, "^(%d+):(%d+): (.*)$")
		text = alt or rest
	end
	local group, rule, name, message = string.match(text, '^group "(.-)", rule (%d+), "(.-)": (.*)$')
	if group and rule and name and message then
		d.group = group
		d.rule = tonumber(rule)
		d.rule_name = if name ~= "" then name else nil
		d.message = message
	else
		d.message = text
	end
end

-- A diagnostic from a line inside a `FAILED:` block of file `path`.
local function ruleDiagnostic(path: string?, text: string): Diagnostic
	local d: Diagnostic = { severity = "error", message = text, detail = {} }
	local lint = string.match(text, "^lint error (.*)$")
	if lint then
		d.severity = "warning"
		d.message = lint
		return d
	end
	if path and string.sub(text, 1, #path + 2) == path .. ": " then
		d.path = path
		readRuleError(d, string.sub(text, #path + 3))
	else
		readRuleError(d, text)
	end
	return d
end

local function hasPrefix(text: string, path: string): boolean
	return string.sub(text, 1, #path + 2) == path .. ": "
end

-- The file a diagnostic line names (`<path>: ...`), the longest path when
-- several fit.
local function namedFile(files: { FileReport }, text: string): FileReport?
	local best: FileReport? = nil
	for _, f in files do
		local p = f.path
		if p and hasPrefix(text, p) and (best == nil or #p > #((best :: FileReport).path :: string)) then
			best = f
		end
	end
	return best
end

local function startsDiagnostic(files: { FileReport }, text: string): boolean
	return namedFile(files, text) ~= nil
		or string.match(text, "^%d+:%d+: ") ~= nil
		or string.match(text, "^lint error ") ~= nil
		or string.match(text, '^group ".-", rule %d+, ') ~= nil
end

-- Rule errors name their file, so they land on it even when a wrapper (a
-- container, a CI runner) delivered stderr after later files' stdout; lines
-- that name no file belong to the file being checked.
local function readCheck(lines: { string }, report: Report)
	local current: FileReport? = nil
	-- Inside a `FAILED:` block: the file it started under and how many
	-- diagnostics it held.
	local block: FileReport? = nil
	local blockItems = 0
	local last: Diagnostic? = nil
	local function closeBlock()
		local owner = block
		if owner and blockItems == 0 then
			owner.verdict = "failed"
		end
		block, blockItems, last = nil, 0, nil
	end
	for _, raw in lines do
		if string.find(raw, "^%s*$") then
			closeBlock()
			continue
		end
		local path = string.match(raw, "^Checking (.+)$")
		if path then
			closeBlock()
			current = newFile(path)
			table.insert(report.files, current :: FileReport)
			continue
		end
		local unknownLint = string.match(raw, "^WARNING: (unknown lint option: .*)$")
		if unknownLint then
			table.insert(report.notes, { severity = "warning", message = unknownLint, detail = {} })
			continue
		end
		local file = current
		if file == nil then
			report.unparsed += 1
			continue
		end
		local rules = string.match(raw, "^  SUCCESS: (%d+ rules? found)$")
		local ruleFiles = string.match(raw, "^  SUCCESS: (%d+ rule files? found)$")
		local failedText = string.match(raw, "^  FAILED: (.+)$")
		local warning = string.match(raw, "^  WARNING: (.+)$")
		if rules then
			if file.verdict == "pending" then
				file.verdict = "ok"
			end
			table.insert(file.summary, rules)
		elseif ruleFiles then
			table.insert(file.summary, ruleFiles)
		elseif string.match(raw, "^ SUCCESS: .+ is valid prometheus config file syntax$") then
			if file.verdict == "pending" then
				file.verdict = "ok"
			end
			table.insert(file.summary, "valid config syntax")
		elseif raw == "  FAILED:" then
			closeBlock()
			block = file
		elseif failedText then
			closeBlock()
			-- A lint finding about scrape intervals fails only with --lint-fatal.
			local lint = string.find(failedText, "^too long scrape interval") ~= nil
			local d: Diagnostic =
				{ severity = if lint then "warning" else "error", message = failedText, detail = {}, path = file.path }
			if not lint then
				file.verdict = "failed"
			end
			table.insert(file.diagnostics, d)
			block, blockItems, last = file, 1, d
		elseif warning then
			local d: Diagnostic = { severity = "warning", message = warning, detail = {}, path = file.path }
			table.insert(file.diagnostics, d)
			last = d
		elseif block then
			local lastDiag = last
			if lastDiag and not startsDiagnostic(report.files, raw) then
				table.insert(lastDiag.detail, (string.gsub(raw, "%s+$", "")))
			else
				local owner = namedFile(report.files, raw) or file
				local d = ruleDiagnostic(owner.path, raw)
				if d.severity == "error" then
					owner.verdict = "failed"
				elseif owner.verdict == "pending" then
					owner.verdict = "warning"
				end
				table.insert(owner.diagnostics, d)
				blockItems += 1
				last = d
			end
		else
			report.unparsed += 1
		end
	end
	closeBlock()
end

-- Lines with their shared leading whitespace removed (tabs count as one).
local function dedent(lines: { string }): { string }
	local indent = math.huge
	for _, l in lines do
		if not string.find(l, "^%s*$") then
			indent = math.min(indent, #(string.match(l, "^%s*") :: string))
		end
	end
	if indent == math.huge then
		indent = 0
	end
	local out: { string } = table.create(#lines)
	for i, l in lines do
		out[i] = string.sub(l, indent + 1)
	end
	return out
end

local function closeFailure(file: FileReport?, block: { string })
	if file == nil or #block == 0 then
		return
	end
	local title = string.gsub(trim(block[1]), ",$", "")
	local rest: { string } = {}
	for k = 2, #block do
		rest[k - 1] = block[k]
	end
	table.insert(file.failures, { title = title, detail = dedent(rest) })
end

local function readTest(lines: { string }, report: Report)
	local current: FileReport? = nil
	-- Inside a FAILED: block: the lines of the failure being read.
	local inFailed = false
	local block: { string } = {}
	local function verdictFile(): FileReport
		local file = current
		if file and file.verdict == "pending" then
			return file
		end
		-- 3.x: no header, a verdict starts the next file.
		local fresh = newFile(nil)
		table.insert(report.files, fresh)
		current = fresh
		return fresh
	end
	for _, raw in lines do
		local header = string.match(raw, "^Unit Testing:%s+(.+)$")
		local warning = string.match(raw, "^  WARNING: (.+)$")
		if header then
			closeFailure(current, block)
			block, inFailed = {}, false
			current = newFile(header)
			table.insert(report.files, current :: FileReport)
		elseif raw == "  SUCCESS" then
			closeFailure(current, block)
			block, inFailed = {}, false
			verdictFile().verdict = "ok"
		elseif raw == "  FAILED:" then
			closeFailure(current, block)
			block = {}
			verdictFile().verdict = "failed"
			inFailed = true
		elseif warning then
			table.insert(report.notes, { severity = "warning", message = warning, detail = {} })
		elseif string.find(raw, "^%s*$") then
			if inFailed then
				closeFailure(current, block)
				block = {}
			end
		elseif inFailed then
			table.insert(block, (string.gsub(raw, "%s+$", "")))
		elseif string.match(raw, "^DEBUG: ") == nil then
			report.unparsed += 1
		end
	end
	closeFailure(current, block)
end

function M.build(inv: Invocation, lines: { string }): Report
	local report: Report = { files = {}, notes = {}, unparsed = 0 }
	if inv.command == "test-rules" then
		readTest(lines, report)
		-- 3.x names no files: they are the arguments, in order, when they
		-- account for every verdict (an unexpanded glob does not).
		local unnamed = 0
		for _, f in report.files do
			if f.path == nil then
				unnamed += 1
			end
		end
		if unnamed > 0 and unnamed == #report.files and #inv.files == unnamed then
			for k, f in report.files do
				f.path = inv.files[k]
			end
		end
	elseif inv.command then
		readCheck(lines, report)
	end
	return report
end

-- Rendering --------------------------------------------------------------------------

local TITLES: { [string]: string } = {
	["check-rules"] = "promtool check rules",
	["check-config"] = "promtool check config",
	["test-rules"] = "promtool test rules",
}

local function percentPath(p: string): string
	return (
		string.gsub(p, "[^%w/%-%._~]", function(c: string): string
			return string.format("%%%02X", string.byte(c))
		end)
	)
end

-- A `file://` URL for `p` (relative to `cwd`), with `#L<line>C<col>` when
-- known; nil when it cannot be resolved (no cwd, `~`, standard input).
function M.fileHref(p: string, cwd: string?, line: number?, col: number?): string?
	local abs: string
	if string.sub(p, 1, 1) == "/" then
		abs = p
	elseif cwd and string.sub(cwd, 1, 1) == "/" and string.sub(p, 1, 1) ~= "~" and p ~= "standard input" then
		abs = string.gsub(cwd, "/+$", "") .. "/" .. string.gsub(p, "^%./", "")
	else
		return nil
	end
	local href = "file://" .. percentPath(abs)
	if line then
		href ..= "#L" .. line
		if col then
			href ..= "C" .. col
		end
	end
	return href
end

local function pathSpan(p: string, cwd: string?, line: number?, col: number?): ui.Span
	local text = p
	if line then
		text ..= ":" .. line
		if col then
			text ..= ":" .. col
		end
	end
	local span: ui.Span = { t = text, s = "path" }
	span.href = M.fileHref(p, cwd, line, col)
	return span
end

local VERDICT_BADGE: { [Verdict]: { text: string, tone: string } } = {
	ok = { text = "OK", tone = "success" },
	warning = { text = "LINT", tone = "warning" },
	failed = { text = "FAILED", tone = "error" },
	pending = { text = "?", tone = "muted" },
}

local function fileRow(f: FileReport, index: number, cwd: string?): Node
	local badge = VERDICT_BADGE[f.verdict]
	local spans: { ui.SpanLike } = {
		if f.path then pathSpan(f.path, cwd, nil, nil) else ui.span("file " .. index, "muted"),
	}
	if #f.summary > 0 then
		table.insert(spans, ui.span("  " .. table.concat(f.summary, ", "), "muted"))
	end
	return ui.row({ ui.badge(badge.text, badge.tone), ui.text(spans) }, { key = "f" .. index })
end

-- A diagnostic card the way tern.ui.diagnostic draws one: toned by severity,
-- keyed by location, the location linking to the file.
local function diagnosticCard(d: Diagnostic, key: string, cwd: string?): Node
	local head: { ui.SpanLike } = {}
	if d.path then
		table.insert(head, pathSpan(d.path, cwd, d.line, d.col))
	elseif d.line then
		table.insert(head, ui.span(string.format("%d:%d", d.line, d.col or 0), "path"))
	end
	if d.group then
		table.insert(head, ui.span(string.format("  group %s", d.group), "muted"))
	end
	if d.rule then
		table.insert(head, ui.span(string.format("  rule %d", d.rule), "muted"))
		if d.rule_name then
			table.insert(head, ui.span("  " .. d.rule_name, "strong"))
		end
	end
	if #head == 0 then
		table.insert(head, ui.span(if d.severity == "error" then "error" else "warning", d.severity))
	end
	local children: { Node } = {
		ui.text({ ui.span(d.message, d.severity) }, { key = "m", actions = { click = "copy" }, title = "Copy" }),
	}
	if #d.detail > 0 then
		table.insert(children, ui.code(table.concat(d.detail, "\n"), nil, nil, { key = "d" }))
	end
	return ui.card(head, children, { tone = d.severity, key = key })
end

local function failureCard(f: Failure, key: string): Node
	local children: { Node } = {}
	if #f.detail > 0 then
		local shown = math.min(#f.detail, M.MAX_DETAIL_LINES)
		local text = table.concat(f.detail, "\n", 1, shown)
		if shown < #f.detail then
			text ..= string.format("\n... %d more lines (Raw shows everything)", #f.detail - shown)
		end
		table.insert(children, ui.code(text, nil, nil, { key = "d" }))
	end
	return ui.card(
		{ ui.span(f.title, "error") },
		children,
		{ tone = "error", key = key, actions = { click = "copy" }, title = "Copy" }
	)
end

-- tern.ui.test_summary: a stacked pass/fail meter and the counts, toned by
-- whether anything failed.
function M.summaryNode(passed: number, failed: number, unit: string): Node
	local total = passed + failed
	local parts = {}
	if total > 0 then
		table.insert(parts, { value = passed / total, token = "success", label = "passed" })
		table.insert(parts, { value = failed / total, token = "error", label = "failed" })
	end
	local label = string.format("%d passed", passed)
	if failed > 0 then
		label ..= string.format(" · %d failed", failed)
	end
	return ui.row({
		{ k = "meter", p = { parts = parts, label = { { t = label } }, size = "sm" } },
		ui.text({ ui.span(unit, "muted") }),
	}, { key = "summary", tone = if failed > 0 then "error" else "success" })
end

local function more(hidden: number): Node
	return ui.muted(string.format("... %d more (Raw shows everything)", hidden))
end

-- The native view, or nil for raw (nothing promtool-shaped was read).
function M.render(inv: Invocation, report: Report, status: number, cwd: string?): Node?
	local command = inv.command
	if command == nil or #report.files == 0 then
		return nil
	end
	local passed, failed = 0, 0
	for _, f in report.files do
		if f.verdict == "ok" or f.verdict == "warning" then
			passed += 1
		elseif f.verdict == "failed" then
			failed += 1
		end
	end
	local children: { Node } = {}
	local isTest = command == "test-rules"
	table.insert(children, M.summaryNode(passed, failed, if #report.files == 1 then "file" else "files"))
	for _, note in report.notes do
		table.insert(children, ui.text({ ui.span(note.message, "warning") }))
	end
	local budget = M.MAX_ITEMS
	local hidden = 0
	for i, f in report.files do
		table.insert(children, fileRow(f, i, cwd))
		local items = if isTest then #f.failures else #f.diagnostics
		for k = 1, items do
			if budget <= 0 then
				hidden += 1
				continue
			end
			budget -= 1
			local key = string.format("f%d.%d", i, k)
			if isTest then
				table.insert(children, failureCard(f.failures[k], key))
			else
				table.insert(children, diagnosticCard(f.diagnostics[k], key, cwd))
			end
		end
	end
	if hidden > 0 then
		table.insert(children, more(hidden))
	end
	if failed == 0 and status ~= 0 then
		table.insert(children, ui.muted(string.format("promtool exited with status %d", status)))
	end
	if report.unparsed > 0 then
		table.insert(
			children,
			ui.muted(
				string.format(
					"%d %s not shown (Raw shows everything)",
					report.unparsed,
					if report.unparsed == 1 then "line" else "lines"
				)
			)
		)
	end
	local head: { ui.SpanLike } = { ui.span(TITLES[command], "strong") }
	return ui.card(head, children, { tone = if failed > 0 or status ~= 0 then "error" else "success" })
end

-- Lens --------------------------------------------------------------------------------------

export type State = {
	invocation: Invocation,
	cwd: string?,
	lines: { string },
	bytes: number,
	overflow: boolean,
	status: number?,
	report: Report?,
}

function M.open(run: Run): State
	return {
		invocation = M.parseArgs(run.program, run.args),
		cwd = run.cwd,
		lines = {},
		bytes = 0,
		overflow = false,
		status = nil,
		report = nil,
	}
end

function M.line(state: State, text: string)
	if state.invocation.command == nil or state.overflow then
		return
	end
	state.bytes += #text + 1
	if #state.lines >= M.MAX_LINES or state.bytes > M.MAX_BYTES then
		state.overflow = true
		state.lines = {}
		return
	end
	table.insert(state.lines, text)
end

function M.finish(state: State, status: number)
	state.status = status
end

-- Raw while promtool runs: a file's verdict and its failures arrive together
-- at the end of each file.
function M.view(state: State, _env: Env): Node?
	local status = state.status
	if state.invocation.command == nil or state.overflow or status == nil then
		return nil
	end
	local report = state.report
	if report == nil then
		report = M.build(state.invocation, state.lines)
		state.report = report
	end
	return M.render(state.invocation, report :: Report, status, state.cwd)
end

local lens: LensTypes.Lens<State> = {
	open = M.open,
	line = M.line,
	finish = M.finish,
	view = M.view,
}
M.lens = lens

return M
