--!strict
-- Scrape targets from /api/v1/targets: normalized active targets, dropped
-- totals, filtering (free words plus label matchers, the alerts inbox syntax)
-- and grouping by scrape pool (the job), unhealthy pools first.

local Env = require("../env")
local Group = require("../alerts/group")
local Range = require("../time/range")

type Env = Env.Env
type Filter = Group.Filter

export type Health = "up" | "down" | "unknown"

export type Target = {
	-- Stable within one answer: pool and scrape URL.
	key: string,
	pool: string,
	instance: string,
	url: string,
	health: Health,
	labels: { [string]: string },
	last_scrape_ms: number?,
	duration_s: number?,
	interval: string?,
	timeout: string?,
	last_error: string?,
}

export type Dropped = { pool: string, address: string, labels: { [string]: string } }

export type Targets = {
	active: { Target },
	-- Totals per pool: `droppedTargetCounts` where the server has it, else
	-- counted from the list.
	dropped_count: number,
	dropped_by_pool: { [string]: number },
	-- The first MAX_DROPPED dropped targets (service discovery can drop
	-- thousands).
	dropped: { Dropped },
}

export type Pool = {
	name: string,
	targets: { Target },
	up: number,
	down: number,
	unknown: number,
	dropped: number,
}

local M = {}

M.MAX_DROPPED = 200

local function str(env: Env, v: any): string?
	v = Env.value(env, v)
	return if type(v) == "string" then v else nil
end

local function labelMap(env: Env, v: any): { [string]: string }
	local out: { [string]: string } = {}
	v = Env.value(env, v)
	if type(v) == "table" then
		for k, val in v do
			if type(k) == "string" and type(val) == "string" then
				out[k] = val
			end
		end
	end
	return out
end

local function parseHealth(v: string?): Health
	if v == "up" or v == "down" then
		return v
	end
	return "unknown"
end

-- Prometheus reports a never-scraped target as 0001-01-01T00:00:00Z.
local function time(env: Env, v: any): number?
	local s = str(env, v)
	if s == nil or s == "" or string.sub(s, 1, 4) == "0001" then
		return nil
	end
	return (Range.parse(s, false, { now_ms = env.now_ms }))
end

local function target(env: Env, raw: any): Target?
	if type(raw) ~= "table" then
		return nil
	end
	local labels = labelMap(env, raw.labels)
	local discovered = labelMap(env, raw.discoveredLabels)
	local pool = str(env, raw.scrapePool) or labels.job or discovered.job or ""
	local url = str(env, raw.scrapeUrl) or ""
	local err = str(env, raw.lastError)
	local duration = Env.value(env, raw.lastScrapeDuration)
	local t: Target = {
		key = pool .. " " .. url,
		pool = pool,
		instance = labels.instance or discovered.__address__ or url,
		url = url,
		health = parseHealth(str(env, raw.health)),
		labels = labels,
		last_scrape_ms = time(env, raw.lastScrape),
		duration_s = if type(duration) == "number" then duration else nil,
		interval = str(env, raw.scrapeInterval),
		timeout = str(env, raw.scrapeTimeout),
		last_error = if err and err ~= "" then err else nil,
	}
	return t
end

function M.normalize(data: any, env: Env): Targets
	local out: Targets = { active = {}, dropped_count = 0, dropped_by_pool = {}, dropped = {} }
	local active = if type(data) == "table" then Env.value(env, data.activeTargets) else nil
	if type(active) == "table" then
		for _, raw in active do
			local t = target(env, raw)
			if t then
				table.insert(out.active, t)
			end
		end
	end
	local dropped = if type(data) == "table" then Env.value(env, data.droppedTargets) else nil
	local listed = 0
	local listedByPool: { [string]: number } = {}
	if type(dropped) == "table" then
		for _, raw in dropped do
			if type(raw) ~= "table" then
				continue
			end
			local labels = labelMap(env, raw.discoveredLabels)
			local pool = str(env, raw.scrapePool) or labels.job or ""
			listed += 1
			listedByPool[pool] = (listedByPool[pool] or 0) + 1
			if #out.dropped < M.MAX_DROPPED then
				table.insert(out.dropped, { pool = pool, address = labels.__address__ or "", labels = labels })
			end
		end
	end
	local counts = if type(data) == "table" then Env.value(env, data.droppedTargetCounts) else nil
	if type(counts) == "table" then
		for pool, n in counts do
			if type(pool) == "string" and type(n) == "number" then
				out.dropped_by_pool[pool] = n
				out.dropped_count += n
			end
		end
	else
		out.dropped_by_pool = listedByPool
		out.dropped_count = listed
	end
	return out
end

-- Free words match pool, instance, URL, error, health and any label name or
-- value; matchers test the target labels (plus `job` = pool when unlabeled
-- and `health`).
function M.accept(filter: Filter, t: Target): boolean
	if #filter.matchers > 0 then
		local labels = table.clone(t.labels)
		labels.health = t.health
		if labels.job == nil then
			labels.job = t.pool
		end
		for _, m in filter.matchers do
			if not Group.matches(m, labels) then
				return false
			end
		end
	end
	for _, w in filter.words do
		local function has(s: string?): boolean
			return s ~= nil and string.find(string.lower(s), w, 1, true) ~= nil
		end
		local found = has(t.pool) or has(t.instance) or has(t.url) or has(t.last_error) or has(t.health)
		if not found then
			for name, value in t.labels do
				if has(name) or has(value) then
					found = true
					break
				end
			end
		end
		if not found then
			return false
		end
	end
	return true
end

local HEALTH_RANK: { [Health]: number } = { down = 0, unknown = 1, up = 2 }

-- Pools of the targets that pass `filter` (and are unhealthy when
-- `unhealthy_only`): pools with down targets first, then by name; targets
-- down first, then by instance.
function M.pools(targets: Targets, filter: Filter, unhealthy_only: boolean): { Pool }
	local byName: { [string]: Pool } = {}
	local list: { Pool } = {}
	for _, t in targets.active do
		if unhealthy_only and t.health == "up" then
			continue
		end
		if not M.accept(filter, t) then
			continue
		end
		local p = byName[t.pool]
		if p == nil then
			local created: Pool = {
				name = t.pool,
				targets = {},
				up = 0,
				down = 0,
				unknown = 0,
				dropped = targets.dropped_by_pool[t.pool] or 0,
			}
			p = created
			byName[t.pool] = created
			table.insert(list, created)
		end
		local pool = p :: Pool
		table.insert(pool.targets, t)
		local health: string = t.health
		if health == "up" then
			pool.up += 1
		elseif health == "down" then
			pool.down += 1
		else
			pool.unknown += 1
		end
	end
	for _, p in list do
		table.sort(p.targets, function(a: Target, b: Target): boolean
			if a.health ~= b.health then
				return HEALTH_RANK[a.health] < HEALTH_RANK[b.health]
			end
			return a.instance < b.instance
		end)
	end
	table.sort(list, function(a: Pool, b: Pool): boolean
		local ad, bd = a.down > 0, b.down > 0
		if ad ~= bd then
			return ad
		end
		return a.name < b.name
	end)
	return list
end

export type Counts = { up: number, down: number, unknown: number }

-- Health counts over every active target.
function M.counts(targets: Targets): Counts
	local out: Counts = { up = 0, down = 0, unknown = 0 }
	for _, t in targets.active do
		local health: string = t.health
		if health == "up" then
			out.up += 1
		elseif health == "down" then
			out.down += 1
		else
			out.unknown += 1
		end
	end
	return out
end

return M
