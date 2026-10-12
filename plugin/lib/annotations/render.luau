--!strict
-- View of the approve block (lib/annotations/state.luau): what will be
-- posted where, the three choices, and the outcome. The manage view lists
-- the remembered per-context decisions with Forget buttons.

local Api = require("./api")
local Env = require("../env")
local Range = require("../time/range")
local State = require("./state")
local ui = require("../ui")

type Node = ui.Node
type State = State.State
type Draft = Api.Draft

local M = {}

local CHOICE_TEXT: { [string]: { label: string, hint: string, class: string } } = {
	always = { label = "Always", hint = "post now and every later deploy in this context", class = "tg-an-always" },
	once = { label = "Once", hint = "post this one, ask again next time", class = "tg-an-once" },
	never = { label = "Never", hint = "post nothing, never ask in this context", class = "tg-an-never" },
}

local function button(text: string, act: string, key: string, class: string?, title: string?): Node
	return ui.el("button", {
		key = key,
		class = "tg-an-btn" .. (if class then " " .. class else ""),
		text = text,
		title = title,
		actions = { click = act },
	})
end

local function utc(ms: number): string
	return Range.formatMs(ms) .. " UTC"
end

local function note(s: State): Node?
	if s.note == nil then
		return nil
	end
	return ui.text({ ui.span(s.note :: string, s.note_tone) }, { key = "note" })
end

local function draftView(s: State, d: Draft): { Node }
	local out: { Node } = {}
	local status = if d.status == 0 then ui.badge("exit 0", "success") else ui.badge("exit " .. d.status, "error")
	table.insert(
		out,
		ui.row({
			ui.text({ ui.span("Annotate deploy in ", "muted"), ui.span(d.context, "strong") }),
			ui.badge(d.kind, "info"),
			status,
		}, { key = "head", wrap = true })
	)
	-- An `el` (only `el` nodes take a class): the text wraps as Grafana shows it.
	table.insert(out, ui.el("div", { key = "text", class = "tg-an-text", text = d.text }))
	local items: { { { ui.SpanLike } } } = {
		{ { "Grafana" }, { s.grafana or "(context has no grafana endpoint)" } },
		{ { "Tags" }, { table.concat(d.tags, ", ") } },
		{
			{ "Time" },
			{ string.format("%s to %s (%s)", utc(d.time_ms), utc(d.time_end_ms), Api.duration(d.took_ms)) },
		},
	}
	if d.dashboard_uid then
		local where = "dashboard " .. d.dashboard_uid
		if d.panel_id then
			where ..= ", panel " .. tostring(d.panel_id)
		end
		table.insert(items, { { "On" }, { where } })
	else
		table.insert(items, { { "On" }, { "organization-wide (no dashboard_uid configured)" } })
	end
	table.insert(out, ui.col({ ui.kv(items) }, { key = "facts" }))
	return out
end

local function choices(s: State): Node
	local buttons: { Node } = {}
	for i, c in State.CHOICES do
		local t = CHOICE_TEXT[c]
		local class = t.class .. (if s.sel == i then " is-sel" else "")
		table.insert(buttons, button(t.label, "choose=" .. c, "c" .. c, class, t.hint))
	end
	table.insert(buttons, button("Dismiss", "dismiss", "dismiss", "tg-an-plain", "post nothing, decide later"))
	return ui.row(buttons, { key = "choices", wrap = true })
end

local function hints(s: State): string
	if s.phase == "ask" then
		local picked = if s.sel then CHOICE_TEXT[State.CHOICES[s.sel :: number]] else nil
		return "arrows pick a choice, y confirms"
			.. (if picked then " (" .. picked.label .. ": " .. picked.hint .. ")" else "")
			.. ", esc dismisses"
	elseif s.phase == "manage" then
		return "up/down select, x forget, r reload, esc close"
	end
	return "esc closes"
end

local function manage(s: State): { Node }
	local out: { Node } = {
		ui.text({ ui.span("Deploy annotation decisions", "strong") }, { key = "head" }),
		ui.muted(
			"Contexts listed here are annotated without asking (always) or never; forget one to be asked again.",
			{ key = "about" }
		),
	}
	local rows: { Node } = {}
	for i, r in s.approvals do
		table.insert(
			rows,
			ui.row({
				ui.text({ ui.span(r.context, "strong") }),
				ui.badge(r.decision, if r.decision == "always" then "success" else "muted"),
				button("Forget", "forget=" .. i, "f", "tg-an-plain"),
			}, { key = "r" .. i, tone = if s.row == i then "accent" else nil })
		)
	end
	if #rows == 0 then
		table.insert(
			rows,
			ui.muted("No remembered decisions: every context asks on its first deploy.", { key = "none" })
		)
	end
	table.insert(out, ui.col(rows, { key = "list" }))
	return out
end

function M.view(s: State, _env: Env.Env): (any, any)
	local main: { Node } = {}
	if s.phase == "manage" then
		main = manage(s)
	elseif s.phase == "loading" then
		table.insert(main, ui.muted("Loading the deploy annotation...", { key = "loading" }))
	elseif s.draft then
		main = draftView(s, s.draft :: Draft)
		if s.phase == "ask" then
			table.insert(main, choices(s))
		end
	end
	local n = note(s)
	if n then
		table.insert(main, n)
	end
	if s.phase == "posted" or s.phase == "declined" or s.phase == "missing" then
		table.insert(main, ui.row({ button("Close", "close", "close", "tg-an-plain") }, { key = "done" }))
	end
	return {
		main = ui.col(main),
		dock = ui.col({ ui.muted(hints(s), { key = "hints" }) }),
	}, nil
end

return M
