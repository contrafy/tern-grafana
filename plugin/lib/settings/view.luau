--!strict
-- View of the Settings block (pure): header with the config path and its
-- validation state, then one page: the context list, an edit form, the
-- starter templates or a confirmation. Header values whose names look like
-- credentials are masked everywhere.

local ConfigTypes = require("../config/types")
local Effect = require("../effect")
local Env = require("../env")
local Json = require("./json")
local Model = require("./model")
local State = require("./state")
local Validate = require("../config/validate")
local ui = require("../ui")

type State = State.State
type Node = ui.Node
type SpanLike = ui.SpanLike
type Problem = ConfigTypes.Problem

local M = {}

local function chip(text: string, action: string, key: string, props: { [string]: any }?): Node
	local p: { [string]: any } = { actions = { click = action }, role = "tern-grafana.chip", key = key }
	if props then
		for k, v in props do
			p[k] = v
		end
	end
	return ui.badge(text, p.tone or "neutral", p)
end

local function cell(class: string, children: { Node }, props: { [string]: any }?): Node
	local p: { [string]: any } = { class = "tg-set-c " .. class }
	if props then
		for k, v in props do
			p[k] = v
		end
	end
	return ui.el("div", p, children)
end

local function loadBadge(s: State): Node
	local text, tone
	if not s.loaded then
		text, tone = "loading", "neutral"
	elseif s.path == nil then
		text, tone = "no config path", "error"
	elseif s.read_error then
		text, tone = "unreadable", "error"
	elseif not s.exists then
		text, tone = "no file yet", "warning"
	elseif s.decode_error then
		text, tone = "not a JSON object", "error"
	elseif #s.problems > 0 then
		text, tone = #s.problems .. (if #s.problems == 1 then " problem" else " problems"), "error"
	else
		text, tone = "valid", "success"
	end
	return ui.badge(text, tone, { key = "load", role = "tern-grafana.settings-load" })
end

local function header(s: State): Node
	local bar: { Node } = {
		ui.text({ ui.span("Grafana settings", "strong") }, { key = "t" }),
		loadBadge(s),
	}
	local default = Model.defaultContext(s.raw)
	if default then
		table.insert(bar, ui.badge("default " .. default, "accent", { key = "def" }))
	end
	if s.writing then
		table.insert(bar, ui.badge("writing", "warning", { key = "w" }))
	end
	table.insert(bar, chip("Reload", "reload", "reload", { title = "Re-read the file (R)" }))
	if s.exists then
		table.insert(bar, chip("Open file", "open", "open", { title = "Open the file in Tern (o)" }))
	end
	table.insert(bar, chip("?", "help", "help", { title = "Keys (?)" }))
	return ui.col({
		ui.row(bar, { key = "bar", wrap = true, role = "tern-grafana.settings-bar" }),
		ui.text({
			ui.span("config ", "muted"),
			ui.span(s.path or "(unknown: neither XDG_CONFIG_HOME nor HOME is set)", "mono"),
		}, { key = "path" }),
	}, { key = "header", role = "tern-grafana.settings-header" })
end

local MESSAGE_STYLE = { info = "muted", success = "success", error = "error" }

local function problemsNode(s: State): Node?
	local lines: { Node } = {}
	local fileError = s.read_error or s.decode_error
	if fileError then
		table.insert(lines, ui.text({ ui.span(fileError, "error") }, { key = "fe" }))
	end
	if s.decode_error == nil then
		for i, p in s.problems do
			table.insert(lines, ui.text({ ui.span(Validate.format(p), "error") }, { key = "p" .. i }))
		end
	end
	if #lines == 0 then
		return nil
	end
	table.insert(
		lines,
		1,
		ui.text({
			ui.span("The file is not used until these are fixed (all of it is ignored, never half of it).", "muted"),
		}, { key = "why" })
	)
	return ui.col(lines, { key = "problems", role = "tern-grafana.settings-problems" })
end

-- List page -----------------------------------------------------------------------------

