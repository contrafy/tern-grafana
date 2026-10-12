--!strict
-- How an investigation travels between the halves (G4). The source block and
-- the preview run in the host half, on the machine whose panes they serve
-- (possibly a remote Tern host); the agent is started by the window half, on
-- the machine showing the window. kv is per machine, so nothing goes through
-- it: everything travels in the `tern-grafana://investigate` link.
--
--   1. The source block (alerts detail, query, dashboard panel) opens
--      `investigate?subject=<payload>`: the Subject as base64url JSON, its
--      recent values trimmed first when it would not fit. The window answers
--      with the preview block, whose args are that link and a ticket the
--      window just minted.
--   2. Send in the preview opens
--      `investigate?prompt=<payload>&title=<title>&ticket=<ticket>`. The window
--      starts the agent only for a ticket it minted itself (in memory, for
--      TICKET_TTL_MS). Any other prompt link (one printed in a terminal, or
--      sent by a preview restored after Tern restarted) opens a preview of
--      that exact prompt with a fresh ticket instead.
--
-- So no link on its own ever starts an agent: the user always reads the
-- prompt in a preview and presses Send. Links carry no credentials: subjects
-- hold names, labels, queries, series statistics and http(s) links without
-- userinfo or credential-named query parameters (lib/investigate/subject),
-- and the scheme refuses credential-named parameters.

local Base64 = require("../auth/base64")
local Compact = require("../carly/compact")
local Effect = require("../effect")
local Env = require("../env")
local Scheme = require("../links/scheme")
local Subject = require("./subject")
local Tbl = require("../tbl")

type Effect = Effect.Effect
type Env = Env.Env
type Link = Scheme.Link
type Subject = Subject.Subject

-- Ticket -> window epoch ms when it was minted. Held by the window glue.
export type Tickets = { [string]: number }

export type Decision =
	{ kind: "preview", args: { string } }
	| { kind: "send", prompt: string, title: string }
	| { kind: "refused", message: string }

-- What a preview link holds: a subject, or a prompt alone (a prompt link
-- that the window did not accept as a send), or why neither.
export type Opened = { subject: Subject?, prompt: string?, title: string?, err: string? }

local M = {}

M.BLOCK = "tern-grafana.investigate"
M.MAX_PAYLOAD = Scheme.MAX_PAYLOAD
M.MAX_PROMPT = 16000
M.MAX_TITLE = 200
-- A preview left open this long re-previews on Send instead of sending.
M.TICKET_TTL_MS = 12 * 60 * 60 * 1000
M.MAX_TICKETS = 64
-- Long text is clipped to this when trimming values alone does not fit.
M.CLIP_TEXT = 400

-- base64url (RFC 4648 section 5) without padding: unreserved in a URL, so the
-- link stays ~4/3 of the JSON instead of percent-encoding every quote.
local TO_URL: { [string]: string } = { ["+"] = "-", ["/"] = "_", ["="] = "" }

function M.encodePayload(bytes: string): string
	return (string.gsub(Base64.encode(bytes), "[+/=]", TO_URL))
end

local URL_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local FROM_URL: { [number]: number } = {}
for i = 1, 64 do
	FROM_URL[string.byte(URL_ALPHABET, i)] = i - 1
end

