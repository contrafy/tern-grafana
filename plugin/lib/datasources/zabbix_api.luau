--!strict
-- The Zabbix API as Grafana's Zabbix plugin (alexanderzobnin-zabbix-datasource
-- 6.10.2) calls it from the browser: every call is a POST of `{method,
-- params}` to the datasource's `resources/zabbix-api` route, answered
-- `{result}` (the plugin's error body `{error, message}` otherwise). Ported
-- from src/datasource/zabbix/connectors/zabbix_api/zabbixAPIConnector.ts
-- (request params by Zabbix version), zabbix/zabbix.ts (findByFilter and the
-- group -> host -> problem -> trigger chains), responseHandler.ts
-- handleTriggersResponse, problemsHandler.ts and datasource.ts
-- queryTriggersData / queryTriggersPCData / queryProblems.
--
-- Chains run against `Calls`: a call whose answer is known returns it, an
-- unknown one is recorded and unwinds the chain (`M.run` reports it pending),
-- so the caller asks for the recorded calls and replays the chain with their
-- answers. The plugin's request cache (one hostgroup.get for the many lookups
-- of a chain) is the same memo: equal calls are asked once per job.
--
-- Not reproduced (lib/datasources/zabbix.luau names them as ladder reasons):
-- counting triggers by items, problems with item values at problem time
-- (fetchHistoricalItemValue). The browser plugin's `/regex/g` filters keep a
-- lastIndex between list items; here every test starts at the beginning.

local Env = require("../env")
local Frame = require("../frame/types")
local Regex = require("../regex")
local Str = require("../str")
local Tbl = require("../tbl")
local Url = require("../url")

type Env = Env.Env

local M = {}

M.DEFAULT_VERSION = "3.0.0"

-- c.DEFAULT_ZABBIX_PROBLEMS_LIMIT is the editor's default; queries carry it.
local TRIGGER_SEVERITY = { "Not classified", "Information", "Warning", "Average", "High", "Disaster" }
M.TRIGGER_SEVERITY = TRIGGER_SEVERITY

function M.path(uid: string): string
	return "/api/datasources/uid/" .. Url.percentEncode(uid) .. "/resources/zabbix-api"
end

-- Versions ---------------------------------------------------------------------

local function parts(v: string): { number }
	local out: { number } = {}
	for n in string.gmatch(v, "%d+") do
		table.insert(out, tonumber(n) :: number)
		if #out == 3 then
			break
		end
	end
	return out
end

-- semver.gte for the plain x.y.z versions apiinfo.version reports.
function M.gte(version: string, want: string): boolean
	local a, b = parts(version), parts(want)
	for i = 1, 3 do
		local x, y = a[i] or 0, b[i] or 0
		if x ~= y then
			return x > y
		end
	end
	return true
end

-- getParamsKeyByVersion.
local function selectHostGroupsKey(version: string): string
	return if M.gte(version, "7.0.0") then "selectHostGroups" else "selectGroups"
end

local function selectAcknowledgesKey(version: string): string
	return if M.gte(version, "7.0.0") then "selectAcknowledges" else "select_acknowledges"
end

local function withHostsKey(version: string): string
	return if M.gte(version, "6.2.0") then "with_hosts" else "real_hosts"
end

local function supportsApplications(version: string): boolean
	return not M.gte(version, "5.4.0")
end

-- Calls ------------------------------------------------------------------------

export type Answer = { value: any, error: string? }
export type Call = { key: string, method: string, params: { [string]: any } }

export type Calls = {
	version: string,
	-- Answers by call key.
	answers: { [string]: Answer },
	-- Calls a chain needed without an answer, in the order asked.
	wanted: { Call },
	asked: { [string]: boolean },
	env: Env,
}

local PENDING = table.freeze({ pending = true })

function M.calls(version: string, answers: { [string]: Answer }, env: Env): Calls
	return { version = version, answers = answers, wanted = {}, asked = {}, env = env }
end

