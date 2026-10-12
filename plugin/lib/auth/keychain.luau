--!strict
-- The OS keychain as the plugin's credential store, and the one-line
-- explanations every credential failure turns into.
--
-- macOS uses /usr/bin/security (the login keychain), Linux secret-tool (the
-- Secret Service). Items live under service SERVICE with the item name as
-- the account. A secret never goes into argv: storing writes it to the
-- child's stdin. Explanations name sources, programs, items and exit codes,
-- never a secret or a command's output.

local M = {}

export type Platform = "macos" | "linux"

-- Facts the host gathers: tern.runtime.os, whether /usr/bin/security exists,
-- whether secret-tool is on PATH.
export type Probe = { os: string?, security: boolean, secret_tool: boolean }

export type Plan = { argv: { string }, stdin: string? }

-- message says what is wrong, hint what to do; `line` joins them.
export type Explained = { message: string, hint: string }

export type Kind =
	"item_missing"
	| "keychain_unavailable"
	| "keychain_failed"
	| "keychain_timeout"
	| "env_unset"
	| "cmd_missing"
	| "cmd_start"
	| "cmd_failed"
	| "cmd_timeout"
	| "file_unreadable"
	| "home_unset"
	| "empty"
	| "multiline"

export type Detail = {
	-- Config field, e.g. token_keychain.
	field: string?,
	context: string?,
	item: string?,
	-- Environment variable name.
	name: string?,
	-- token_cmd argv[1].
	program: string?,
	status: number?,
	path: string?,
	-- A spawn or read error from the host; only its first line is shown.
	error: string?,
	os: string?,
	seconds: number?,
	-- What printed or held an empty or multi-line value, e.g. "token_cmd `op`".
	source: string?,
}

M.SERVICE = "tern-grafana"
M.SECURITY = "/usr/bin/security"
M.SECRET_TOOL = "secret-tool"
M.MAX_ITEM = 128
-- Long enough for a keychain unlock or access prompt.
M.TIMEOUT_MS = 30000
-- security's "item could not be found" exit status.
M.MACOS_NOT_FOUND = 44

local UPDATE = "open Grafana: Settings and use Connect or Update token"

function M.platform(probe: Probe): Platform?
	if probe.os == "macos" and probe.security then
		return "macos"
	elseif probe.os == "linux" and probe.secret_tool then
		return "linux"
	end
	return nil
end

-- Convention `<context>/<endpoint>`, e.g. cloud/grafana.
function M.itemName(context: string, endpoint: string): string
	return context .. "/" .. endpoint
end

-- ^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$: safe as an argv word and inside the
-- double quotes of a `security -i` line without escaping.
function M.validItem(name: any): boolean
	return type(name) == "string"
		and #name >= 1
		and #name <= M.MAX_ITEM
		and string.match(name, "^[A-Za-z0-9][A-Za-z0-9._/%-]*$") ~= nil
end

local function label(item: string): string
	return "Tern Grafana (" .. item .. ")"
end

function M.lookupPlan(platform: Platform, item: string): Plan
	if platform == "macos" then
		return { argv = { M.SECURITY, "find-generic-password", "-s", M.SERVICE, "-a", item, "-w" } }
	end
	return { argv = { M.SECRET_TOOL, "lookup", "service", M.SERVICE, "account", item } }
end

-- How a finished lookup went: security exits 44 for a missing item;
-- secret-tool exits 1 and prints nothing.
function M.lookupStatus(platform: Platform, status: number, stdout: string): "found" | "missing" | "failed"
	if platform == "macos" then
		if status == 0 then
			return "found"
		end
		return if status == M.MACOS_NOT_FOUND then "missing" else "failed"
	end
	if status == 0 then
		return if stdout ~= "" then "found" else "missing"
	end
	return if status == 1 and stdout == "" then "missing" else "failed"
end

-- Quotes one word for `security -i`, which splits its input line like a
-- shell: inside double quotes a backslash escapes `\` and `"`.
local function quote(word: string): string
	return '"' .. string.gsub(word, '[\\"]', "\\%0") .. '"'
end

-- A secret must be one non-empty line: a line break would end the
-- `security -i` command early, and no token holds control characters.
function M.checkSecret(secret: string): string?
	if secret == "" then
		return "the token is empty"
	elseif string.find(secret, "%c") then
		return "the token contains line breaks or control characters; paste only the token"
	end
	return nil
end

-- Adds or replaces (macOS -U; secret-tool replaces by attributes) the item.
-- The secret travels on stdin only.
function M.storePlan(platform: Platform, item: string, secret: string): (Plan?, string?)
	if not M.validItem(item) then
		return nil, "invalid keychain item name"
	end
	local bad = M.checkSecret(secret)
	if bad then
		return nil, bad
	end
	if platform == "macos" then
		return {
			argv = { M.SECURITY, "-i" },
			stdin = string.format(
				"add-generic-password -U -s %s -a %s -l %s -w %s\n",
				quote(M.SERVICE),
				quote(item),
				quote(label(item)),
				quote(secret)
			),
		},
			nil
	end
	return {
		argv = { M.SECRET_TOOL, "store", "--label=" .. label(item), "service", M.SERVICE, "account", item },
		stdin = secret,
	},
		nil
end

function M.deletePlan(platform: Platform, item: string): Plan
	if platform == "macos" then
		return { argv = { M.SECURITY, "delete-generic-password", "-s", M.SERVICE, "-a", item } }
	end
	return { argv = { M.SECRET_TOOL, "clear", "service", M.SERVICE, "account", item } }
end

-- True when a finished delete left no item behind (a missing item counts).
function M.deleted(platform: Platform, status: number): boolean
	return status == 0 or (platform == "macos" and status == M.MACOS_NOT_FOUND)
