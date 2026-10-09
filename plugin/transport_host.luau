--!strict
-- Executes one Request against a routed endpoint: resolves the credential
-- (command, environment variable or file), then sends with tern.fetch, or with
-- curl when the endpoint has TLS options. Decisions live in plugin/lib; this
-- file only performs the effects and hands back a Response.
--
-- Secrets live only in this VM's memory, in `cache`, for SECRET_TTL_MS. They
-- are never logged, persisted, or put in argv or URLs.

local Auth = require("./lib/auth/auth")
local Curl = require("./lib/transport/curl")
local Http = require("./lib/transport/http")
local Route = require("./lib/config/route")
local TransportTypes = require("./lib/transport/types")

type Route = Route.Route
type Request = TransportTypes.Request
type Response = TransportTypes.Response
type QueryError = TransportTypes.QueryError
type Plan = Auth.Plan

export type Callback = (Response) -> ()

local M = {}

M.SECRET_TTL_MS = 5 * 60 * 1000
M.MAX_SECRET_FILE_BYTES = 65536

type Entry = { secret: string, expires: number }

local cache: { [string]: Entry } = {}
local pending: { [string]: { (string?, string?) -> () } } = {}
-- Bumped by forget(); a resolution started before it is not cached.
local generation = 0

local function failure(kind: "auth" | "network", message: string): Response
	return {
		status = 0,
		headers = {},
		body = "",
		timed_out = false,
		failure = { kind = kind, message = message },
	}
end

local function home(): string?
	local h = tern.getenv("HOME")
	return if h == "" then nil else h
end

local function cacheKey(route: Route, plan: Plan): string
	local source = if plan.kind == "process"
		then table.concat(plan.argv, "\0")
		elseif plan.kind == "env" then plan.name
		else plan.path
	return table.concat({ route.context, route.endpoint_name, plan.kind, source }, "\0")
end

local function settle(key: string, gen: number, plan: Plan, outcome: Auth.Outcome)
	local secret, err = Auth.secret(plan, outcome)
	if secret and gen == generation then
		cache[key] = { secret = secret, expires = tern.now() + M.SECRET_TTL_MS }
	end
	local waiters = pending[key]
	pending[key] = nil
	if waiters then
		for _, waiter in waiters do
			waiter(secret, err)
		end
	end
end

local function resolve(key: string, plan: Plan, done: (string?, string?) -> ())
	local hit = cache[key]
	if hit and hit.expires > tern.now() then
		done(hit.secret, nil)
		return
	end
	cache[key] = nil
	local waiters = pending[key]
	if waiters then
		table.insert(waiters, done)
		return
	end
	pending[key] = { done }
	local gen = generation
	if plan.kind == "env" then
		settle(key, gen, plan, { text = tern.getenv(plan.name) })
	elseif plan.kind == "file" then
		local ok, text = pcall(tern.fs.read, plan.path, M.MAX_SECRET_FILE_BYTES)
		settle(key, gen, plan, if ok then { text = text } else { error = tostring(text) })
	else
		local ok, err = pcall(function()
			tern.process.run(plan.argv, { timeout_ms = Auth.PROCESS_TIMEOUT_MS }, function(result: ProcessResult)
				settle(key, gen, plan, { text = result.stdout, status = result.status, timed_out = result.timed_out })
			end)
		end)
		if not ok then
			settle(key, gen, plan, { error = tostring(err) })
		end
	end
end

local function send(route: Route, request: Request, secret: string?, cb: Callback)
	local endpoint = route.endpoint
	local authHeaders = Auth.headers(endpoint.auth, secret)
	local headers = Http.headers(endpoint, request, authHeaders)
	if Curl.needsCurl(endpoint) then
		local plan, err = Curl.curlPlan(endpoint, request, headers, home())
		if plan == nil then
			cb(failure("network", err or "curl request could not be built"))
			return
		end
		local ok, spawnErr = pcall(function()
			tern.process.run(
				plan.argv,
				{ stdin = plan.stdin, timeout_ms = plan.timeout_ms },
				function(result: ProcessResult)
					cb(Curl.parseCurl(result.stdout, result.status, result.stderr, result.timed_out))
				end
			)
		end)
		if not ok then
			cb(failure("network", "curl (needed for tls options) could not be started: " .. tostring(spawnErr)))
		end
		return
	end
	local options: FetchOptions = {
		method = string.upper(request.method),
		headers = headers,
		body = request.body,
		timeout_ms = endpoint.timeout_ms,
	}
	local ok, fetchErr = pcall(function()
		tern.fetch(Http.url(endpoint, request), options, function(result: FetchResult)
			cb({
				status = result.status,
				headers = result.headers,
				body = result.body,
				error = result.error,
				timed_out = result.timed_out,
			})
		end)
	end)
	if not ok then
		local hide: { string } = { secret or "" }
		for _, value in authHeaders do
			table.insert(hide, value)
		end
		cb(failure("network", "invalid request: " .. Auth.redact(tostring(fetchErr), hide)))
	end
end

-- Calls `cb` exactly once with the Response.
function M.execute(route: Route, request: Request, cb: Callback)
	local plan, planErr = Auth.plan(route.endpoint.auth, home())
	if planErr then
		cb(failure("auth", planErr))
		return
	end
	if plan == nil then
		send(route, request, nil, cb)
		return
	end
	local key = cacheKey(route, plan)
	resolve(key, plan, function(secret, err)
		if secret == nil then
			cb(failure("auth", err or "credential could not be resolved"))
			return
		end
		send(route, request, secret, function(response)
			-- A rotated or revoked token: resolve it again next time.
			if response.status == 401 then
				local hit = cache[key]
				if hit and hit.secret == secret then
					cache[key] = nil
				end
			end
			cb(response)
		end)
	end)
end

-- Drops every cached secret (config reload, settings change).
function M.forget()
	table.clear(cache)
	generation += 1
end

return M
