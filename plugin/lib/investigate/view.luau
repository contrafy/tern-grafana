--!strict
-- The Investigate preview: what is being investigated, the exact prompt,
-- and the buttons that send, copy or close. Buttons reuse the alerts sheet's
-- `tg-al-btn` class.

local Env = require("../env")
local State = require("./state")
local ui = require("../ui")

type Node = ui.Node
type State = State.State

local M = {}

local KIND_LABEL: { [string]: string } = { alert = "alert", query = "query", panel = "dashboard panel" }

local function button(key: string, text: string, act: string, primary: boolean?): Node
	return ui.el("button", {
		key = key,
		class = if primary then "tg-al-btn tg-sil-confirm" else "tg-al-btn",
		text = text,
		actions = { click = act },
	})
end

-- The prompt as wrapped text lines (a code node would not wrap, and the
-- user must be able to read all of it before sending).
function M.prompt(text: string): Node
	local lines: { Node } = {}
	local i = 0
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		i += 1
		table.insert(lines, ui.text({ ui.span(if line == "" then " " else line, "mono") }, { key = "l" .. i }))
	end
	return ui.col(lines, { key = "prompt", gap = "none" })
end

function M.view(s: State, env: Env.Env): any
	local subject = s.subject
	if subject == nil and s.prompt == "" then
		return {
			main = ui.col({
				ui.text({ ui.span("Investigate", "accent") }, { key = "head" }),
				ui.text({ ui.span(s.note or "Nothing to investigate.", "warning") }, { key = "note" }),
				ui.muted("Start again from an alert (i), a query or a dashboard panel (I).", { key = "hint" }),
				ui.row({ button("bclose", "Close (q)", "close") }, { key = "buttons" }),
			}, { role = "tern-grafana.investigate" }),
		}
	end
	local head: { ui.SpanLike } = { ui.span("Investigate ", "accent") }
	if subject then
		table.insert(head, ui.span(KIND_LABEL[subject.kind] or subject.kind, "muted"))
		table.insert(head, " " .. subject.title)
		if subject.context then
			table.insert(head, ui.span("  " .. (subject.context :: string), "muted"))
		end
	else
		table.insert(head, s.title or "prompt")
	end
	local fetches = subject ~= nil and subject.fetch == true
	local children: { Node } = { ui.text(head, { key = "head" }) }
	if s.status == "loading" then
		table.insert(children, ui.muted("Fetching recent values...", { key = "status" }))
	elseif s.sent_ms then
		table.insert(
			children,
			ui.text({
				ui.span(
					string.format(
						"Sent to a new agent %ds ago. Close this preview with q.",
						math.max(0, math.floor((env.now_ms - (s.sent_ms :: number)) / 1000))
					),
					"accent"
				),
			}, { key = "status" })
		)
	else
		table.insert(
			children,
			ui.muted("Nothing is sent until you press Send. The agent starts in a new pane.", { key = "status" })
		)
	end
	if s.note then
		table.insert(children, ui.text({ ui.span(s.note :: string, "warning") }, { key = "note" }))
	end
	table.insert(children, M.prompt(s.prompt))
	local buttons: { Node } = {
		button("bsend", if s.sent_ms then "Send again" else "Send to agent (enter)", "send", true),
		button("bcopy", "Copy prompt (y)", "copy"),
	}
	if fetches then
		table.insert(buttons, button("brefresh", "Refresh values (r)", "refresh"))
	end
	table.insert(buttons, button("bclose", "Close (q)", "close"))
	table.insert(children, ui.row(buttons, { key = "buttons", wrap = true }))
	local hints = "enter send  y copy  q close"
	if fetches then
		hints = "enter send  y copy  r refresh values  q close"
	end
	return {
		main = ui.col(children, { role = "tern-grafana.investigate" }),
		dock = ui.col({ ui.text({ ui.span(hints, "muted") }, { key = "keys" }) }, { key = "dock" }),
	}
end

return M
