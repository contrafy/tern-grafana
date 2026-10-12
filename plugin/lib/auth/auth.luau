--!strict
-- Turns a configured credential source into a resolution plan the host
-- executes, checks what came back, and builds the Authorization header.
-- Failures are Keychain.Explained values (message plus hint) that name the
-- source and program, never the secret, a command's output or a traceback.

local Base64 = require("./base64")
local Keychain = require("./keychain")
local Types = require("../config/types")
local Tbl = require("../tbl")

type Auth = Types.Auth
type SecretSource = Types.SecretSource

export type Explained = Keychain.Explained

-- What the host does to obtain the secret: run argv (no shell), read an
-- environment variable (then the login shell's), read a file, or look up a
-- keychain item.
export type Plan =
	{ kind: "process", field: string, argv: { string } }
	| { kind: "env", field: string, name: string }
	| { kind: "file", field: string, path: string }
	| { kind: "keychain", field: string, item: string }

-- What the host observed: `text` is stdout, the variable or the file content;
-- `error` a spawn or read failure; `status`/`timed_out` from a process;
-- `lookup` a keychain verdict (Keychain.lookupStatus, or "unavailable" when
-- this machine has no keychain tool). stderr is deliberately absent: a
-- command may print the secret there.
export type Outcome = {
	text: string?,
	error: string?,
	status: number?,
	timed_out: boolean?,
	lookup: ("found" | "missing" | "failed" | "unavailable")?,
}

-- Facts for messages: the context the credential belongs to and the OS.
export type Where = { context: string?, os: string? }

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
function M.plan(auth: Auth, home: string?): (Plan?, Explained?)
	local source = sourceOf(auth)
	if source == nil then
		return nil, nil
	end
	if source.from == "keychain" then
		return { kind = "keychain", field = source.field, item = source.item }, nil
	elseif source.from == "cmd" then
		return { kind = "process", field = source.field, argv = Tbl.copy(source.argv) }, nil
	elseif source.from == "env" then
		return { kind = "env", field = source.field, name = source.name }, nil
	end
	local path = M.expandHome(source.path, home)
	if path == nil then
		return nil, Keychain.explain("home_unset", { field = source.field, path = source.path })
	end
	return { kind = "file", field = source.field, path = path }, nil
end

-- A spawn error for a program that does not exist ("No such file or
-- directory (os error 2)" from tern.process.run).
local function isMissingProgram(err: string): boolean
	local lower = string.lower(err)
	return string.find(lower, "no such file", 1, true) ~= nil
		or string.find(lower, "not found", 1, true) ~= nil
		or string.find(lower, "os error 2)", 1, true) ~= nil
end

local function describe(plan: Plan): string
	if plan.kind == "process" then
		return string.format("%s `%s`", plan.field, plan.argv[1])
	elseif plan.kind == "env" then
		return "environment variable " .. plan.name
	elseif plan.kind == "keychain" then
		return "keychain item " .. plan.item
	end
	return plan.field .. " " .. plan.path
end

function M.secret(plan: Plan, outcome: Outcome, where: Where?): (string?, Explained?)
	local at: Where = where or {}
	local field = plan.field
	if plan.kind == "process" then
		local program = plan.argv[1]
		if outcome.error then
			local kind: Keychain.Kind = if isMissingProgram(outcome.error) then "cmd_missing" else "cmd_start"
			return nil, Keychain.explain(kind, { field = field, program = program, error = outcome.error })
		elseif outcome.timed_out then
			return nil,
				Keychain.explain(
					"cmd_timeout",
					{ field = field, program = program, seconds = M.PROCESS_TIMEOUT_MS // 1000 }
				)
		elseif outcome.status ~= 0 then
			return nil, Keychain.explain("cmd_failed", { field = field, program = program, status = outcome.status })
		end
	elseif plan.kind == "keychain" then
		local detail: Keychain.Detail = { field = field, item = plan.item, context = at.context, os = at.os }
		if outcome.lookup == "unavailable" then
			return nil, Keychain.explain("keychain_unavailable", detail)
		elseif outcome.timed_out then
			return nil, Keychain.explain("keychain_timeout", detail)
		elseif outcome.lookup == "missing" then
			return nil, Keychain.explain("item_missing", detail)
		elseif outcome.error or outcome.lookup ~= "found" then
			detail.status = outcome.status
			return nil, Keychain.explain("keychain_failed", detail)
		end
	elseif plan.kind == "env" then
		if outcome.text == nil or outcome.text == "" then
			return nil, Keychain.explain("env_unset", { field = field, name = plan.name, os = at.os })
		end
	elseif plan.kind == "file" and outcome.error then
		return nil, Keychain.explain("file_unreadable", { field = field, path = plan.path, error = outcome.error })
	end

	local value = string.gsub(outcome.text or "", "[\r\n]+$", "")
	local source = if plan.kind == "process" then describe(plan) .. " output" else describe(plan)
	if value == "" then
		return nil, Keychain.explain("empty", { field = field, source = source })
	end
	if string.find(value, "%c") then
		return nil, Keychain.explain("multiline", { field = field, source = source })
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
	local sorted = Tbl.copy(secrets)
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
