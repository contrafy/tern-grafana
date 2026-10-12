--!strict
-- Window glue for `tern-grafana://investigate?id=<nonce>` (G4), called by
-- links_window before the generic link routing. Decisions live in
-- lib/investigate/handoff.luau: a draft opens the preview block; a send
-- record is deleted, then the default Tern agent starts with its prompt in
-- the origin pane's working directory (or HOME). Every agents call is
-- pcalled and failures toast; the prompt is never logged. Handoff loads on
-- the first investigate link, not with the window entry (50 ms load budget).

local Scheme = require("./lib/links/scheme")

local M = {}

-- True for links this module answers.
function M.claims(url: string): boolean
	if not Scheme.isLink(url) then
		return false
	end
	local action = string.match(string.sub(url, #Scheme.SCHEME + 4), "^([^?/]*)")
	return action ~= nil and string.lower(action) == "investigate"
end

local function nowMs(): number
	return os.time() * 1000
end

-- The origin pane's working directory, else HOME.
local function cwdFor(t: any, cx: any, pane: number?): string?
	if pane then
		local ok, info = pcall(function()
			return cx.session:pane(pane)
		end)
		if ok and type(info) == "table" and type(info.cwd) == "string" and info.cwd ~= "" then
			return info.cwd
		end
	end
	local okHome, home = pcall(t.getenv, "HOME")
	return if okHome and type(home) == "string" and home ~= "" then home else nil
end

function M.handle(link: any, cx: any, t: any): any
	local Handoff = require("./lib/investigate/handoff")
	local l, err = Scheme.decode(link.url)
	if l == nil then
		cx:toast("error", "Invalid investigation link", if err then err.message else nil)
		return { handled = true }
	end
	local nonce = l.params.id
	local key = Handoff.key(nonce)
	local okGet, raw = pcall(t.kv.get, key)
	if not okGet then
		cx:toast("error", "Tern Grafana could not read the investigation", tostring(raw))
		return { handled = true }
	end
	local decision: any = Handoff.decide(nonce, raw, nowMs())
	if decision.kind == "preview" then
		return { block = Handoff.BLOCK, args = { decision.link } }
	end
	-- Used once: delete before acting, so a second click finds nothing.
	if decision.kind == "send" or decision.delete then
		pcall(t.kv.set, key, nil)
	end
	if decision.kind == "refused" then
		cx:toast("info", decision.message)
		return { handled = true }
	end
	local cwd = cwdFor(t, cx, link.pane)
	if cwd == nil then
		cx:toast("error", "Could not start the agent", "No working directory: neither the pane nor HOME has one")
		return { handled = true }
	end
	local ok, pane = pcall(function()
		return cx.agents:start({ prompt = decision.prompt, cwd = cwd })
	end)
	if ok then
		cx:toast("info", "Investigation sent to a new agent", decision.title)
		pcall(t.log.info, "tern-grafana investigate: agent started", "pane=" .. tostring(pane))
	else
		cx:toast("error", "Could not start the agent", tostring(pane))
	end
	return { handled = true }
end

return M
