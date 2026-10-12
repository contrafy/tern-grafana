--!strict
-- Shared time range and cursor across blocks (B4). One kv record,
-- `tern-grafana.time.shared`, holds the range and cursor the last synced
-- block published: `{from, to, cursor_ms?, origin, seq}`. Ranges stay
-- Grafana time strings ("now-1h", or epoch-ms digits once absolute); no
-- secrets. kv is a 0644 file every window reads, and Tern has no kv change
-- callback, so synced blocks poll it on a timer.
--
-- Every block that takes part keeps a Sync: whether it is on (key `S`,
-- persisted in save()), its origin (a per-block id) and the newest seq it has
-- published or adopted. A record is adopted only when another origin wrote it
-- and its seq is newer than anything this block has seen: a block never
-- re-applies its own echo, and an older record left behind by a slow writer
-- never rolls a newer range back.

local Env = require("../env")

type Env = Env.Env

export type Range = { from: string, to: string }

export type Value = {
	from: string,
	to: string,
	-- Cursor time (epoch ms) in graph views; nil when no cursor is on.
	cursor_ms: number?,
	-- The publishing block's Sync.origin.
	origin: string,
	seq: number,
}

export type Sync = {
	on: boolean,
	origin: string,
	-- Newest seq published or adopted by this block.
	seq: number,
	-- Bumped on every toggle: a poll tick of an older generation is stale.
	gen: number,
}

local M = {}

M.KEY = "tern-grafana.time.shared"
-- How often a synced block reads the record.
M.POLL_MS = 2000
-- Timer tag prefix; the tag is TAG .. sync.gen.
M.TAG = "sync:"

local function validTime(v: any): boolean
	return type(v) == "string" and v ~= "" and #v <= 64
end

-- The record when `raw` is a well-formed one, else nil.
function M.read(raw: any): Value?
	if type(raw) ~= "table" then
		return nil
	end
	if not validTime(raw.from) or not validTime(raw.to) then
		return nil
	end
	if type(raw.origin) ~= "string" or type(raw.seq) ~= "number" or raw.seq ~= raw.seq then
		return nil
	end
	local cursor = raw.cursor_ms
	return {
		from = raw.from,
		to = raw.to,
		cursor_ms = if type(cursor) == "number" and cursor == cursor then cursor else nil,
		origin = raw.origin,
		seq = raw.seq,
	}
end

-- An id for one block: its kind plus the clock and a random salt, so two
-- blocks opened in the same millisecond still differ.
function M.origin(kind: string, now_ms: number): string
	return string.format("%s-%d-%d", kind, math.floor(now_ms), math.random(1, 2 ^ 30))
end

function M.new(kind: string, now_ms: number, on: boolean?): Sync
	return { on = on == true, origin = M.origin(kind, now_ms), seq = 0, gen = 0 }
end

-- The record to store after `origin` changed its range or cursor; `prev` is
-- the current stored record (any shape). The seq goes past the stored one so
-- every reader sees it as newer.
function M.publish(range: Range, cursor: number?, origin: string, prev: any): Value
	local p = M.read(prev)
	return {
		from = range.from,
		to = range.to,
		cursor_ms = cursor,
		origin = origin,
		seq = (if p then p.seq else 0) + 1,
	}
end

-- What `mine` should apply from the stored record `value`: the range and the
-- cursor (nil cursor: none), or nothing for its own echo, a record already
-- seen or an older one. Remembers the seq of anything it reads. The caller
-- compares the range with its own before re-querying (a cursor-only move
-- republishes the same range).
function M.adopt(value: any, mine: Sync): (Range?, number?)
	local v = M.read(value)
	if v == nil or v.seq <= mine.seq then
		return nil, nil
	end
	mine.seq = v.seq
	if v.origin == mine.origin then
		return nil, nil
	end
	return { from = v.from, to = v.to }, v.cursor_ms
end

-- The kv write publishing `range` and `cursor` for a synced block (nil when
-- sync is off).
function M.share(mine: Sync, range: Range, cursor: number?, env: Env): { kind: "kv_set", key: string, value: any }?
	if not mine.on then
		return nil
	end
	local prev = if env.kv_get then env.kv_get(M.KEY) else nil
	local v = M.publish(range, cursor, mine.origin, prev)
	mine.seq = v.seq
	return { kind = "kv_set", key = M.KEY, value = v }
end

-- Reads and adopts the stored record (see adopt).
function M.poll(mine: Sync, env: Env): (Range?, number?)
	if not mine.on or env.kv_get == nil then
		return nil, nil
	end
	return M.adopt((env.kv_get :: (string) -> any)(M.KEY), mine)
end

-- The poll timer for the current generation.
function M.timer(mine: Sync): { kind: "timer", tag: string, ms: number }
	return { kind = "timer", tag = M.TAG .. tostring(mine.gen), ms = M.POLL_MS }
end

-- True when `tag` is this block's live poll tick.
function M.isTick(mine: Sync, tag: string): boolean
	return mine.on and tag == M.TAG .. tostring(mine.gen)
end

-- Turns sync on or off; returns the poll timer to arm when on. Call join
-- right after turning it on.
function M.toggle(mine: Sync): { kind: "timer", tag: string, ms: number }?
	mine.on = not mine.on
	mine.gen += 1
	return if mine.on then M.timer(mine) else nil
end

-- Right after sync turns on: the record another block shares wins (joining
-- never yanks the others to this block's range); with none, or only this
-- block's own, this block's range is published for the others to adopt.
function M.join(
	mine: Sync,
	range: Range,
	cursor: number?,
	env: Env
): (Range?, number?, { kind: "kv_set", key: string, value: any }?)
	local v = M.read(if env.kv_get then env.kv_get(M.KEY) else nil)
	if v and v.origin ~= mine.origin then
		mine.seq = math.max(mine.seq, v.seq)
		return { from = v.from, to = v.to }, v.cursor_ms, nil
	end
	return nil, nil, M.share(mine, range, cursor, env)
end

return M
