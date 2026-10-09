--!strict
-- Turns a configured credential source into a resolution plan the host
-- executes, checks what came back, and builds the Authorization header.
-- Messages name the source and program, never the secret or the command's
-- stdout.

local Base64 = require("./base64")
local Types = require("../config/types")

type Auth = Types.Auth
type SecretSource = Types.SecretSource

-- What the host does to obtain the secret: run argv (no shell), read an
-- environment variable, or read a file.
export type Plan =
	{ kind: "process", field: string, argv: { string } }
	| { kind: "env", field: string, name: string }
	| { kind: "file", field: string, path: string }

-- What the host observed: `text` is stdout, the variable or the file content;
-- `error` a spawn or read failure; `status`/`timed_out` from a process. stderr
-- is deliberately absent: a command may print the secret there.
export type Outcome = {
	text: string?,
	error: string?,
	status: number?,
	timed_out: boolean?,
}

local M = {}

-- Long enough for a password manager's unlock prompt.
M.PROCESS_TIMEOUT_MS = 30000

function M.expandHome(path: string, home: string?): (string?, string?)
	if path ~= "~" and string.sub(path, 1, 2) ~= "~/" then
		return path, nil
	end
	if home == nil or home == "" then
		return nil, "cannot expand ~ because HOME is not set"
	end
	local base = string.gsub(home, "/+$", "")
	return base .. string.sub(path, 2), nil
end

local function sourceOf(auth: Auth): SecretSource?
	if auth.type == "bearer" then
		return auth.token
	elseif auth.type == "basic" then
		return auth.password
	end
	return nil
end

-- nil, nil when the auth type needs no secret.
function M.plan(auth: Auth, home: string?): (Plan?, string?)
	local source = sourceOf(auth)
	if source == nil then
		return nil, nil
	end
	if source.from == "cmd" then
		return { kind = "process", field = source.field, argv = table.clone(source.argv) }, nil
	elseif source.from == "env" then
		return { kind = "env", field = source.field, name = source.name }, nil
	end
	local path, err = M.expandHome(source.path, home)
	if path == nil then
		return nil, string.format("%s %s: %s", source.field, source.path, err or "")
	end
	return { kind = "file", field = source.field, path = path }, nil
end

local function describe(plan: Plan): string
	if plan.kind == "process" then
		return string.format("%s `%s`", plan.field, plan.argv[1])
	elseif plan.kind == "env" then
		return plan.field .. " " .. plan.name
	end
	return plan.field .. " " .. plan.path
end

function M.secret(plan: Plan, outcome: Outcome): (string?, string?)
	local what = describe(plan)
	if plan.kind == "process" then
		if outcome.error then
			return nil, string.format("%s could not be started: %s", what, outcome.error)
		elseif outcome.timed_out then
			return nil,
				string.format(
					"%s timed out after %d s (an unlock prompt may be waiting)",
					what,
					M.PROCESS_TIMEOUT_MS // 1000
				)
		elseif outcome.status ~= 0 then
			return nil,
				string.format(
					"%s exited with status %s; run it in a terminal to see why",
					what,
					tostring(outcome.status)
				)
		end
	elseif plan.kind == "env" then
		if outcome.text == nil or outcome.text == "" then
			return nil, what .. " is not set or is empty"
		end
	elseif outcome.error then
		return nil, string.format("%s could not be read: %s", what, outcome.error)
	end

	local value = string.gsub(outcome.text or "", "[\r\n]+$", "")
	if value == "" then
		return nil, what .. (if plan.kind == "process" then " printed nothing" else " is empty")
	end
	if string.find(value, "%c") then
		if plan.kind == "process" then
			return nil, what .. " printed line breaks or control characters; it must print only the secret"
		end
		return nil, what .. " contains line breaks or control characters; it must hold only the secret"
	end
	return value, nil
end

function M.headers(auth: Auth, secret: string?): { [string]: string }
	if auth.type == "none" then
		return {}
	end
	if secret == nil then
		error("auth.headers: " .. auth.type .. " auth needs a resolved secret", 2)
	end
	if auth.type == "bearer" then
		return { Authorization = "Bearer " .. secret }
	end
	return { Authorization = "Basic " .. Base64.encode(auth.username .. ":" .. secret) }
end

-- Replaces every occurrence of each secret with [redacted]. Plain-text
-- matching, since a secret may contain pattern characters; longer secrets
-- first, so one that contains another is hidden whole.
function M.redact(text: string, secrets: { string }): string
	local sorted = table.clone(secrets)
	table.sort(sorted, function(a: string, b: string): boolean
		return #a > #b
	end)
	for _, secret in sorted do
		if secret == "" then
			continue
		end
		local out: { string } = {}
		local from = 1
		while true do
			local s, e = string.find(text, secret, from, true)
			if not s then
				break
			end
			table.insert(out, string.sub(text, from, s - 1))
			table.insert(out, "[redacted]")
			from = (e :: number) + 1
		end
		table.insert(out, string.sub(text, from))
		text = table.concat(out)
	end
	return text
end

return M
