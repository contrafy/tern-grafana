--!strict
-- token_env fallback: Tern started from the Dock or Finder does not inherit
-- variables exported in shell startup files, so when the daemon lacks the
-- variable the host asks the user's login shell for that one variable.
--
-- The shell runs interactive and login (-l -i) so ~/.zprofile, ~/.zshrc,
-- ~/.bash_profile and friends all load. Startup files may print anything, so
-- the value is printed between markers. The markers are written split in the
-- script ("A""B"), so a shell that echoes its input never prints them whole.
-- Only the variable's name is in argv, never its value.

local M = {}

M.TIMEOUT_MS = 5000
M.BEGIN = "__TERN_GRAFANA_ENV_BEGIN__"
M.END = "__TERN_GRAFANA_ENV_END__"

export type Plan = { argv: { string }, stdin: string, timeout_ms: number }

function M.validName(name: string): boolean
	return string.match(name, "^[%a_][%w_]*$") ~= nil
end

-- The user's shell: $SHELL when it is an absolute path, else the platform's
-- default login shell.
function M.shell(shellVar: string?, os: string?): string
	if shellVar and string.sub(shellVar, 1, 1) == "/" and not string.find(shellVar, "%s") then
		return shellVar
	end
	return if os == "macos" then "/bin/zsh" else "/bin/sh"
end

local function split(marker: string): string
	local cut = #marker // 2
	return '"' .. string.sub(marker, 1, cut) .. '""' .. string.sub(marker, cut + 1) .. '"'
end

function M.plan(shell: string, name: string): Plan?
	if not M.validName(name) then
		return nil
	end
	local script = string.format("printf '%%s%%s%%s' %s \"$%s\" %s", split(M.BEGIN), name, split(M.END))
	-- Empty stdin: a startup file that reads input gets EOF instead of hanging.
	return { argv = { shell, "-l", "-i", "-c", script }, stdin = "", timeout_ms = M.TIMEOUT_MS }
end

-- The value between the markers ("" when unset or empty), or nil when the
-- markers are missing (the shell failed before printing them).
function M.parse(stdout: string): string?
	local _, beginEnd = string.find(stdout, M.BEGIN, 1, true)
	if beginEnd == nil then
		return nil
	end
	local endStart = string.find(stdout, M.END, beginEnd + 1, true)
	if endStart == nil then
		return nil
	end
	return string.sub(stdout, beginEnd + 1, endStart - 1)
end

return M
