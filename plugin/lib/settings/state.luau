--!strict
-- Pure core of the Settings block (`tern-grafana.settings`): loads the config
-- file text, lists contexts and endpoints, runs edit forms, validates every
-- edit against the whole new file before asking the host to write it, and
-- tests endpoints of the saved config. The host (settings_host.luau) reads
-- and atomically writes the file; plugin/block_runner.luau runs the http
-- effects.

local ConfigTypes = require("../config/types")
local EffectTypes = require("../effect")
local Env = require("../env")
local Json = require("./json")
local Model = require("./model")
local Probe = require("./probe")
local Validate = require("../config/validate")

type Config = ConfigTypes.Config
type Problem = ConfigTypes.Problem
type Env = Env.Env
type Raw = Model.Raw
type Form = Model.Form
type Field = Model.Field

local M = {}

-- Custom effects executed by settings_host.luau.
export type ReadEffect = { kind: "config_read" }
export type WriteEffect = {
	kind: "config_write",
	path: string,
	text: string,
	-- Json.hash of the text the edit was computed from; nil when the file did
	-- not exist. The host refuses the write when the file no longer matches.
	base_hash: string?,
}
export type Effect = EffectTypes.Effect | ReadEffect | WriteEffect

export type FileMsg = {
	kind: "config_file",
	path: string?,
	-- nil when the file does not exist or could not be read.
	text: string?,
	exists: boolean,
	error: string?,
}
export type WrittenMsg = { kind: "config_written", ok: boolean, conflict: boolean?, error: string? }
export type Msg = EffectTypes.Msg | FileMsg | WrittenMsg

export type Message = { level: "info" | "success" | "error", text: string }

export type Page = "list" | "form" | "templates" | "confirm"

export type RowKind = "context" | "endpoint" | "add"
export type Row = { key: string, kind: RowKind, context: string?, endpoint: string? }

export type Confirm = {
	action: "remove_context" | "remove_endpoint",
	context: string,
	endpoint: string?,
	text: string,
}

export type TestStep = { step: Probe.Step, result: Probe.StepResult? }
export type Test = { gen: number, steps: { TestStep }, error: string? }

export type Edit = { id: string, text: string }

export type State = {
	loaded: boolean,
	path: string?,
	exists: boolean,
	text: string?,
	hash: string?,
	read_error: string?,
	raw: Raw?,
	-- The file text is not a JSON object: nothing can be edited until fixed.
	decode_error: string?,
	config: Config?,
	problems: { Problem },
	page: Page,
	sel: number,
	sel_key: string?,
	form: Form?,
	form_sel: number,
	editing: Edit?,
	form_problems: { Problem },
	template_sel: number,
	confirm: Confirm?,
	writing: boolean,
	conflict: boolean,
	message: Message?,
	tests: { [string]: Test },
	gen: number,
	help: boolean,
}

M.EDIT_INPUT = "main.edit"

-- Loading -------------------------------------------------------------------------

function M.init(_args: { string }, saved: any, _env: Env): (State, { Effect })
	local s: State = {
		loaded = false,
		path = nil,
		exists = false,
		text = nil,
		hash = nil,
		read_error = nil,
		raw = nil,
		decode_error = nil,
		config = nil,
		problems = {},
		page = "list",
		sel = 1,
		sel_key = if type(saved) == "table" and type(saved.sel) == "string" then saved.sel else nil,
		form = nil,
		form_sel = 1,
		editing = nil,
		form_problems = {},
		template_sel = 1,
		confirm = nil,
		writing = false,
		conflict = false,
		message = nil,
		tests = {},
		gen = 0,
		help = false,
	}
	return s, { { kind = "config_read" } }
end

function M.save(s: State): any
	local row = M.rows(s)[s.sel]
	return { sel = if row then row.key else s.sel_key }
end

function M.title(s: State): string?
	if s.page == "form" and s.form then
		return "Grafana settings: " .. M.formTitle(s.form)
	end
	return "Grafana settings"
end