local function testLines(s: State, context: string, endpoint: string): { Node }
	local test = s.tests[State.testKey(context, endpoint)]
	if test == nil then
		return {}
	end
	local out: { Node } = {}
	if test.error then
		table.insert(out, ui.text({ ui.span("test: " .. test.error, "error") }, { key = "te" }))
		return out
	end
	for i, st in test.steps do
		local r = st.result
		local spans: { SpanLike }
		if r == nil then
			spans = { ui.span(st.step .. ": testing ...", "muted") }
		elseif r.ok then
			spans = { ui.span(st.step .. ": " .. (r.text or "ok"), "success") }
		else
			spans = { ui.span(st.step .. ": " .. (r.error or "failed"), "error") }
			if r.hint then
				table.insert(spans, ui.span("  fix: " .. r.hint, "muted"))
			end
		end
		table.insert(out, ui.text(spans, { key = "t" .. i }))
	end
	return out
end

local function endpointDetail(s: State, context: string, endpoint: string): { Node }
	local ep = Model.rawEndpoint(s.raw, context, endpoint)
	if ep == nil then
		return { ui.muted("(not an object)") }
	end
	local sum = Model.summary(ep)
	local first: { SpanLike } = { ui.span(sum.url, "mono") }
	if sum.path_prefix then
		table.insert(first, ui.span(" prefix " .. sum.path_prefix, "mono muted"))
	end
	local out: { Node } = {
		ui.text(first, { key = "u" }),
		ui.text({ ui.span("auth ", "muted"), ui.span(sum.auth, "mono") }, { key = "a" }),
	}
	if #sum.headers > 0 then
		table.insert(
			out,
			ui.text({ ui.span("headers ", "muted"), ui.span(table.concat(sum.headers, ", "), "mono") }, { key = "h" })
		)
	end
	if sum.tls then
		table.insert(out, ui.text({ ui.span("tls ", "muted"), ui.span(sum.tls, "mono") }, { key = "tls" }))
	end
	if sum.datasources then
		table.insert(
			out,
			ui.text({ ui.span("datasources ", "muted"), ui.span(sum.datasources, "mono") }, { key = "ds" })
		)
	end
	if #sum.extra > 0 then
		table.insert(out, ui.text({ ui.span(table.concat(sum.extra, ", "), "muted") }, { key = "x" }))
	end
	for _, n in testLines(s, context, endpoint) do
		table.insert(out, n)
	end
	return out
end

local function rowNode(s: State, i: number, row: State.Row): Node
	local selected = i == s.sel
	local cells: { Node }
	if row.kind == "add" then
		cells = {
			cell("tg-set-name", { ui.text({ ui.span("+ new context", "accent") }) }),
			cell("tg-set-ctl", { ui.row({ chip("Add", "new_context", "n", { title = "New context (n)" }) }) }),
			cell("tg-set-detail", { ui.muted("a context is one environment: a lab, a cluster, a Grafana stack") }),
		}
	elseif row.kind == "context" then
		local name = row.context :: string
		local isDefault = Model.defaultContext(s.raw) == name
		local count = #Model.endpointNames(s.raw, name)
		local controls: { Node } = {
			chip("Test", "test=" .. row.key, "t", { title = "Test every endpoint (t)" }),
			chip("Add endpoint", "add_endpoint=" .. row.key, "a", { title = "Add an endpoint (a)" }),
		}
		if not isDefault or (s.raw and s.raw.default_context ~= name) then
			table.insert(controls, chip("Make default", "default=" .. name, "d", { title = "Set default_context (d)" }))
		end
		table.insert(controls, chip("Rename", "rename=" .. row.key, "r", { title = "Rename (r)" }))
		table.insert(controls, chip("Remove", "remove=" .. row.key, "x", { tone = "error", title = "Remove (x)" }))
		local nameNodes: { Node } = {
			ui.text({
				ui.span(name, "strong mono"),
				ui.span(" " .. count .. (if count == 1 then " endpoint" else " endpoints"), "muted"),
			}),
		}
		if isDefault then
			table.insert(nameNodes, ui.badge("default", "accent", { key = "def" }))
		end
		cells = {
			cell("tg-set-name", { ui.row(nameNodes, { key = "n" }) }),
			cell("tg-set-ctl", { ui.row(controls, { key = "ctl", wrap = true }) }),
		}
	else
		cells = {
			cell("tg-set-name", { ui.text({ ui.span(row.endpoint :: string, "mono strong") }) }),
			cell("tg-set-ctl", {
				ui.row({
					chip("Edit", "edit=" .. row.key, "e", { title = "Edit (enter)" }),
					chip("Test", "test=" .. row.key, "t", { title = "Test connection (t)" }),
					chip("Remove", "remove=" .. row.key, "x", { tone = "error", title = "Remove (x)" }),
				}, { key = "ctl", wrap = true }),
			}),
			cell("tg-set-detail", {
				ui.col(endpointDetail(s, row.context :: string, row.endpoint :: string), { key = "d", gap = "none" }),
			}),
		}
	end
	local class = "tg-set-r"
		.. (if row.kind == "context" then " tg-set-ctx" elseif row.kind == "endpoint" then " tg-set-ep" else "")
	return ui.el("div", {
		key = "r:" .. row.key,
		class = if selected then class .. " tg-set-sel" else class,
		actions = { click = "sel=" .. row.key },
	}, cells)