-- A stable text for a params table (keys sorted), the memo key of a call.
local function canonical(v: any): string
	local t = type(v)
	if t == "table" then
		local n = #v
		if n > 0 or next(v) == nil then
			local items = table.create(n)
			for i = 1, n do
				items[i] = canonical(v[i])
			end
			return "[" .. table.concat(items, ",") .. "]"
		end
		local keys = Tbl.sortedKeys(v)
		local items = table.create(#keys)
		for i, k in keys do
			items[i] = string.format("%q:", tostring(k)) .. canonical(v[k])
		end
		return "{" .. table.concat(items, ",") .. "}"
	elseif t == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end

function M.key(method: string, params: { [string]: any }): string
	return method .. " " .. canonical(params)
end

local function lookup(c: Calls, method: string, params: { [string]: any }): Answer?
	local key = M.key(method, params)
	local a = c.answers[key]
	if a == nil and not c.asked[key] then
		c.asked[key] = true
		table.insert(c.wanted, { key = key, method = method, params = params })
	end
	return a
end

-- Asks for a call the chain needs later, without waiting for it (the
-- plugin's Promise.all of independent calls).
function M.want(c: Calls, method: string, params: { [string]: any })
	lookup(c, method, params)
end

local function fail(message: string): never
	error({ zabbix = message }, 0)
end

-- The result of a call; unwinds the chain while it is unanswered or when it
-- failed.
function M.call(c: Calls, method: string, params: { [string]: any }): any
	local a = lookup(c, method, params)
	if a == nil then
		error(PENDING, 0)
	end
	local answer = a :: Answer
	if answer.error then
		fail(answer.error :: string)
	end
	return answer.value
end

export type Status = "done" | "pending" | "error"

-- Runs a chain: its result, or pending (c.wanted holds what it waits for),
-- or the error the plugin rejects the query with.
function M.run(fn: () -> any): (Status, any)
	local ok, result = pcall(fn)
	if ok then
		return "done", result
	elseif result == PENDING then
		return "pending", nil
	elseif type(result) == "table" and type(result.zabbix) == "string" then
		return "error", result.zabbix
	end
	error(result, 0)
end

-- A list param: tagged so an empty one encodes as `[]`.
local function arr(env: Env, t: { any }): { any }
	return if env.array then env.array(t) else t
end

-- utils.mustArray.
local function list(env: Env, v: any): { any }
	v = Env.value(env, v)
	return if type(v) == "table" then v else {}
end

local function str(env: Env, v: any): string?
	v = Env.value(env, v)
	return if type(v) == "string" then v else nil
end

local function pluck(env: Env, items: { any }, field: string): { any }
	local out = table.create(#items)
	for i, it in items do
		out[i] = if type(it) == "table" then Env.value(env, it[field]) else nil
	end
	return arr(env, out)
end

-- Filters (zabbix.ts findByFilter and friends) ------------------------------------

-- utils.isRegex: `/pattern/flags`.
function M.isRegex(s: string?): boolean
	return s ~= nil and string.match(s, "^/.*/[gmi]*$") ~= nil
end

local regexCache: { [string]: Regex.Regex } = {}

-- utils.buildRegex; an invalid pattern rejects the query as `new RegExp` does.
function M.buildRegex(s: string): Regex.Regex
	local hit = regexCache[s]
	if hit then
		return hit
	end
	local pattern, flags = string.match(s, "^/(.*)/([gmi]*)$")
	local re, err = Regex.compile(pattern or "", flags)
	if re == nil then
		fail(string.format("Invalid regular expression: %s: %s", s, err or "invalid pattern"))
	end
	regexCache[s] = re :: Regex.Regex
	return re :: Regex.Regex
end

-- RegExp.test on a value JavaScript would stringify (undefined -> "undefined").
local function test(re: Regex.Regex, v: any): boolean
	local s = if v == nil then "undefined" elseif type(v) == "string" then v else tostring(v)
	local ok, err = Regex.test(re, s)
	if err then
		fail(err)
	end
	return ok
end

local function nameOf(env: Env, item: any): any
	return if type(item) == "table" then Env.value(env, item.name) else nil
end

-- findByFilter: a regex keeps every match, a name only the first equal one.
function M.findByFilter(env: Env, items: { any }, filter: string?): { any }
	local out: { any } = {}
	if M.isRegex(filter) then
		local re = M.buildRegex(filter :: string)
		for _, it in items do
			if test(re, nameOf(env, it)) then
				table.insert(out, it)
			end
		end
		return out
	end
	for _, it in items do
		if nameOf(env, it) == filter then
			table.insert(out, it)
			break
		end
	end
	return out
end

-- filterByQuery: like findByFilter, but every equal name.
function M.filterByQuery(env: Env, items: { any }, filter: string?): { any }
	if M.isRegex(filter) then
		return M.findByFilter(env, items, filter)
	end
	local out: { any } = {}
	for _, it in items do
		if nameOf(env, it) == filter then
			table.insert(out, it)
		end
	end
	return out
end

-- utils.wildcardToRegex: `*` is any run, case-insensitive, anchored.
local function wildcard(pattern: string): Regex.Regex
	local pieces = string.split(pattern, "*")
	for i, p in pieces do
		pieces[i] = (string.gsub(p, "[\\%^%$%+%?%.%(%)|%[%]{}]", "\\%0"))
	end
	local re = Regex.compile("^" .. table.concat(pieces, ".*") .. "$", "i")
	return re :: Regex.Regex
end

-- utils.matchesProblemName.
function M.matchesProblemName(value: string, filter: string): boolean
	if M.isRegex(filter) then
		return test(M.buildRegex(filter), value)
	elseif string.find(filter, "*", 1, true) then
		return test(wildcard(filter), value)
	end
	return value == filter
end

-- Problem name search (utils.buildProblemNameSearchParams) -----------------------

local MIN_LITERAL_LENGTH = 3

local function chars(s: string): { string }
	local out: { string } = {}
	for _, cp in utf8.codes(s) do
		table.insert(out, utf8.char(cp))
	end
	return out
end

local TERMINATORS = table.freeze({ ["."] = true, ["+"] = true, ["^"] = true, ["$"] = true, ["}"] = true, ["|"] = true })

-- guaranteedLiteralForBranch.
local function branchLiteral(pattern: string): string?
	local cs = chars(pattern)
	local runs: { { string } } = {}
	local marks: { number } = {}
	local current: { string } = {}
	local function flush(dropLast: boolean)
		if dropLast and #current > 0 then
			table.remove(current)
		end
		if #current > 0 then
			table.insert(runs, current)
		end
		current = {}
	end
	local i = 1
	local n = #cs
	while i <= n do
		local ch = cs[i]
		if ch == "\\" then
			flush(false)
			i += 1
		elseif ch == "[" then
			flush(false)
			i += 1
			while i <= n and cs[i] ~= "]" do
				if cs[i] == "\\" then
					i += 1
				end
				i += 1
			end
		elseif ch == "(" then
			flush(false)
			table.insert(marks, #runs)
		elseif ch == ")" then
			flush(false)
			local mark = table.remove(marks) or 0
			local nextCh = cs[i + 1]
			if nextCh == "?" or nextCh == "*" or nextCh == "{" then
				for k = #runs, mark + 1, -1 do
					runs[k] = nil
				end
				i += 1
				if nextCh == "{" then
					while i <= n and cs[i] ~= "}" do
						i += 1
					end
				end
			end
		elseif ch == "?" or ch == "*" or ch == "{" then
			flush(true)
			if ch == "{" then
				while i <= n and cs[i] ~= "}" do
					i += 1
				end
			end
		elseif TERMINATORS[ch] then
			flush(false)
		else
			table.insert(current, ch)
		end
		i += 1
	end
	flush(false)
	local longest: { string } = {}
	for _, r in runs do
		if #r > #longest then
			longest = r
		end
	end
	return if #longest >= MIN_LITERAL_LENGTH then table.concat(longest) else nil
end

-- stripAnchorsAndOuterGroup.
local function stripOuter(pattern: string): string
	local p = pattern
	if string.sub(p, 1, 1) == "^" then
		p = string.sub(p, 2)
	end
	if string.sub(p, -1) == "$" then
		p = string.sub(p, 1, -2)
	end
	while string.sub(p, 1, 1) == "(" and string.sub(p, 1, 2) ~= "(?" do
		local depth, finish, inClass = 0, -1, false
		local i = 1
		while i <= #p do
			local ch = string.sub(p, i, i)
			if ch == "\\" then
				i += 1
			elseif inClass then
				if ch == "]" then
					inClass = false
				end
			elseif ch == "[" then
				inClass = true
			elseif ch == "(" then
				depth += 1
			elseif ch == ")" then
				depth -= 1
				if depth == 0 then
					finish = i
					break
				end
			end
			i += 1
		end
		if finish == #p then
			p = string.sub(p, 2, -2)
		else
			break
		end
	end
	return p
end

-- splitTopLevelAlternation.
local function splitTop(pattern: string): { string }
	local branches: { string } = {}
	local depth, inClass = 0, false
	local current: { string } = {}
	local i = 1
	while i <= #pattern do
		local ch = string.sub(pattern, i, i)
		if ch == "\\" then
			table.insert(current, string.sub(pattern, i, i + 1))
			i += 1
		elseif inClass then
			table.insert(current, ch)
			if ch == "]" then
				inClass = false
			end
		elseif ch == "[" then
			inClass = true
			table.insert(current, ch)
		elseif ch == "(" then
			depth += 1
			table.insert(current, ch)
		elseif ch == ")" then
			depth -= 1
			table.insert(current, ch)
		elseif ch == "|" and depth == 0 then
			table.insert(branches, table.concat(current))
			current = {}
		else
			table.insert(current, ch)
		end
		i += 1
	end
	table.insert(branches, table.concat(current))
	return branches
end

-- extractRegexLiterals: substrings one of which every match contains, nil
-- when no safe narrowing exists.
function M.regexLiterals(filter: string): { string }?
	if not M.isRegex(filter) then
		return nil
	end
	local pattern = string.match(filter, "^/(.*)/[gmi]*$")
	if pattern == nil or pattern == "" or string.find(pattern, "(?", 1, true) then
		return nil
	end
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, branch in splitTop(stripOuter(pattern)) do
		local lit = branchLiteral(branch)
		if lit == nil then
			return nil
		end
		if not seen[lit] then
			seen[lit] = true
			table.insert(out, lit)
		end
	end
	return out
end

-- buildProblemNameSearchParams, written into `params`.
local function problemNameSearch(env: Env, params: { [string]: any }, filter: string?)
	if filter == nil or filter == "" then
		return
	end
	if M.isRegex(filter) then
		local lits = M.regexLiterals(filter :: string)
		if lits == nil or #lits == 0 then
			return
		elseif #lits == 1 then
			params.search = { name = lits[1] }
		else
			params.search = { name = arr(env, lits) }
			params.searchByAny = true
		end
	elseif string.find(filter :: string, "*", 1, true) then
		params.search = { name = filter }
		params.searchWildcardsEnabled = true
	else
		params.search = { name = filter }
	end
end

-- Tags --------------------------------------------------------------------------

export type Tag = { tag: string?, value: string?, operator: number? }

-- utils.parseTags: "a:1, b:2".
function M.parseTags(s: string?): { Tag }
	local out: { Tag } = {}
	if s == nil or s == "" then
		return out
	end
	for _, piece in string.split(s, ",") do
		local p = string.split(Str.trim(piece), ":")
		table.insert(out, {
			tag = if p[1] then Str.trim(p[1]) else nil,
			value = if p[2] then Str.trim(p[2]) else nil,
		})
	end
	return out
end

-- The legacy free-text filter, without the `/^`..`$/` a variable wrapped it
-- in, as Equal filters.
function M.legacyTags(s: string?): { Tag }
	local raw = s or ""
	raw = string.gsub(raw, "/%^", "", 1)
	raw = string.gsub(raw, "%$/", "", 1)
	local tags = M.parseTags(raw)
	for _, t in tags do
		t.operator = 1
	end
	return tags
end

local function trimAnchors(s: string): string
	s = string.gsub(s, "/%^", "", 1)
	s = string.gsub(s, "%$/", "", 1)
	return s
end

-- utils.problemTagsToQueryParam: structured filters (Contains by default;
-- Exists / Does not exist without a value; a variable that expanded to the
-- legacy "tag:value" text split like the old filter).
function M.problemTags(env: Env, filters: { any }): { Tag }
	local out: { Tag } = {}
	for _, f in filters do
		if type(f) ~= "table" then
			continue
		end
		local tag = Str.trim(trimAnchors(str(env, f.tag) or ""))
		local value = Str.trim(trimAnchors(str(env, f.value) or ""))
		local rawOp = Env.value(env, f.operator)
		local operator = tonumber(if rawOp == nil then "0" else tostring(rawOp)) or 0
		if tag == "" then
			continue
		end
		if operator == 4 or operator == 5 then
			table.insert(out, { tag = tag, operator = operator })
		elseif value == "" and string.find(tag, ":", 1, true) then
			for _, parsed in M.parseTags(tag) do
				if parsed.tag and parsed.tag ~= "" then
					table.insert(out, { tag = parsed.tag, value = parsed.value or "", operator = operator } :: Tag)
				end
			end
		else
			table.insert(out, { tag = tag, value = value, operator = operator } :: Tag)
		end
	end
	return out
end

local function tagParams(env: Env, tags: { Tag }): { any }
	local out = table.create(#tags)
	for i, t in tags do
		out[i] = { tag = t.tag, value = t.value, operator = t.operator }
	end
	return arr(env, out)
end

-- API calls (ZabbixAPIConnector) --------------------------------------------------

local function allGroups(c: Calls): { any }
	local params: { [string]: any } = { output = arr(c.env, { "name", "groupid" }), sortfield = "name" }
	params[withHostsKey(c.version)] = true
	return list(c.env, M.call(c, "hostgroup.get", params))
end

function M.groups(c: Calls, filter: string?): { any }
	return M.findByFilter(c.env, allGroups(c), filter)
end

function M.hosts(c: Calls, groupFilter: string?, hostFilter: string?): { any }
	local groups = M.groups(c, groupFilter)
	local all = list(
		c.env,
		M.call(c, "host.get", {
			output = arr(c.env, { "hostid", "name", "host" }),
			sortfield = "name",
			groupids = pluck(c.env, groups, "groupid"),
		})
	)
	return M.findByFilter(c.env, all, hostFilter)
end

-- Zabbix.getApps: the hosts' applications (before 5.4) matching the filter;
-- `empty` when there is no application filter (or no applications), with
-- the host ids.
function M.apps(c: Calls, groupFilter: string?, hostFilter: string?, appFilter: string?): ({ any }, boolean, { any })
	local hosts = M.hosts(c, groupFilter, hostFilter)
	local hostids = pluck(c.env, hosts, "hostid")
	if appFilter and appFilter ~= "" and supportsApplications(c.version) then
		local apps = list(c.env, M.call(c, "application.get", { output = "extend", hostids = hostids }))
		return M.filterByQuery(c.env, apps, appFilter), false, hostids
	end
	return {}, true, hostids
end

-- getHostsApsFromTarget: the hosts and the filtered applications ([] without
-- an application filter).
local function hostsApps(c: Calls, t: Target): ({ any }, { any })
	local hosts = M.hosts(c, t.group, t.host)
	local apps, empty = M.apps(c, t.group, t.host, t.application)
	return hosts, if empty then {} else apps
end

local function proxies(c: Calls): { any }
	local output = { "proxyid", if M.gte(c.version, "7.0.0") then "name" else "host" }
	return list(c.env, M.call(c, "proxy.get", { output = arr(c.env, output) }))
end

local function wantProxies(c: Calls)
	local output = { "proxyid", if M.gte(c.version, "7.0.0") then "name" else "host" }
	M.want(c, "proxy.get", { output = arr(c.env, output) })
end

local function userParams(c: Calls): { [string]: any }
	return { output = arr(c.env, { "userid", "username", "name", "surname" }) }
end

local function wantUsers(c: Calls)
	M.want(c, "user.get", userParams(c))
end

local function users(c: Calls): { any }
	return list(c.env, M.call(c, "user.get", userParams(c)))
end

export type ProblemOptions = {
	recent: boolean?,
	severities: { number }?,
	limit: number?,
	acknowledged: boolean?,
	tags: { Tag }?,
	evaltype: any?,
	problem_name: string?,
	symptom: any?,
	time_from: number?,
	time_to: number?,
}

local function problemCall(
	c: Calls,
	groupids: { any }?,
	hostids: { any }?,
	appids: { any }?,
	o: ProblemOptions
): { any }
	local env = c.env
	local params: { [string]: any } = {
		output = "extend",
		selectAcknowledges = "extend",
		selectSuppressionData = "extend",
		selectTags = "extend",
		source = "0",
		object = "0",
		sortfield = arr(env, { "eventid" }),
		sortorder = "DESC",
		evaltype = "0",
		groupids = groupids,
		hostids = hostids,
		recent = o.recent,
	}
	if o.severities then
		params.severities = arr(env, table.clone(o.severities :: { number }))
	end
	if o.acknowledged ~= nil then
		params.acknowledged = o.acknowledged
	end
	if o.tags then
		params.tags = tagParams(env, o.tags :: { Tag })
	end
	if o.evaltype ~= nil and o.evaltype ~= "" and o.evaltype ~= 0 and o.evaltype ~= false then
		params.evaltype = o.evaltype
	end
	if o.limit and o.limit ~= 0 then
		params.limit = o.limit
	end
	if (o.time_from and o.time_from ~= 0) or (o.time_to and o.time_to ~= 0) then
		params.time_from = o.time_from
		params.time_till = o.time_to
	end
	if supportsApplications(c.version) then
		params.applicationids = appids
	end
	problemNameSearch(env, params, o.problem_name)
	if M.gte(c.version, "6.4.0") and o.symptom ~= nil then
		params.symptom = o.symptom
	end
	return list(env, M.call(c, "problem.get", params))
end

local function eventsCall(c: Calls, groupids: { any }?, hostids: { any }?, appids: { any }?, o: ProblemOptions): { any }
	local env = c.env
	local params: { [string]: any } = {
		output = "extend",
		time_from = o.time_from,
		time_till = o.time_to,
		value = "1",
		source = "0",
		object = "0",
		evaltype = "0",
		sortfield = arr(env, { "eventid" }),
		sortorder = "DESC",
		selectTags = "extend",
		selectSuppressionData = arr(env, { "maintenanceid", "suppress_until" }),
		groupids = groupids,
		hostids = hostids,
		applicationids = appids,
	}
	params[selectAcknowledgesKey(c.version)] = "extend"
	if o.limit and o.limit ~= 0 then
		params.limit = o.limit
	end
	if o.severities then
		params.severities = arr(env, table.clone(o.severities :: { number }))
	end
	if o.tags then
		params.tags = tagParams(env, o.tags :: { Tag })
	end
	if o.evaltype ~= nil and o.evaltype ~= "" and o.evaltype ~= 0 and o.evaltype ~= false then
		params.evaltype = o.evaltype
	end
	problemNameSearch(env, params, o.problem_name)
	if M.gte(c.version, "6.4.0") and o.symptom ~= nil then
		params.symptom = o.symptom
	end
	return list(env, M.call(c, "event.get", params))
end

-- getTriggersByIds: triggers keyed by id (preservekeys), `groups` from
-- `hostgroups` on 7.0+. The comment is expanded unless `expandComment` is
-- false (the key must then be absent: Zabbix reads presence as true).
local function triggersByIds(c: Calls, ids: { any }, expandComment: boolean): { [string]: any }
	local env = c.env
	local selectHosts = { "hostid", "name", "host", "maintenance_status", "description" }
	table.insert(selectHosts, if M.gte(c.version, "7.0.0") then "proxyid" else "proxy_hostid")
	local params: { [string]: any } = {
		output = "extend",
		triggerids = arr(env, ids),
		expandDescription = true,
		expandData = true,
		expandExpression = true,
		monitored = true,
		skipDependent = true,
		selectHosts = arr(env, selectHosts),
		selectItems = arr(env, { "itemid", "name", "key_", "lastvalue", "value_type" }),
		preservekeys = "1",
	}
	if expandComment then
		params.expandComment = true
	end
	params[selectHostGroupsKey(c.version)] = arr(env, { "name", "groupid" })
	local triggers = Env.value(env, M.call(c, "trigger.get", params))
	local out: { [string]: any } = {}
	if type(triggers) == "table" then
		for id, t in triggers do
			if type(t) == "table" then
				if M.gte(c.version, "7.0.0") then
					t.groups = t.hostgroups
				end
				out[tostring(id)] = t
			end
		end
	end
	return out
end

local function lastEventAck(env: Env, t: any): any
	local le = Env.value(env, t.lastEvent)
	return if type(le) == "table" then Env.value(env, le.acknowledged) else nil
end

-- filterTriggersByAcknowledge.
local function byAck(env: Env, triggers: { any }, acknowledged: any): { any }
	if acknowledged ~= 0 and acknowledged ~= 1 then
		return triggers
	end
	local want = if acknowledged == 0 then "0" else "1"
	local out: { any } = {}
	for _, t in triggers do
		if type(t) == "table" and lastEventAck(env, t) == want then
			table.insert(out, t)
		end
	end
	return out
end

local function groupsFromHostgroups(c: Calls, triggers: { any })
	if M.gte(c.version, "7.0.0") then
		for _, t in triggers do
			if type(t) == "table" then
				t.groups = t.hostgroups
			end
		end
	end
end

export type AlertOptions = {
	min_severity: any,
	acknowledged: any,
	count: boolean,
	tags: { Tag }?,
	time_from: number?,
	time_to: number?,
}

-- The answer of the alert calls: a count, or the triggers.
export type Alerts = { count: number?, triggers: { any }? }

-- getHostAlerts.
local function hostAlerts(c: Calls, hostids: { any }, appids: { any }, o: AlertOptions): Alerts
	local env = c.env
	local params: { [string]: any } = {
		output = "extend",
		hostids = hostids,
		min_severity = o.min_severity,
		filter = { value = 1 },
		expandDescription = true,
		expandData = true,
		expandComment = true,
		monitored = true,
		skipDependent = true,
		selectLastEvent = "extend",
		selectHosts = arr(env, { "hostid", "host", "name" }),
	}
	params[selectHostGroupsKey(c.version)] = "extend"
	if o.count and o.acknowledged ~= 1 then
		params.countOutput = true
		if o.acknowledged == 0 then
			params.withLastEventUnacknowledged = true
		end
	end
	if #appids > 0 then
		params.applicationids = appids
	end
	if (o.time_from and o.time_from ~= 0) or (o.time_to and o.time_to ~= 0) then
		params.lastChangeSince = o.time_from
		params.lastChangeTill = o.time_to
	end
	if o.tags then
		params.tags = tagParams(env, o.tags :: { Tag })
		params.evaltype = 0
	end
	local result = M.call(c, "trigger.get", params)
	if not o.count or o.acknowledged == 1 then
		local triggers = byAck(env, list(env, result), o.acknowledged)
		if o.count then
			return { count = #triggers }
		end
		groupsFromHostgroups(c, triggers)
		return { triggers = triggers }
	end
	return { count = tonumber(Env.value(env, result)) or 0 }
end

-- getHostPCAlerts.
local function hostPCAlerts(c: Calls, hostids: { any }, appids: { any }, triggerids: { any }, o: AlertOptions): Alerts
	local env = c.env
	local params: { [string]: any } = {
		output = "extend",
		hostids = hostids,
		triggerids = triggerids,
		min_severity = o.min_severity,
		filter = { value = 1 },
		expandDescription = true,
		expandData = true,
		expandComment = true,
		monitored = true,
		skipDependent = true,
		selectLastEvent = "extend",
		selectHosts = arr(env, { "host", "name" }),
		selectItems = arr(env, { "name", "key_" }),
	}
	params[selectHostGroupsKey(c.version)] = "extend"
	if o.count and o.acknowledged ~= 0 and o.acknowledged ~= 1 then
		params.countOutput = true
	end
	if #appids > 0 then
		params.applicationids = appids
	end
	if (o.time_from and o.time_from ~= 0) or (o.time_to and o.time_to ~= 0) then
		params.lastChangeSince = o.time_from
		params.lastChangeTill = o.time_to
	end
	local result = M.call(c, "trigger.get", params)
	if not o.count or o.acknowledged == 0 or o.acknowledged == 1 then
		local triggers = byAck(env, list(env, result), o.acknowledged)
		if o.count then
			return { count = #triggers }
		end
		groupsFromHostgroups(c, triggers)
		return { triggers = triggers }
	end
	return { count = tonumber(Env.value(env, result)) or 0 }
end

-- Problems (problemsHandler) -------------------------------------------------------

-- A problem as the Problems panel reads it (ProblemDTO): the decoded
-- problem/event fields joined with its trigger's.
export type Problem = { [string]: any }

local function join(env: Env, events: { any }, triggers: { [string]: any }, fromEvent: boolean): { Problem }
	local out: { Problem } = {}
	for _, p in events do
		if type(p) ~= "table" then
			continue
		end
		local id = Env.value(env, p.objectid)
		local t = if id ~= nil then triggers[tostring(id)] else nil
		if t == nil then
			continue
		end
		local function e(k: string): any
			return Env.value(env, p[k])
		end
		local function tr(k: string): any
			return Env.value(env, t[k])
		end
		table.insert(out, {
			timestamp = tonumber(e("clock")) or 0,
			triggerid = e("objectid"),
			eventid = e("eventid"),
			name = e("name"),
			severity = e("severity"),
			acknowledged = e("acknowledged"),
			acknowledges = e("acknowledges"),
			tags = e("tags"),
			suppressed = e("suppressed"),
			suppression_data = if fromEvent then nil else e("suppression_data"),
			description = if fromEvent then tr("description") else (e("name") or tr("description")),
			comments = tr("comments"),
			value = tr("value"),
			opdata = if fromEvent then nil else e("opdata"),
			groups = tr("groups"),
			hosts = tr("hosts"),
			items = tr("items"),
			alerts = tr("alerts"),
			url = tr("url"),
			expression = tr("expression"),
			correlation_mode = tr("correlation_mode"),
			correlation_tag = tr("correlation_tag"),
			manual_close = tr("manual_close"),
			state = tr("state"),
			error = tr("error"),
		})
	end
	return out
end

local function hostsOf(env: Env, t: any): { any }
	return list(env, if type(t) == "table" then t.hosts else nil)
end

-- filterTriggersByProxy (the proxies are always read).
local function byProxy(c: Calls, triggers: { any }, proxyFilter: string?): { any }
	local all = proxies(c)
	for _, p in all do
		if type(p) == "table" then
			p.name = Env.value(c.env, p.host)
		end
	end
	local matched = M.findByFilter(c.env, all, proxyFilter)
	if proxyFilter == nil or proxyFilter == "" or proxyFilter == "/.*/" then
		return triggers
	end
	local ids: { [string]: boolean } = {}
	for _, p in matched do
		local id = Env.value(c.env, p.proxyid)
		if id ~= nil then
			ids[tostring(id)] = true
		end
	end
	local out: { any } = {}
	for _, t in triggers do
		for _, h in hostsOf(c.env, t) do
			local id = if type(h) == "table"
				then Env.value(c.env, h.proxyid) or Env.value(c.env, h.proxy_hostid)
				else nil
			if id ~= nil and ids[tostring(id)] then
				table.insert(out, t)
				break
			end
		end
	end
	return out
end

-- The interpolated parts of a target the chains read.
export type Target = {
	ref_id: string,
	-- The query type: "4" triggers, "5" problems.
	mode: string,
	group: string?,
	host: string?,
	application: string?,
	proxy: string?,
	trigger: string?,
	-- The legacy free-text tags filter.
	tags: string?,
	-- Structured problem tag filters (schema 13).
	problem_tags: { any }?,
	evaltype: any?,
	show_problems: string,
	count_by: string,
	options: { [string]: any },
	datasource: any,
}

local function idsOf(env: Env, items: { any }, field: string): { any }
	return pluck(env, items, field)
end

-- getCProblems: problems of the target's groups/hosts/applications whose
-- name passes the trigger filter, joined with their triggers, by proxy.
local function cproblems(c: Calls, t: Target, o: ProblemOptions): { Problem }
	local env = c.env
	local groups = M.groups(c, t.group)
	local hosts = M.hosts(c, t.group, t.host)
	local apps = M.apps(c, t.group, t.host, t.application)
	local hostids = if t.host and t.host ~= "" and t.host ~= "/.*/" then idsOf(env, hosts, "hostid") else nil
	local groupids = if t.group and t.group ~= "" then idsOf(env, groups, "groupid") else nil
	local appids = if t.application and t.application ~= "" then idsOf(env, apps, "applicationid") else nil
	local problems = problemCall(c, groupids, hostids, appids, o)
	problems = M.findByFilter(env, problems, t.trigger)
	local ids = idsOf(env, problems, "objectid")
	local triggers = triggersByIds(c, ids, true)
	return byProxy(c, join(env, problems, triggers, false), t.proxy)
end

-- Triggers count (queryTriggersData) -------------------------------------------------

local function num(env: Env, v: any): number?
	v = Env.value(env, v)
	return if type(v) == "number" then v else nil
end

local function timeRange(env: Env, t: Target, from_s: number, to_s: number): (number?, number?)
	if Env.value(env, t.options.useTimeRange) == true then
		return from_s, to_s
	end
	return nil, nil
end

-- getTriggerStats + handleTriggersResponse.
function M.triggersFrame(env: Env, alerts: Alerts, groups: { any }, to_s: number, refId: string): Frame.Frame
	if alerts.triggers == nil then
		return {
			name = "Count " .. refId,
			refId = refId,
			fields = {
				Frame.field("Time", "time", { to_s * 1000 }),
				Frame.field("Value", "number", { alerts.count or Frame.NULL }),
			},
		}
	end
	local stats: { [string]: { [number]: number } } = {}
	for _, t in alerts.triggers :: { any } do
		local priority = tonumber(Env.value(env, t.priority))
		for _, g in list(env, t.groups) do
			local name = if type(g) == "table" then str(env, g.name) else nil
			if name then
				local s = stats[name] or { [0] = 0, [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0 }
				stats[name] = s
				if priority and s[priority] then
					s[priority] += 1
				end
			end
		end
	end
	local names: { any } = {}
	local columns: { { number } } = {}
	for i = 1, #TRIGGER_SEVERITY do
		columns[i] = {}
	end
	for _, g in groups do
		local name = if type(g) == "table" then str(env, g.name) else nil
		table.insert(names, name or Frame.NULL)
		local s = if name then stats[name] else nil
		for i = 1, #TRIGGER_SEVERITY do
			table.insert(columns[i], if s then s[#TRIGGER_SEVERITY - i] else 0)
		end
	end
	local fields = { Frame.field("Host group", "string", names) }
	for i = 1, #TRIGGER_SEVERITY do
		local name = TRIGGER_SEVERITY[#TRIGGER_SEVERITY - i + 1]
		table.insert(fields, Frame.field(name, "number", columns[i], nil, { unit = "none", decimals = 0 }))
	end
	return { name = "Triggers " .. refId, refId = refId, fields = fields }
end

-- queryTriggersPCData (countTriggersBy "problems").
local function triggersByProblems(c: Calls, t: Target, from_s: number, to_s: number): Frame.Frame?
	local env = c.env
	wantProxies(c)
	local o = t.options
	local minSeverity = num(env, o.minSeverity)
	local po: ProblemOptions = { limit = num(env, o.limit) }
	local tags = M.legacyTags(t.tags)
	if #tags > 0 then
		po.tags = tags
	end
	local ack = Env.value(env, o.acknowledged)
	if ack == 0 or ack == 1 then
		po.acknowledged = ack == 1
	end
	if minSeverity and minSeverity ~= 0 then
		local sevList = Env.value(env, o.severities)
		local sev: { number } = {}
		for v = 0, 5 do
			if v >= minSeverity and (type(sevList) ~= "table" or table.find(sevList, v)) then
				table.insert(sev, v)
			end
		end
		po.severities = sev
	end
	local tf, tt = timeRange(env, t, from_s, to_s)
	po.time_from, po.time_to = tf, tt
	local hosts, apps = hostsApps(c, t)
	local problems = cproblems(c, t, po)
	if #hosts == 0 then
		return nil
	end
	local groups = M.groups(c, t.group)
	local alerts = hostPCAlerts(
		c,
		idsOf(env, hosts, "hostid"),
		idsOf(env, apps, "applicationid"),
		idsOf(env, problems, "triggerid"),
		{
			min_severity = Env.value(env, o.minSeverity),
			acknowledged = ack,
			count = Env.value(env, o.count) == true,
			time_from = tf,
			time_to = tt,
		}
	)
	return M.triggersFrame(env, alerts, groups, to_s, t.ref_id)
end

-- queryTriggersData (countTriggersBy unset: the triggers of the hosts).
local function triggersByHosts(c: Calls, t: Target, from_s: number, to_s: number): Frame.Frame?
	local env = c.env
	local hosts, apps = hostsApps(c, t)
	if #hosts == 0 then
		return nil
	end
	local groups = M.groups(c, t.group)
	local o = t.options
	local tf, tt = timeRange(env, t, from_s, to_s)
	local tags = M.legacyTags(t.tags)
	local alerts = hostAlerts(c, idsOf(env, hosts, "hostid"), idsOf(env, apps, "applicationid"), {
		min_severity = Env.value(env, o.minSeverity),
		acknowledged = Env.value(env, o.acknowledged),
		count = Env.value(env, o.count) == true,
		tags = if #tags > 0 then tags else nil,
		time_from = tf,
		time_to = tt,
	})
	return M.triggersFrame(env, alerts, groups, to_s, t.ref_id)
end

-- The frame of a triggers-mode target, nil when the plugin returns none.
function M.triggers(c: Calls, t: Target, from_s: number, to_s: number): Frame.Frame?
	if t.count_by == "problems" then
		return triggersByProblems(c, t, from_s, to_s)
	end
	return triggersByHosts(c, t, from_s, to_s)
end

-- Problems (queryProblems) -------------------------------------------------------------

-- lodash orderBy over string or number keys, all descending.
local function before(a: any, b: any): boolean
	if a == b then
		return false
	elseif a == nil then
		return false
	elseif b == nil then
		return true
	elseif type(a) == type(b) then
		return a > b
	end
	return tostring(a) > tostring(b)
end

function M.orderDesc(problems: { Problem }, keys: { string }): { Problem }
	local indexed = table.create(#problems)
	for i, p in problems do
		indexed[i] = { p = p, i = i }
	end
	table.sort(indexed, function(x, y)
		for _, k in keys do
			local a, b = x.p[k], y.p[k]
			if a ~= b then
				return before(a, b)
			end
		end
		return x.i < y.i
	end)
	local out = table.create(#indexed)
	for i, e in indexed do
		out[i] = e.p
	end
	return out
end

local function problemsList(c: Calls, t: Target, from_s: number, to_s: number): { Problem }
	local env = c.env
	local o = t.options
	local showProblems = if t.show_problems ~= "" then t.show_problems else "problems"
	local showProxy = Env.value(env, o.hostProxy) == true
	local showHostIp = Env.value(env, o.hostIp) == true
	wantUsers(c)
	wantProxies(c)
	local tags: { Tag }
	if t.problem_tags and #(t.problem_tags :: { any }) > 0 then
		tags = M.problemTags(env, t.problem_tags :: { any })
	else
		tags = M.legacyTags(t.tags)
	end
	local po: ProblemOptions = {
		recent = showProblems == "recent",
		limit = num(env, o.limit),
		problem_name = t.trigger,
	}
	if #tags > 0 then
		po.tags = tags
	end
	if t.evaltype ~= nil then
		po.evaltype = t.evaltype
	end
	local ackOpt = Env.value(env, o.acknowledged)
	if ackOpt == 0 or ackOpt == 1 then
		po.acknowledged = ackOpt == 1
	end
	local only = list(env, o.severities)
	if #only > 0 then
		local sev: { number } = {}
		for v = 0, 5 do
			if table.find(only, v) then
				table.insert(sev, v)
			end
		end
		po.severities = sev
	end
	local symptom = Env.value(env, o.symptom)
	if symptom ~= nil then
		po.symptom = symptom
	end
	local problems: { Problem }
	if showProblems == "history" or Env.value(env, o.useTimeRange) == true then
		po.time_from, po.time_to = from_s, to_s
		local groups = M.groups(c, t.group)
		local hosts = M.hosts(c, t.group, t.host)
		local apps = M.apps(c, t.group, t.host, t.application)
		local appids = if t.application
				and t.application ~= ""
				and supportsApplications(c.version)
			then idsOf(env, apps, "applicationid")
			else nil
		local hostids = if t.host and t.host ~= "" then idsOf(env, hosts, "hostid") else nil
		local groupids = if t.group and t.group ~= "" then idsOf(env, groups, "groupid") else nil
		local events = eventsCall(c, groupids, hostids, appids, po)
		local triggers = triggersByIds(c, idsOf(env, events, "objectid"), true)
		problems = byProxy(c, join(env, events, triggers, true), t.proxy)
	else
		local groups = M.groups(c, t.group)
		local hosts = M.hosts(c, t.group, t.host)
		local apps = M.apps(c, t.group, t.host, t.application)
		local hostids = if t.host and t.host ~= "" and t.host ~= "/.*/" then idsOf(env, hosts, "hostid") else nil
		local groupids = if t.group and t.group ~= "" then idsOf(env, groups, "groupid") else nil
		local appids = if t.application and t.application ~= "" then idsOf(env, apps, "applicationid") else nil
		local found = problemCall(c, groupids, hostids, appids, po)
		local triggers = triggersByIds(c, idsOf(env, found, "objectid"), true)
		problems = byProxy(c, join(env, found, triggers, false), t.proxy)
	end
	local userList = users(c)
	local proxyList = if showProxy then proxies(c) else {}

	-- setMaintenanceStatus
	for _, p in problems do
		local inMaintenance = false
		for _, h in hostsOf(env, p) do
			if type(h) == "table" and Env.value(env, h.maintenance_status) == "1" then
				inMaintenance = true
				break
			end
		end
		p.hostInMaintenance = inMaintenance
		p.maintenance = p.suppressed == "1"
	end
	-- filterTriggersPre
	if t.trigger and t.trigger ~= "" then
		local kept: { Problem } = {}
		for _, p in problems do
			if M.matchesProblemName(if type(p.name) == "string" then p.name else "", t.trigger :: string) then
				table.insert(kept, p)
			end
		end
		problems = kept
	end
	if Env.value(env, o.hostsInMaintenance) ~= true then
		local kept: { Problem } = {}
		for _, p in problems do
			if not p.maintenance then
				table.insert(kept, p)
			end
		end
		problems = kept
	end
	-- sortProblems
	local sort = str(env, o.sortProblems)
	if sort == "severity" then
		problems = M.orderDesc(problems, { "severity", "eventid" })
	elseif sort == "lastchange" then
		problems = M.orderDesc(problems, { "timestamp", "eventid" })
	end
	-- addTriggerDataSource, formatAcknowledges
	local byUser: { [string]: any } = {}
	for _, u in userList do
		local id = if type(u) == "table" then Env.value(env, u.userid) else nil
		if id ~= nil then
			byUser[tostring(id)] = u
		end
	end
	for _, p in problems do
		p.datasource = t.datasource
		for _, a in list(env, p.acknowledges) do
			local ack: any = a
			if type(ack) ~= "table" then
				continue
			end
			local uid = Env.value(env, ack.userid)
			local u = if uid ~= nil then byUser[tostring(uid)] else nil
			if u == nil and uid == "1" then
				u = { username = "Admin" }
			end
			ack.user = (if u then str(env, u.username) else nil) or ""
			ack.name = (if u then str(env, u.name) else nil) or ""
			ack.surname = (if u then str(env, u.surname) else nil) or ""
		end
	end
	-- addTriggerHostProxy
	local byProxyId: { [string]: any } = {}
	for _, px in proxyList :: { any } do
		local id = if type(px) == "table" then Env.value(env, px.proxyid) else nil
		if id ~= nil then
			byProxyId[tostring(id)] = px
		end
	end
	for _, p in problems do
		local h = hostsOf(env, p)[1]
		if type(h) == "table" then
			local id = Env.value(env, h.proxyid) or Env.value(env, h.proxy_hostid)
			if id ~= "0" then
				local px = if id ~= nil then byProxyId[tostring(id)] else nil
				h.proxy = if px then Env.value(env, px.host) else ""
			end
		end
	end
	if showHostIp then
		local seen: { [string]: boolean } = {}
		local hostids: { any } = {}
		for _, p in problems do
			local h = hostsOf(env, p)[1]
			local id = if type(h) == "table" then Env.value(env, h.hostid) else nil
			if id ~= nil and id ~= "" and not seen[tostring(id)] then
				seen[tostring(id)] = true
				table.insert(hostids, id)
			end
		end
		if #hostids > 0 then
			local found = list(
				env,
				M.call(c, "host.get", {
					output = arr(env, { "hostid" }),
					hostids = arr(env, hostids),
					selectInterfaces = arr(env, { "ip", "useip" }),
				})
			)
			local byHost: { [string]: any } = {}
			for _, h in found do
				local id = if type(h) == "table" then Env.value(env, h.hostid) else nil
				if id ~= nil then
					byHost[tostring(id)] = h
				end
			end
			for _, p in problems do
				local h = hostsOf(env, p)[1]
				if type(h) == "table" then
					local id = Env.value(env, h.hostid)
					local entry = if id ~= nil then byHost[tostring(id)] else nil
					local ips: { string } = {}
					for _, iface in list(env, if entry then entry.interfaces else nil) do
						local ip = if type(iface) == "table" then str(env, iface.ip) else nil
						if type(iface) == "table" and Env.value(env, iface.useip) == "1" and ip and ip ~= "" then
							table.insert(ips, ip)
						end
					end
					h.hostIp = table.concat(ips, ", ")
				end
			end
		end
	end
	return problems
end

-- problemsHandler.toDataFrame: one `other` field of problems.
function M.problemsFrame(problems: { Problem }, refId: string): Frame.Frame
	return {
		name = "problems",
		refId = refId,
		fields = { Frame.field("Problems", "other", problems, nil, { custom = { type = "problems" } }) },
	}
end

function M.problems(c: Calls, t: Target, from_s: number, to_s: number): Frame.Frame
	return M.problemsFrame(problemsList(c, t, from_s, to_s), t.ref_id)
end

return M