local function isObject(v: any): boolean
	return type(v) == "table" and (next(v) == nil or #v == 0)
end

local function applyFile(s: State, msg: FileMsg, env: Env)
	s.loaded = true
	s.path = msg.path
	s.exists = msg.exists
	s.text = msg.text
	s.hash = if msg.text then Json.hash(msg.text) else nil
	s.read_error = msg.error
	s.raw = nil
	s.decode_error = nil
	s.config = nil
	s.problems = {}
	s.conflict = false
	if msg.error then
		return
	end
	if msg.text == nil then
		if s.path ~= nil then
			s.page = if s.form then s.page else "templates"
		end
		return
	end
	local ok, raw = pcall(env.decode, msg.text)
	if not ok then
		s.decode_error = "the file is not valid JSON: " .. tostring(raw)
	elseif not isObject(raw) or not string.find(msg.text, "^%s*{") then
		s.decode_error = "the file must contain a JSON object"
	else
		s.raw = raw
	end
	s.config, s.problems = Validate.parseFile(msg.text, env.decode)
	if s.page == "templates" then
		s.page = "list"
	end
end

-- Rows ------------------------------------------------------------------------------

function M.rows(s: State): { Row }
	local out: { Row } = {}
	for _, name in Model.contextNames(s.raw) do
		table.insert(out, { key = name, kind = "context", context = name })
		for _, ep in Model.endpointNames(s.raw, name) do
			table.insert(out, { key = name .. "/" .. ep, kind = "endpoint", context = name, endpoint = ep })
		end
	end
	if s.raw then
		table.insert(out, { key = "+", kind = "add" })
	end
	return out
end

local function selectKey(s: State, key: string?): boolean
	if key == nil then
		return false
	end
	for i, row in M.rows(s) do
		if row.key == key then
			s.sel = i
			s.sel_key = key
			return true
		end
	end
	return false
end

local function clampSel(s: State)
	local rows = M.rows(s)
	if not selectKey(s, s.sel_key) then
		s.sel = math.clamp(s.sel, 1, math.max(1, #rows))
		local row = rows[s.sel]
		s.sel_key = if row then row.key else nil
	end
end

local function moveSel(s: State, delta: number)
	local rows = M.rows(s)
	if #rows == 0 then
		return
	end
	s.sel = math.clamp(s.sel + delta, 1, #rows)
	s.sel_key = rows[s.sel].key
end

function M.selectedRow(s: State): Row?
	return M.rows(s)[s.sel]
end

-- Writes ----------------------------------------------------------------------------

local function formatAll(problems: { Problem }): string
	local lines = table.create(#problems)
	for i, p in problems do
		lines[i] = Validate.format(p)
	end
	return table.concat(lines, "\n")
end

-- Validates `raw` as the whole new file and asks the host to write it.
-- Returns the problems that block the write (empty when the write started).
local function commit(s: State, raw: Raw, env: Env, what: string, effects: { Effect }): { Problem }
	if s.writing then
		return { { path = "", message = "a write is still in progress" } }
	end
	if s.path == nil then
		return { { path = "", message = "the config path is unknown (neither XDG_CONFIG_HOME nor HOME is set)" } }
	end
	if s.read_error then
		return { { path = "", message = s.read_error } }
	end
	if s.decode_error then
		return { { path = "", message = s.decode_error .. "; fix it in an editor (o opens the file)" } }
	end
	local text = Json.encode(raw, env.encode)
	local config, problems = Validate.parseFile(text, env.decode)
	if config == nil then
		return problems
	end
	s.writing = true
	s.message = { level = "info", text = what .. " ..." }
	table.insert(effects, { kind = "config_write", path = s.path :: string, text = text, base_hash = s.hash })
	return {}
end

local function blocked(s: State, what: string, problems: { Problem })
	s.message = { level = "error", text = "Not saved (" .. what .. "):\n" .. formatAll(problems) }
end

-- Forms -------------------------------------------------------------------------------

function M.formTitle(form: Form): string
	if form.mode == "new_context" then
		return "new context"
	elseif form.mode == "new_endpoint" then
		return "new endpoint in " .. form.context
	elseif form.mode == "rename_context" then
		return "rename " .. form.context
	end
	return form.context .. "." .. form.endpoint
end

function M.formFields(s: State): { Field }
	if s.form == nil then
		return {}
	end
	return Model.fields(s.form :: Form, s.raw)
end

local function openForm(s: State, form: Form?)
	if form == nil then
		return
	end
	s.form = form
	s.page = "form"
	s.form_sel = 1
	s.editing = nil
	s.form_problems = {}
	s.message = nil
end

local function closeForm(s: State)
	s.form = nil
	s.editing = nil
	s.form_problems = {}
	s.page = "list"
end

local function selectedField(s: State): Field?
	return M.formFields(s)[s.form_sel]
end

local function startEdit(s: State, f: Field, effects: { Effect })
	local form = s.form :: Form
	if f.kind == "enum" then
		s.form = Model.cycle(form, f, 1)
		return
	end
	s.editing = { id = f.id, text = Model.editText(form, f) }
	table.insert(effects, { kind = "focus", id = M.EDIT_INPUT })
end

local function finishEdit(s: State, effects: { Effect })
	local edit = s.editing :: Edit
	local form, problem = Model.setField(s.form :: Form, edit.id, edit.text)
	if problem then
		s.message = { level = "error", text = problem }
		return
	end
	s.form = form
	s.editing = nil
	s.message = nil
	table.insert(effects, { kind = "focus", id = nil })
end

local function applyForm(s: State, env: Env, effects: { Effect })
	local form = s.form :: Form
	if s.editing then
		finishEdit(s, effects)
		if s.editing then
			return
		end
		form = s.form :: Form
	end
	local raw, problems = Model.applyForm(s.raw, form, env.decode)
	if raw then
		problems = commit(s, raw, env, "Saving " .. M.formTitle(form), effects)
	end
	s.form_problems = problems
	if #problems > 0 then
		s.message = {
			level = "error",
			text = if #problems == 1
				then "Not saved: 1 problem"
				else string.format("Not saved: %d problems", #problems),
		}
	end
end

-- List actions ----------------------------------------------------------------------

local function guardEditable(s: State): boolean
	if s.decode_error or s.read_error then
		s.message = { level = "error", text = (s.decode_error or s.read_error :: string) .. "; o opens the file" }
		return false
	end
	if s.raw == nil then
		s.message = { level = "error", text = "No config file yet: pick a starter template." }
		return false
	end
	return true
end

local function editRow(s: State, row: Row, env: Env)
	if not guardEditable(s) then
		return
	end
	if row.kind == "add" then
		openForm(s, Model.newContextForm())
	elseif row.kind == "endpoint" then
		openForm(s, Model.editForm(s.raw, row.context :: string, row.endpoint :: string, env.encode))
	else
		local form = Model.newEndpointForm(s.raw, row.context :: string)
		if form == nil then
			s.message = { level = "info", text = row.context :: string .. " has every endpoint kind already." }
		end
		openForm(s, form)
	end
end

local function setDefault(s: State, context: string, env: Env, effects: { Effect })
	if not guardEditable(s) then
		return
	end
	if Model.defaultContext(s.raw) == context and (s.raw :: Raw).default_context == context then
		s.message = { level = "info", text = context .. " is already the default context." }
		return
	end
	local problems = commit(s, Model.setDefault(s.raw, context), env, "Setting default context " .. context, effects)
	if #problems > 0 then
		blocked(s, "default context", problems)
	end
end

local function askRemove(s: State, row: Row)
	if not guardEditable(s) then
		return
	end
	if row.kind == "context" then
		local text = string.format("Remove context %q and all its endpoints?", row.context :: string)
		if (s.raw :: Raw).default_context == row.context then
			text ..= " It is the default context; default_context is unset."
		end
		s.confirm = { action = "remove_context", context = row.context :: string, text = text }
	elseif row.kind == "endpoint" then
		s.confirm = {
			action = "remove_endpoint",
			context = row.context :: string,
			endpoint = row.endpoint,
			text = string.format("Remove endpoint %s from context %q?", row.endpoint :: string, row.context :: string),
		}
	else
		return
	end
	s.page = "confirm"
end

local function confirm(s: State, env: Env, effects: { Effect })
	local c = s.confirm
	s.confirm = nil
	s.page = "list"
	if c == nil then
		return
	end
	local raw = if c.action == "remove_context"
		then Model.removeContext(s.raw, c.context)
		else Model.removeEndpoint(s.raw, c.context, c.endpoint :: string)
	local what = if c.action == "remove_context"
		then "Removing context " .. c.context
		else "Removing " .. c.context .. "." .. (c.endpoint :: string)
	local problems = commit(s, raw, env, what, effects)
	if #problems > 0 then
		blocked(s, "remove", problems)
	end
end

-- Connection tests --------------------------------------------------------------------

local TAG = "test"

function M.testKey(context: string, endpoint: string): string
	return context .. "/" .. endpoint
end

local function testEndpoint(s: State, context: string, endpoint: string, effects: { Effect })
	local key = M.testKey(context, endpoint)
	s.gen += 1
	local config = s.config
	if config == nil then
		s.tests[key] = {
			gen = s.gen,
			steps = {},
			error = "the saved config has problems; fix them first (tests use the saved file)",
		}
		return
	end
	local route = Probe.route(config, context, endpoint)
	if route == nil then
		s.tests[key] = { gen = s.gen, steps = {}, error = "not in the saved config; save it first" }
		return
	end
	local probes = Probe.requests(route)
	local steps: { TestStep } = {}
	for i, p in probes do
		steps[i] = { step = p.step, result = nil }
		table.insert(effects, {
			kind = "http",
			tag = table.concat({ TAG, tostring(s.gen), context, endpoint, p.step }, "|"),
			route = route,
			request = p.request,
		})
	end
	s.tests[key] = { gen = s.gen, steps = steps, error = nil }
end

local function testRow(s: State, row: Row, effects: { Effect })
	s.tests = table.clone(s.tests)
	if row.kind == "endpoint" then
		testEndpoint(s, row.context :: string, row.endpoint :: string, effects)
	elseif row.kind == "context" then
		for _, ep in Model.endpointNames(s.raw, row.context :: string) do
			testEndpoint(s, row.context :: string, ep, effects)
		end
	end
end

local function onHttp(s: State, tag: string, response: any, env: Env): boolean
	local prefix, gen, context, endpoint, step = string.match(tag, "^([^|]+)|(%d+)|([^|]+)|([^|]+)|([^|]+)$")
	if prefix ~= TAG then
		return false
	end
	local key = M.testKey(context :: string, endpoint :: string)
	local test = s.tests[key]
	if test == nil or tostring(test.gen) ~= gen or s.config == nil then
		return false
	end
	local route = Probe.route(s.config :: Config, context :: string, endpoint :: string)
	if route == nil then
		return false
	end
	local result = Probe.parse(route, step :: any, response, env)
	local steps = table.clone(test.steps)
	for i, st in steps do
		if st.step == step then
			steps[i] = { step = st.step, result = result }
		end
	end
	s.tests = table.clone(s.tests)
	s.tests[key] = { gen = test.gen, steps = steps, error = nil }
	return true
end

-- Overall test state: "pending" until every step answered.
function M.testStatus(test: Test): "pending" | "ok" | "error"
	if test.error then
		return "error"
	end
	local status: "pending" | "ok" | "error" = "ok"
	for _, st in test.steps do
		if st.result == nil then
			return "pending"
		elseif not st.result.ok then
			status = "error"
		end
	end
	return status
end

-- Templates ---------------------------------------------------------------------------

local function writeTemplate(s: State, env: Env, effects: { Effect })
	local t = Model.TEMPLATES[s.template_sel]
	if t == nil then
		return
	end
	if s.exists then
		s.message = { level = "error", text = "The config file exists; templates only start a new one." }
		return
	end
	local problems = commit(s, t.raw, env, "Creating " .. (s.path or "config") .. " from " .. t.title, effects)
	if #problems > 0 then
		blocked(s, "template", problems)
	end
end

-- Keys --------------------------------------------------------------------------------

local function printable(key: Key): string?
	if key.ctrl or key.meta or key.alt then
		return nil
	end
	local text = key.text
	if text and #text >= 1 and not string.find(text, "%c") then
		return text
	end
	if #key.name == 1 then
		return if key.shift then string.upper(key.name) else key.name
	end
	if key.name == "space" then
		return " "
	end
	return nil
end

local function editKey(s: State, key: Key, effects: { Effect }): boolean
	local edit = s.editing :: Edit
	local name = key.name
	if name == "escape" then
		s.editing = nil
		s.message = nil
		table.insert(effects, { kind = "focus", id = nil })
	elseif name == "enter" or name == "return" then
		finishEdit(s, effects)
	elseif name == "backspace" then
		s.editing = { id = edit.id, text = string.sub(edit.text, 1, -2) }
	elseif name == "paste" then
		s.editing = { id = edit.id, text = edit.text .. string.gsub(key.text or "", "[\r\n]+", " ") }
	elseif key.ctrl and name == "u" then
		s.editing = { id = edit.id, text = "" }
	else
		local ch = printable(key)
		if ch == nil then
			return false
		end
		s.editing = { id = edit.id, text = edit.text .. ch }
	end
	return true
end

local function formKey(s: State, key: Key, env: Env, effects: { Effect }): boolean
	if s.editing then
		return editKey(s, key, effects)
	end
	local name = key.name
	local ch = printable(key)
	local fields = M.formFields(s)
	if name == "escape" then
		closeForm(s)
		s.message = { level = "info", text = "Edit discarded." }
	elseif (key.ctrl and name == "s") or ch == "w" then
		applyForm(s, env, effects)
	elseif ch == "j" or name == "down" or name == "tab" then
		s.form_sel = math.clamp(s.form_sel + 1, 1, #fields)
	elseif ch == "k" or name == "up" then
		s.form_sel = math.clamp(s.form_sel - 1, 1, #fields)
	elseif name == "enter" or name == "return" or ch == "e" or ch == " " then
		local f = selectedField(s)
		if f == nil then
			return false
		end
		startEdit(s, f, effects)
	elseif name == "left" or name == "right" then
		local f = selectedField(s)
		if f == nil or f.kind ~= "enum" then
			return false
		end
		s.form = Model.cycle(s.form :: Form, f, if name == "left" then -1 else 1)
	elseif ch == "x" then
		local f = selectedField(s)
		if f == nil or string.sub(f.id, 1, 7) ~= "header:" then
			return false
		end
		s.form = Model.removeHeader(s.form :: Form, string.sub(f.id, 8))
	else
		return false
	end
	s.form_sel = math.clamp(s.form_sel, 1, math.max(1, #M.formFields(s)))
	return true
end

local function listKey(s: State, key: Key, env: Env, effects: { Effect }): boolean
	local name = key.name
	local ch = printable(key)
	local row = M.selectedRow(s)
	if ch == "j" or name == "down" then
		moveSel(s, 1)
	elseif ch == "k" or name == "up" then
		moveSel(s, -1)
	elseif ch == "g" or name == "home" then
		moveSel(s, -#M.rows(s))
	elseif ch == "G" or name == "end" then
		moveSel(s, #M.rows(s))
	elseif name == "enter" or name == "return" or ch == "e" then
		if row == nil then
			return false
		end
		editRow(s, row, env)
	elseif ch == "a" then
		if row == nil or row.kind == "add" then
			editRow(s, { key = "+", kind = "add" }, env)
		else
			editRow(s, { key = row.context :: string, kind = "context", context = row.context }, env)
		end
	elseif ch == "n" then
		editRow(s, { key = "+", kind = "add" }, env)
	elseif ch == "d" then
		if row == nil or row.context == nil then
			return false
		end
		setDefault(s, row.context :: string, env, effects)
	elseif ch == "r" then
		if row == nil or row.context == nil or not guardEditable(s) then
			return row ~= nil
		end
		openForm(s, Model.renameForm(row.context :: string))
	elseif ch == "x" or name == "delete" then
		if row == nil then
			return false
		end
		askRemove(s, row)
	elseif ch == "t" then
		if row == nil then
			return false
		end
		testRow(s, row, effects)
	else
		return false
	end
	return true
end

local function templatesKey(s: State, key: Key, env: Env, effects: { Effect }): boolean
	local name = key.name
	local ch = printable(key)
	if ch == "j" or name == "down" then
		s.template_sel = math.clamp(s.template_sel + 1, 1, #Model.TEMPLATES)
	elseif ch == "k" or name == "up" then
		s.template_sel = math.clamp(s.template_sel - 1, 1, #Model.TEMPLATES)
	elseif name == "enter" or name == "return" or ch == "w" then
		writeTemplate(s, env, effects)
	else
		return false
	end
	return true
end

local function onKey(s: State, key: Key, env: Env, effects: { Effect }): boolean
	local name = key.name
	local ch = printable(key)
	if s.page == "form" and s.editing then
		return editKey(s, key, effects)
	end
	if s.help then
		if name == "escape" or ch == "?" then
			s.help = false
			return true
		end
		return false
	end
	if ch == "?" then
		s.help = true
		return true
	end
	if s.page == "confirm" then
		if ch == "y" or name == "enter" or name == "return" then
			confirm(s, env, effects)
		elseif ch == "n" or name == "escape" then
			s.confirm = nil
			s.page = "list"
		else
			return false
		end
		return true
	end
	if s.page == "form" then
		return formKey(s, key, env, effects)
	end
	if ch == "R" then
		s.message = { level = "info", text = "Reloaded the config file." }
		table.insert(effects, { kind = "config_read" })
		return true
	elseif ch == "o" then
		if s.path and s.exists then
			table.insert(effects, { kind = "open", target = s.path :: string })
		else
			s.message = { level = "error", text = "There is no config file to open yet." }
		end
		return true
	elseif name == "escape" then
		table.insert(effects, { kind = "exit" })
		return true
	end
	if s.page == "templates" then
		return templatesKey(s, key, env, effects)
	end
	return listKey(s, key, env, effects)
end

function M.key(prev: State, key: Key, env: Env): (State, { Effect }, boolean)
	local s = table.clone(prev)
	local effects: { Effect } = {}
	local changed = onKey(s, key, env, effects)
	if not changed and #effects == 0 then
		return prev, effects, false
	end
	return s, effects, true
end

-- Click actions ("act=value") -------------------------------------------------------------

local function rowByKey(s: State, key: string): Row?
	if not selectKey(s, key) then
		return nil
	end
	return M.selectedRow(s)
end

local function onAction(s: State, act: string, value: string, env: Env, effects: { Effect }): boolean
	if act == "sel" then
		return selectKey(s, value)
	elseif act == "edit" then
		local row = rowByKey(s, value)
		if row then
			editRow(s, row, env)
		end
	elseif act == "add_endpoint" then
		local row = rowByKey(s, value)
		if row then
			editRow(s, { key = value, kind = "context", context = row.context }, env)
		end
	elseif act == "new_context" then
		editRow(s, { key = "+", kind = "add" }, env)
	elseif act == "rename" then
		local row = rowByKey(s, value)
		if row and row.context and guardEditable(s) then
			openForm(s, Model.renameForm(row.context :: string))
		end
	elseif act == "default" then
		setDefault(s, value, env, effects)
	elseif act == "remove" then
		local row = rowByKey(s, value)
		if row then
			askRemove(s, row)
		end
	elseif act == "test" then
		local row = rowByKey(s, value)
		if row then
			testRow(s, row, effects)
		end
	elseif act == "field" then
		if s.form == nil then
			return false
		end
		for i, f in M.formFields(s) do
			if f.id == value then
				if s.editing and s.editing.id ~= f.id then
					finishEdit(s, effects)
				end
				s.form_sel = i
				if s.editing == nil then
					startEdit(s, f, effects)
				end
				return true
			end
		end
		return false
	elseif act == "remove_header" then
		if s.form == nil then
			return false
		end
		s.form = Model.removeHeader(s.form :: Form, value)
		s.editing = nil
	elseif act == "apply" then
		if s.form == nil then
			return false
		end
		applyForm(s, env, effects)
	elseif act == "cancel" then
		if s.page == "confirm" then
			s.confirm = nil
			s.page = "list"
		elseif s.form then
			closeForm(s)
		end
	elseif act == "confirm" then
		confirm(s, env, effects)
	elseif act == "template" then
		local i = tonumber(value)
		if i == nil or Model.TEMPLATES[i] == nil then
			return false
		end
		s.template_sel = i
	elseif act == "write_template" then
		writeTemplate(s, env, effects)
	elseif act == "reload" then
		return onKey(
			s,
			{ name = "R", text = "R", ctrl = false, alt = false, shift = true, meta = false } :: any,
			env,
			effects
		)
	elseif act == "open" then
		return onKey(
			s,
			{ name = "o", text = "o", ctrl = false, alt = false, shift = false, meta = false } :: any,
			env,
			effects
		)
	elseif act == "help" then
		s.help = not s.help
	else
		return false
	end
	return true
end

-- Update ----------------------------------------------------------------------------------

function M.update(prev: State, msg: Msg, env: Env): (State, { Effect })
	local s = table.clone(prev)
	local effects: { Effect } = {}
	local m: any = msg
	local changed = false
	if m.kind == "config_file" then
		applyFile(s, m, env)
		clampSel(s)
		changed = true
	elseif m.kind == "config_written" then
		s.writing = false
		if m.ok then
			s.message =
				{ level = "success", text = "Saved. New blocks use it; open blocks pick it up when they reload." }
			if s.form then
				closeForm(s)
			end
		elseif m.conflict then
			s.conflict = true
			s.message = {
				level = "error",
				text = "Not saved: the file changed on disk since it was loaded. It has been reloaded"
					.. (if s.form then "; review the form and save again." else "; review and try again."),
			}
		else
			s.message = { level = "error", text = "Not saved: " .. tostring(m.error) }
		end
		table.insert(effects, { kind = "config_read" })
		changed = true
	elseif m.kind == "http_done" then
		changed = onHttp(s, m.tag, m.response, env)
	elseif m.kind == "key" then
		changed = onKey(s, m.key, env, effects)
	elseif m.kind == "event" then
		local ev = m.ev
		if type(ev) == "table" and ev.ev == "action" and type(ev.act) == "string" then
			changed = onAction(s, ev.act, if type(ev.value) == "string" then ev.value else "", env, effects)
		end
	end
	if not changed and #effects == 0 then
		return prev, effects
	end
	return s, effects
end

return M
