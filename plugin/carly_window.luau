--!strict
-- Window glue for Carly (G3): registers the exports of lib/carly/exports
-- (promql, alerts, find_dashboard, logs) and the request context of
-- lib/carly/context. Exports run on the window's UI thread under a 50 ms
-- budget, so they only validate, start the fetches and return
-- `call:wait`; the answer is built in the fetch callbacks. The query stack
-- loads on the first call and the context stack on the first request, not
-- with the window entry (50 ms load budget).
--
-- Requests go through transport_host in this VM, so credentials resolve
-- exactly as in the host half (keychain item, token_env with the login-shell
-- fallback, token_cmd, 0600 file; curl for TLS options), are cached only in
-- this VM's memory and never reach Carly: answers hold names, values and
-- links only. A credential failure reaches Carly as the same one-line
-- message plus fix a block shows; raised errors lose their traceback.

local Specs = require("./lib/carly/specs")

local M = {}

-- How long Carly waits for an answer; transports time out sooner.
M.WAIT_MS = 60000

local function answer(name: string, args: { any }, call: any): any
	local ConfigHost = require("./config_host")
	local EnvHost = require("./env_host")
	local Exports = require("./lib/carly/exports")
	local Keychain = require("./lib/auth/keychain")
	local TransportHost = require("./transport_host")
	local function raised(what: string, err: any)
		pcall(tern.log.warn, "tern-grafana carly " .. name .. " " .. what .. " failed", tostring(err))
		call:fail(string.format("%s failed: %s", name, Keychain.firstLine(tostring(err))))
	end
	pcall(ConfigHost.load)
	local ok, plan, err = pcall(Exports.plan, name, args, EnvHost.make(nil))
	if not ok then
		raised("plan", plan)
		return call:wait(M.WAIT_MS)
	end
	if plan == nil then
		call:fail(err or (name .. ": invalid arguments"))
		return call:wait(M.WAIT_MS)
	end
	local p: Exports.Plan = plan
	local responses: { [string]: any } = {}
	local remaining = #p.fetches
	local function done()
		local okFinish, value, message = pcall(p.finish, responses, EnvHost.make(nil))
		if not okFinish then
			raised("finish", value)
		elseif value == nil then
			call:fail(message or (name .. " failed"))
		else
			call:reply(value)
		end
	end
	if remaining == 0 then
		done()
		return call:wait(M.WAIT_MS)
	end
	for _, f in p.fetches do
		local tag = f.tag
		local okSend, sendErr = pcall(TransportHost.execute :: any, f.route, f.request, function(response: any)
			if call.cancelled or responses[tag] ~= nil then
				return
			end
			responses[tag] = response
			remaining -= 1
			if remaining == 0 then
				done()
			end
		end)
		if not okSend then
			raised("send", sendErr)
			break
		end
	end
	return call:wait(M.WAIT_MS)
end

function M.register(t: any)
	if t.carly == nil then
		return
	end
	t.carly.export("promql", Specs.SPECS.promql, function(expr: any, range: any, context: any, _cx: any, call: any)
		return answer("promql", { expr, range, context }, call)
	end)
	t.carly.export("alerts", Specs.SPECS.alerts, function(context: any, _cx: any, call: any)
		return answer("alerts", { context }, call)
	end)
	t.carly.export("find_dashboard", Specs.SPECS.find_dashboard, function(query: any, context: any, _cx: any, call: any)
		return answer("find_dashboard", { query, context }, call)
	end)
	t.carly.export("logs", Specs.SPECS.logs, function(expr: any, range: any, context: any, _cx: any, call: any)
		return answer("logs", { expr, range, context }, call)
	end)
	t.carly.context(function(_cx: any): string?
		local CarlyContext = require("./lib/carly/context")
		local Summary = require("./lib/alerts/summary")
		local ok, raw = pcall(t.kv.get, Summary.KEY)
		if not ok then
			return nil
		end
		return CarlyContext.text(raw, os.time() * 1000)
	end)
end

return M