-- The bytes of a base64url payload; nil when it is not one.
function M.decodePayload(s: string): string?
	local n = #s
	if n == 0 or n % 4 == 1 or string.find(s, "[^%w%-_]") then
		return nil
	end
	local out: { string } = table.create(n // 4 + 1)
	for i = 1, n, 4 do
		local a, b, c, d = string.byte(s, i, i + 3)
		local word = bit32.lshift(FROM_URL[a], 18)
			+ bit32.lshift(FROM_URL[b :: number], 12)
			+ bit32.lshift(if c then FROM_URL[c] else 0, 6)
			+ (if d then FROM_URL[d] else 0)
		if d then
			table.insert(
				out,
				string.char(bit32.extract(word, 16, 8), bit32.extract(word, 8, 8), bit32.extract(word, 0, 8))
			)
		elseif c then
			table.insert(out, string.char(bit32.extract(word, 16, 8), bit32.extract(word, 8, 8)))
		else
			table.insert(out, string.char(bit32.extract(word, 16, 8)))
		end
	end
	return table.concat(out)
end

-- FNV-1a 32-bit; the prime 16777619 = 2^24 + 403 keeps products exact.
local function fnv32(s: string): number
	local h = 2166136261
	for i = 1, #s do
		h = bit32.bxor(h, string.byte(s, i))
		h = (h * 403 + bit32.lshift(h, 24)) % 4294967296
	end
	return h
end

-- A fresh ticket: the time and a hash of `seed` mixed with `rand`, lower-case hex.
function M.nonce(now_ms: number, seed: string, rand: number): string
	return string.format("%x-%08x", math.floor(math.max(0, now_ms)), bit32.bxor(fnv32(seed), rand))
end

-- A one-line title the scheme accepts.
local function cleanTitle(title: string): string
	local one = string.gsub(title, "[%z\1-\31\127]", " ")
	one = Compact.clip(one, M.MAX_TITLE)
	return if one == "" then "Investigation" else one
end

local function linkOf(params: { [string]: string }): string
	return Scheme.encode({ action = "investigate", params = params, vars = {} })
end

local function payloadOf(subject: Subject, encode: (any) -> string): string
	return M.encodePayload(encode(subject))
end

local function asArray<T>(list: T, array: (<U>(U) -> U)?): T
	return if array then array(list) else list
end

local function clipMap(src: { [string]: string }): { [string]: string }
	local out: { [string]: string } = {}
	for k, v in src do
		out[k] = Compact.clip(v, M.CLIP_TEXT)
	end
	return out
end

-- `subject` with its long free text clipped (each clip ends in "...").
local function clipText(subject: Subject, array: (<U>(U) -> U)?): Subject
	local s = Tbl.copy(subject)
	local queries: { Subject.Query } = {}
	for _, q in subject.queries do
		local c = Tbl.copy(q)
		c.expr = Compact.clip(q.expr, M.CLIP_TEXT)
		table.insert(queries, c)
	end
	s.queries = asArray(queries, array)
	local a = subject.alert
	if a then
		local c = Tbl.copy(a)
		c.summary = Compact.clip(a.summary, M.CLIP_TEXT)
		c.description = if a.description then Compact.clip(a.description :: string, M.CLIP_TEXT) else nil
		c.value = if a.value then Compact.clip(a.value :: string, M.CLIP_TEXT) else nil
		c.labels = clipMap(a.labels)
		c.annotations = clipMap(a.annotations)
		s.alert = c
	end
	return s
end

-- The subject's link payload, at most MAX_PAYLOAD long: when the whole
-- subject is too large, recent-value series are dropped from the end (the
-- smallest last values) and marked `trimmed`, so the prompt says so; then
-- long text is clipped. Nil when even that does not fit.
function M.fit(subject: Subject, encode: (any) -> string, array: (<U>(U) -> U)?): string?
	local payload = payloadOf(subject, encode)
	if #payload <= M.MAX_PAYLOAD then
		return payload
	end
	local s = Tbl.copy(subject)
	local v = subject.values
	if v then
		local series = table.move(v.series, 1, #v.series, 1, {})
		local trimmed: Subject.Values = Tbl.copy(v)
		trimmed.series = asArray(series, array)
		trimmed.trimmed = true
		s.values = trimmed
		while #series > 0 do
			table.remove(series)
			trimmed.omitted += 1
			payload = payloadOf(s, encode)
			if #payload <= M.MAX_PAYLOAD then
				return payload
			end
		end
	end
	payload = payloadOf(clipText(s, array), encode)
	return if #payload <= M.MAX_PAYLOAD then payload else nil
end

-- The effects that start an investigation from a source block: open the
-- preview through the window, the subject in the link.
function M.start(subject: Subject, env: Env): { Effect }
	local payload = M.fit(subject, env.encode, env.array)
	if payload == nil then
		return {
			{
				kind = "toast",
				level = "error",
				text = "This investigation is too large to hand over",
				sub = "Copy the query instead",
			},
		}
	end
	return { { kind = "open", target = linkOf({ subject = payload }) } }
end

-- A prompt link; with `ticket` it asks the window to send, without it it
-- only opens a preview.
function M.promptLink(prompt: string, title: string, ticket: string?): string
	local params: { [string]: string } = { prompt = M.encodePayload(prompt), title = cleanTitle(title) }
	if ticket then
		params.ticket = ticket
	end
	return linkOf(params)
end

-- The effects of "Send": open the prompt link the window acts on.
function M.send(prompt: string, title: string, ticket: string?): { Effect }
	return { { kind = "open", target = M.promptLink(prompt, title, ticket) } }
end

-- Mints a ticket for one preview, dropping expired ones and the oldest when
-- `tickets` is full.
function M.mint(tickets: Tickets, now_ms: number, seed: string, rand: number): string
	local count, oldest, oldestAt = 0, nil, math.huge
	for t, at in tickets do
		if now_ms - at > M.TICKET_TTL_MS or at - now_ms > M.TICKET_TTL_MS then
			tickets[t] = nil
		else
			count += 1
			if at < oldestAt then
				oldest, oldestAt = t, at
			end
		end
	end
	if count >= M.MAX_TICKETS and oldest then
		tickets[oldest] = nil
	end
	local t = M.nonce(now_ms, seed, rand)
	while tickets[t] ~= nil do
		rand = (rand + 1) % 0x80000000
		t = M.nonce(now_ms, seed, rand)
	end
	tickets[t] = now_ms
	return t
end

local function validTicket(tickets: Tickets, ticket: string?, now_ms: number): boolean
	local at = if ticket then tickets[ticket] else nil
	if at == nil then
		return false
	end
	local age = now_ms - at
	-- A ticket from the future (clock jump) is as suspicious as an old one.
	return age <= M.TICKET_TTL_MS and age >= -M.TICKET_TTL_MS
end

local function readPrompt(raw: string?): string?
	local prompt = if raw then M.decodePayload(raw) else nil
	if prompt == nil or prompt == "" or #prompt > M.MAX_PROMPT then
		return nil
	end
	return prompt
end

local UNREADABLE = "This investigation link is not readable."

-- What the window does with an investigate link. `tickets` is the window's
-- memory; `rand` seeds a new ticket.
function M.decide(link: Link, tickets: Tickets, now_ms: number, rand: number): Decision
	local p = link.params
	if p.subject and p.prompt == nil and p.ticket == nil then
		local url = linkOf({ subject = p.subject })
		return { kind = "preview", args = { url, M.mint(tickets, now_ms, string.sub(p.subject, -64), rand) } }
	end
	if p.prompt and p.subject == nil then
		local prompt = readPrompt(p.prompt)
		if prompt == nil then
			return { kind = "refused", message = UNREADABLE }
		end
		local title = p.title or "Investigation"
		if validTicket(tickets, p.ticket, now_ms) then
			return { kind = "send", prompt = prompt, title = title }
		end
		-- Not minted by this window, or too old: show the prompt first.
		local url = M.promptLink(prompt, title)
		return { kind = "preview", args = { url, M.mint(tickets, now_ms, string.sub(p.prompt, -64), rand) } }
	end
	return { kind = "refused", message = UNREADABLE }
end

-- What the preview block's link (`args[1]`) holds.
function M.open(url: string?, decode: (string) -> any): Opened
	local l = if type(url) == "string" then Scheme.decode(url) else nil
	if l == nil or l.action ~= "investigate" then
		return { err = "This block was opened without an investigation." }
	end
	local p = l.params
	if p.subject then
		local json = M.decodePayload(p.subject)
		local ok, raw = pcall(decode, json or "")
		local subject = if json and ok then Subject.read(raw) else nil
		if subject == nil then
			return { err = UNREADABLE }
		end
		return { subject = subject }
	end
	local prompt = readPrompt(p.prompt)
	if prompt == nil then
		return { err = UNREADABLE }
	end
	return { prompt = prompt, title = p.title or "Investigation" }
end

return M
