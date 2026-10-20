--!strict
-- Pieces the on-call and incidents blocks share: their view helpers, the
-- service-account attribution notice every confirmation shows, and the
-- discovery/permission/identity requests both send on open.

local Duration = require("../silences/duration")
local Env = require("../env")
local Range = require("../time/range")
local ui = require("../ui")

type Env = Env.Env
type Node = ui.Node
type SpanLike = ui.SpanLike

local M = {}

-- Writes go out with the context's service-account token: IRM records the
-- action under that account, not under the person at the keyboard.
function M.notice(login: string?): string
	local who = if login then "service account " .. login else "the context's service account"
	return string.format("Sent as %s: IRM records this action under the service account, not under you.", who)
end

function M.age(ms: number): string
	return Duration.format(math.abs(ms) / 1000)
end

-- "13:00" on the day of `now_ms`, else "Tue 20 Oct 13:00", at `offset_min`
-- minutes east of UTC.
function M.clockAt(ms: number, now_ms: number, offset_min: number): string
	local text = Range.formatMs(ms, offset_min)
	local today = string.sub(Range.formatMs(now_ms, offset_min), 1, 10)
	if string.sub(text, 1, 10) == today then
		return string.sub(text, 12, 16)
	end
	return os.date("!%a %d %b ", math.floor(ms / 1000) + offset_min * 60) .. string.sub(text, 12, 16)
end

-- `clockAt` in the viewer's zone.
function M.clock(ms: number, env: Env): string
	return M.clockAt(ms, env.now_ms, env.local_offset_min or 0)
end

function M.button(text: string, act: string, key: string, class: string?): Node
	return ui.el("button", {
		key = key,
		class = "tg-al-btn" .. (if class then " " .. class else ""),
		text = text,
		actions = { click = act },
	})
end

-- Context chips (click switches), as the other blocks show them.
function M.contextChips(contexts: { string }, current: string?): { Node }
	local out: { Node } = {}
	for i, name in contexts do
		table.insert(
			out,
			ui.badge(
				name,
				if name == current then "info" else "neutral",
				{ key = "c" .. i, actions = { click = "ctx=" .. name }, class = "tg-al-chip" }
			)
		)
	end
	return out
end

function M.when(loading: boolean, loaded_ms: number?, env: Env): { SpanLike }
	if loading then
		return { ui.span("loading", "accent") }
	elseif loaded_ms then
		return { ui.span("updated " .. M.age(env.now_ms - (loaded_ms :: number)) .. " ago", "muted") }
	end
	return {}
end

-- A Grafana-relative path ("/a/grafana-irm-app/...") as an absolute URL.
function M.absolute(url: string?, grafana_url: string?): string?
	if url == nil or url == "" then
		return nil
	end
	if string.match(url :: string, "^https?://") then
		return url
	end
	if grafana_url and string.sub(url :: string, 1, 1) == "/" then
		return (string.gsub(grafana_url :: string, "/+$", "")) .. url
	end
	return nil
end

-- Edits a one-line text field from a key; true when the key was used.
function M.editKey(text: string, key: any): (string, boolean)
	local name = key.name
	if name == "backspace" then
		return string.sub(text, 1, (utf8.offset(text, -1) or (#text + 1)) - 1), true
	elseif name == "paste" and type(key.text) == "string" then
		return text .. string.gsub(key.text, "%c", " "), true
	elseif key.ctrl and name == "u" then
		return "", true
	elseif key.text and key.text ~= "" and not key.ctrl and not key.meta then
		return text .. key.text, true
	end
	return text, false
end

return M
