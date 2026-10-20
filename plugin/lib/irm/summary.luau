--!strict
-- The IRM kv summary (`tern-grafana.irm.summary`) the host poller writes and
-- the window's status segment reads: per context, open alert-group counts by
-- state, open incidents by severity and, when `irm.names` allows, who is on
-- call now per schedule (OnCall usernames) and whether `irm.user` is on call
-- (the schedule names and when the shift ends). kv is a 0644 file, so
-- nothing else goes in: no titles, ids, emails or alert content.

local M = {}

M.KEY = "tern-grafana.irm.summary"
M.VERSION = 1
-- Bounds the payload: schedules and names per schedule kept.
M.MAX_SCHEDULES = 12
M.MAX_NAMES = 6

export type OnCallNow = { schedule: string, now: { string } }

-- `irm.user` against the schedules: `known` is false when no OnCall user has
-- that email. `until_ms` is the end of the latest shift the user is in now.
export type You = { known: boolean, now: boolean, until_ms: number?, schedules: { string } }

export type ContextSummary = {
	-- nil while unknown (never read, or OnCall unavailable).
	firing: number?,
	acknowledged: number?,
	silenced: number?,
	incidents: number?,
	-- More open incidents exist than one query returns.
	incidents_more: boolean,
	severities: { [string]: number },
	oncall: { OnCallNow }?,
	-- nil when `irm.user` is not set or the users could not be read.
	you: You?,
	-- The error kind of the last poll's first failure ("auth", "network", ...).
	error: string?,
	-- Why IRM (or OnCall) is unavailable for this context.
	unavailable: string?,
}

export type Payload = {
	v: number,
	updated_ms: number,
	poll_s: number,
	contexts: { [string]: ContextSummary },
}

local function count(v: any): number?
	return if type(v) == "number" and v >= 0 and v == math.floor(v) then v else nil
end

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

local function readContext(raw: any): ContextSummary?
	if type(raw) ~= "table" then
		return nil
	end
	local severities: { [string]: number } = {}
	if type(raw.severities) == "table" then
		for k, v in raw.severities do
			local n = count(v)
			if type(k) == "string" and n then
				severities[k] = n
			end
		end
	end
	local oncall: { OnCallNow }? = nil
	if type(raw.oncall) == "table" then
		local list: { OnCallNow } = {}
		for _, s in raw.oncall do
			if type(s) == "table" and str(s.schedule) and #list < M.MAX_SCHEDULES then
				local now: { string } = {}
				if type(s.now) == "table" then
					for _, n in s.now do
						if str(n) and #now < M.MAX_NAMES then
							table.insert(now, n)
						end
					end
				end
				table.insert(list, { schedule = s.schedule, now = now })
			end
		end
		oncall = list
	end
	local you: You? = nil
	if type(raw.you) == "table" then
		local schedules: { string } = {}
		if type(raw.you.schedules) == "table" then
			for _, n in raw.you.schedules do
				if str(n) and #schedules < M.MAX_SCHEDULES then
					table.insert(schedules, n)
				end
			end
		end
		you = {
			known = raw.you.known == true,
			now = raw.you.now == true,
			until_ms = if type(raw.you.until_ms) == "number" then raw.you.until_ms else nil,
			schedules = schedules,
		}
	end
	return {
		firing = count(raw.firing),
		acknowledged = count(raw.acknowledged),
		silenced = count(raw.silenced),
		incidents = count(raw.incidents),
		incidents_more = raw.incidents_more == true,
		severities = severities,
		oncall = oncall,
		you = you,
		error = str(raw.error),
		unavailable = str(raw.unavailable),
	}
end

-- The validated payload, or nil for anything else (no poll yet, polling
-- off, an older or foreign value).
function M.read(raw: any): Payload?
	if type(raw) ~= "table" or raw.v ~= M.VERSION or type(raw.updated_ms) ~= "number" then
		return nil
	end
	if type(raw.contexts) ~= "table" then
		return nil
	end
	local contexts: { [string]: ContextSummary } = {}
	for name, c in raw.contexts do
		local s = if type(name) == "string" then readContext(c) else nil
		if s then
			contexts[name] = s
		end
	end
	return {
		v = M.VERSION,
		updated_ms = raw.updated_ms,
		poll_s = count(raw.poll_s) or 60,
		contexts = contexts,
	}
end

return M