end

local function listPage(s: State): { Node }
	local rows = State.rows(s)
	if s.raw == nil then
		return {}
	end
	local children: { Node } = {}
	for i, row in rows do
		table.insert(children, rowNode(s, i, row))
	end
	return { ui.el("div", { key = "list", class = "tg-set-grid", role = "tern-grafana.settings-list" }, children) }
end

-- Form page -----------------------------------------------------------------------------

local function formPage(s: State): { Node }
	local form = s.form :: Model.Form
	local fields = Model.fields(form, s.raw)
	local byField, rest = Model.assign(fields, s.form_problems)
	local selected = fields[s.form_sel]
	local out: { Node } = {
		ui.text({ ui.span("Editing ", "muted"), ui.span(State.formTitle(form), "strong mono") }, { key = "ft" }),
	}
	local editing = s.editing
	local text = if editing then editing.text elseif selected then Model.display(form, selected) else ""
	table.insert(out, {
		k = "input",
		p = {
			key = "edit",
			text = text,
			cursor = #text,
			prompt = (if selected then selected.label else "") .. " = ",
			placeholder = if selected and selected.sensitive
				then "hidden; type a new value, empty keeps it"
				elseif selected then selected.hint
				else "",
			class = if editing then "tg-set-editing" else nil,
		},
	})
	if selected then
		table.insert(
			out,
			ui.text({
				ui.span(selected.hint, "muted"),
				ui.span(
					if selected.kind == "enum" then "   enter/space or left/right cycles" else "   enter edits",
					"muted mono"
				),
			}, { key = "hint" })
		)
	end
	local rows: { Node } = {}
	for i, f in fields do
		local problems = byField[f.id]
		local valueText = Model.display(form, f)
		local valueNodes: { Node } = {
			ui.text({
				ui.span(if valueText == "" then "unset" else valueText, if valueText == "" then "muted" else "mono"),
			}),
		}
		if problems then
			for j, message in problems do
				table.insert(valueNodes, ui.text({ ui.span(message, "error") }, { key = "p" .. j }))
			end
		end
		local controls: { Node } = {}
		if string.sub(f.id, 1, 7) == "header:" then
			table.insert(
				controls,
				chip("Remove", "remove_header=" .. string.sub(f.id, 8), "x", { tone = "error", title = "Remove (x)" })
			)
		end
		local class = "tg-set-r" .. (if i == s.form_sel then " tg-set-sel" else "")
		if problems then
			class ..= " tg-set-bad"
		end
		table.insert(
			rows,
			ui.el("div", { key = "f:" .. f.id, class = class, actions = { click = "field=" .. f.id } }, {
				cell("tg-set-name", { ui.text({ ui.span(f.label, "mono") }) }),
				cell("tg-set-detail", { ui.col(valueNodes, { key = "v", gap = "none" }) }),
				cell("tg-set-ctl", { ui.row(controls, { key = "ctl" }) }),
			})
		)
	end
	table.insert(
		out,
		ui.el("div", { key = "fields", class = "tg-set-grid tg-set-form", role = "tern-grafana.settings-form" }, rows)
	)
	for i, p in rest do
		table.insert(out, ui.text({ ui.span(Validate.format(p), "error") }, { key = "rest" .. i }))
	end
	table.insert(
		out,
		ui.row({
			chip(
				"Save",
				"apply",
				"save",
				{ tone = "accent", title = "Validate the whole file and write it (w, ctrl+s)" }
			),
			chip("Cancel", "cancel", "cancel", { title = "Discard (escape)" }),
			ui.muted("Secrets are never typed here: choose where the plugin reads them."),
		}, { key = "actions", wrap = true })
	)
	return out
