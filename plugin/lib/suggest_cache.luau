--!strict
-- Suggestion lists (label names, label values, metric metadata) the Query and
-- Logs blocks fetch lazily, cached per context. Each context keeps at most
-- `max` lists; past that the least recently used one is dropped (it is
-- fetched again when needed). Pinned keys (metric names, metadata: the lists
-- every expression position needs) are never dropped.

local M = {}

-- A fresh list is reused this long; a failed fetch is retried after
-- ERROR_TTL_MS.
M.TTL_MS = 5 * 60 * 1000
M.ERROR_TTL_MS = 30 * 1000
M.MAX = 64

export type Entry = {
	status: "pending" | "ok" | "error",
	at_ms: number,
	values: { string }?,
	-- Query block: metric metadata by name.
	metadata: { [string]: any }?,
}

type Lists = {
	entries: { [string]: Entry },
	-- Last use (a per-context counter) of every unpinned entry.
	used: { [string]: number },
	tick: number,
	n: number,
}

export type Cache = {
	max: number,
	pinned: { [string]: boolean },
	contexts: { [string]: Lists },
}

function M.new(pinned: { [string]: boolean }?, max: number?): Cache
	return { max = max or M.MAX, pinned = pinned or {}, contexts = {} }
end

local function lists(c: Cache, context: string): Lists
	local l = c.contexts[context]
	if l == nil then
		l = { entries = {}, used = {}, tick = 0, n = 0 }
		c.contexts[context] = l
	end
	return l
end

local function touch(c: Cache, l: Lists, key: string)
	if not c.pinned[key] then
		l.tick += 1
		l.used[key] = l.tick
	end
end

-- The list `key` of `context`, marking it used.
function M.get(c: Cache, context: string, key: string): Entry?
	local l = c.contexts[context]
	local e = if l then l.entries[key] else nil
	if l and e then
		touch(c, l, key)
	end
	return e
end

-- Stores the list `key` of `context`, dropping the least recently used
-- unpinned list when the context holds more than `max`.
function M.put(c: Cache, context: string, key: string, e: Entry)
	local l = lists(c, context)
	if l.entries[key] == nil and not c.pinned[key] then
		l.n += 1
	end
	l.entries[key] = e
	touch(c, l, key)
	if l.n <= c.max then
		return
	end
	local oldest: string?, at = nil, math.huge
	for k, t in l.used do
		if k ~= key and t < at then
			oldest, at = k, t
		end
	end
	if oldest then
		l.entries[oldest] = nil
		l.used[oldest] = nil
		l.n -= 1
	end
end

-- Pending, or fetched recently enough to show without asking again.
function M.fresh(e: Entry, now_ms: number): boolean
	if e.status == "pending" then
		return true
	end
	return now_ms - e.at_ms < (if e.status == "ok" then M.TTL_MS else M.ERROR_TTL_MS)
end

return M