end

local PROGRAMS: { [string]: { name: string, fix: string } } = {
	op = {
		name = "the 1Password CLI (op)",
		fix = "install it (https://developer.1password.com/docs/cli/get-started) and turn on its 1Password app integration",
	},
	pass = { name = "pass, the standard Unix password manager", fix = "install pass" },
	gopass = { name = "gopass", fix = "install gopass" },
	vault = { name = "the HashiCorp Vault CLI (vault)", fix = "install vault and log in" },
	bw = { name = "the Bitwarden CLI (bw)", fix = "install bw and unlock it" },
	["secret-tool"] = { name = "secret-tool (libsecret)", fix = "install libsecret-tools" },
}

local SIGNIN: { [string]: string } = {
	op = "run the same `op read ...` in a terminal; 1Password may need `op signin` or an unlocked app",
	vault = "run it in a terminal; `vault login` may be needed",
	bw = "run it in a terminal; `bw unlock` may be needed",
}

local function base(program: string): string
	return string.match(program, "([^/]+)$") or program
end

local function secretWord(field: string?): string
	return if field and string.sub(field, 1, 8) == "password" then "password" else "token"
end

local function keychainName(os: string?): string
	return if os == "linux" then "the Secret Service keyring" else "the macOS keychain"
end

-- First line only, without a "runtime error: " prefix: a host error may carry
-- a Lua stack traceback.
function M.firstLine(text: string?): string
	local line = string.match(text or "", "^%s*([^\r\n]*)") or ""
	line = string.gsub(line, "^runtime error: ", "")
	line = string.gsub(line, "%s+$", "")
	return if line == "" then "unknown error" else line
end

local function keychainOf(detail: Detail): string
	return keychainName(detail.os)
end

function M.explain(kind: Kind, detail: Detail): Explained
	local field = detail.field or "token"
	local word = secretWord(detail.field)
	local program = base(detail.program or "?")
	local known = PROGRAMS[program]
	if kind == "item_missing" then
		local whom = if detail.context then detail.context else "keychain item " .. (detail.item or "?")
		return {
			message = string.format("No %s stored for %s in %s", word, whom, keychainOf(detail)),
			hint = UPDATE,
		}
	elseif kind == "keychain_unavailable" then
		local hint = if detail.os == "linux"
			then "install secret-tool (package libsecret-tools) with a running keyring, or use token_env"
			elseif detail.os == "macos" then "/usr/bin/security is missing; use token_env instead"
			else "use token_env or token_file on this system"
		return { message = string.format("%s needs a system keychain, which is not available here", field), hint = hint }
	elseif kind == "keychain_failed" then
		return {
			message = string.format(
				"Reading keychain item %s failed (exit %s)",
				detail.item or "?",
				tostring(detail.status)
			),
			hint = "unlock " .. keychainOf(detail) .. " and retry, or " .. UPDATE,
		}
	elseif kind == "keychain_timeout" then
		return {
			message = string.format(
				"The keychain did not answer within %d s for item %s",
				detail.seconds or M.TIMEOUT_MS // 1000,
				detail.item or "?"
			),
			hint = "an unlock or access prompt may be waiting; answer it and retry",
		}
	elseif kind == "env_unset" then
		local name = detail.name or "?"
		local hint = if detail.os == "macos"
			then string.format(
				"Tern opened from the Dock does not see shell exports and your login shell does not set it either; "
					.. "run `launchctl setenv %s <token>` and restart Tern, or store the token in the keychain: %s",
				name,
				UPDATE
			)
			else string.format(
				"export it in your login shell profile and restart Tern, or store the token in the keychain: %s",
				UPDATE
			)
		return { message = string.format("Environment variable %s (%s) is not set", name, field), hint = hint }
	elseif kind == "cmd_missing" then
		local what = if known then known.name else "`" .. program .. "`"
		return {
			message = string.format(
				"%s runs `%s`, but %s is not installed or not on Tern's PATH",
				field,
				program,
				what
			),
			hint = (if known then known.fix else "install it or put its absolute path in " .. field)
				.. "; or store the "
				.. word
				.. " in the keychain: "
				.. UPDATE,
		}
	elseif kind == "cmd_start" then
		return {
			message = string.format("%s `%s` could not be started: %s", field, program, M.firstLine(detail.error)),
			hint = "check the program path in " .. field,
		}
	elseif kind == "cmd_failed" then
		return {
			message = string.format("%s `%s` exited with status %s", field, program, tostring(detail.status)),
			hint = SIGNIN[program] or "run it in a terminal to see why",
		}
	elseif kind == "cmd_timeout" then
		return {
			message = string.format(
				"%s `%s` timed out after %d s",
				field,
				program,
				detail.seconds or M.TIMEOUT_MS // 1000
			),
			hint = "an unlock prompt may be waiting; answer it and retry",
		}
	elseif kind == "file_unreadable" then
		return {
			message = string.format(
				"%s %s could not be read: %s",
				field,
				detail.path or "?",
				M.firstLine(detail.error)
			),
			hint = "check that the file exists and is readable by you (chmod 600)",
		}
	elseif kind == "home_unset" then
		return {
			message = string.format("%s %s: cannot expand ~ because HOME is not set", field, detail.path or "?"),
			hint = "use an absolute path",
		}
	elseif kind == "empty" then
		return {
			message = string.format("%s is empty", detail.source or field),
			hint = "it must hold exactly the " .. word,
		}
	end
	return {
		message = string.format("%s has line breaks or control characters", detail.source or field),
		hint = "it must hold only the " .. word .. " on one line",
	}
end

-- One line for views and Carly answers.
function M.line(e: Explained): string
	return e.message .. "; " .. e.hint
end

return M