end

-- Templates and confirm -------------------------------------------------------------------

local function templatesPage(s: State, env: Env.Env): { Node }
	local out: { Node } = {
		ui.text({
			ui.span("No config file yet. ", "strong"),
			ui.span("Pick a starter; it is validated, then written to the path above. Edit it afterwards.", "muted"),
		}, { key = "intro" }),
	}
	local rows: { Node } = {}
	for i, t in Model.TEMPLATES do
		local class = "tg-set-r" .. (if i == s.template_sel then " tg-set-sel" else "")
		table.insert(
			rows,
			ui.el("div", { key = "tp:" .. t.id, class = class, actions = { click = "template=" .. i } }, {
				cell("tg-set-name", { ui.text({ ui.span(t.title, "strong") }) }),
				cell("tg-set-detail", { ui.muted(t.description) }),
				cell("tg-set-ctl", {}),
			})
		)
	end
	table.insert(out, ui.el("div", { key = "templates", class = "tg-set-grid" }, rows))
	local t = Model.TEMPLATES[s.template_sel]
	if t then
		table.insert(out, ui.code(Json.encode(t.raw, env.encode), "json", nil, { key = "preview" }))
		table.insert(
			out,
			ui.row({
				chip("Create config file", "write_template", "write", { tone = "accent", title = "Write it (enter)" }),
			}, { key = "actions" })
		)
	end
	return out
end

local function confirmPage(s: State): { Node }
	local c = s.confirm
	if c == nil then
		return {}
	end
	return {
		ui.text({ ui.span(c.text, "warning") }, { key = "q" }),
		ui.row({
			chip("Remove", "confirm", "yes", { tone = "error", title = "Confirm (y)" }),
			chip("Cancel", "cancel", "no", { title = "Keep it (n, escape)" }),
		}, { key = "actions" }),
	}
end

local HELP: { { string } } = {
	{ "j/k, up/down", "move" },
	{ "enter, e", "edit the endpoint; on a context: add an endpoint" },
	{ "n", "new context" },
	{ "a", "add an endpoint to the selected context" },
	{ "d", "make the selected context the default" },
	{ "r", "rename the selected context" },
	{ "x", "remove (asks first)" },
	{ "t", "test the endpoint (on a context: all of its endpoints)" },
	{ "R", "reload the file" },
	{ "o", "open the file in Tern" },
	{ "form: enter/space", "edit a field or cycle a choice" },
	{ "form: w, ctrl+s", "validate the whole file and save" },
	{ "form: x", "remove the selected header" },
	{ "escape", "cancel the edit, close the form, or close the block" },
}

local function helpLayer(): Node
	local items: { { { SpanLike } } } = {}
	for i, h in HELP do
		items[i] = { { ui.span(h[1], "mono") }, { h[2] } }
	end
	return ui.col({
		ui.text({ ui.span("Settings keys", "strong") }, { key = "h" }),
		ui.kv(items),
		ui.muted("Edits are validated against the whole file before writing; the previous file is kept as .bak."),
	}, { key = "help", role = "tern-grafana.settings-layer" })
end

function M.view(s: State, env: Env.Env): Effect.Regions
	local children: { Node } = { header(s) }
	if s.message then
		local m = s.message :: State.Message
		table.insert(
			children,
			ui.text({ ui.span(m.text, MESSAGE_STYLE[m.level] or "muted") }, {
				key = "message",
				role = "tern-grafana.settings-message",
			})
		)
	end
	local page: { Node }
	if not s.loaded then
		page = { ui.muted("Reading the config file ...", { key = "loading" }) }
	elseif s.page == "form" and s.form then
		page = formPage(s)
	elseif s.page == "templates" then
		page = templatesPage(s, env)
	elseif s.page == "confirm" then
		page = confirmPage(s)
	else
		local problems = problemsNode(s)
		page = if problems then { problems } else {}
		for _, n in listPage(s) do
			table.insert(page, n)
		end
	end
	for _, n in page do
		table.insert(children, n)
	end
	return {
		main = ui.col(children, { role = "tern-grafana.settings" }),
		layer = if s.help then helpLayer() else nil,
	}
end

return M
