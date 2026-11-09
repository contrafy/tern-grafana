--!strict
-- When and how the settings block may replace the config file, decided here
-- and executed step by step by settings_host.luau. A write goes ahead only
-- when the target is the config path, it is not a symlink, and the file on
-- disk is still the text the edit was computed from (same Json.hash, or still
-- missing). Then, in this order: create the directory, copy the current text
-- to `<config>.bak`, write the new text to a hidden temporary file in the same
-- directory, rename it over the config with `mv`, and read the config back.

local Json = require("./json")

local M = {}

-- The config_write effect (State.WriteEffect).
export type Request = { path: string, text: string, base_hash: string? }

-- The config file as the host read it; `error` when it could not be read,
-- `linked` when the path is a symlink.
export type Disk = { exists: boolean, text: string?, error: string?, linked: boolean }

-- Why nothing was written: an error, or `conflict` when the file changed
-- since the block loaded it.
export type Refusal = { error: string?, conflict: boolean? }

export type Plan = {
	target: string,
	-- Created first.
	dir: string,
	-- Then written with `current`, when the file exists.
	backup: string?,
	current: string?,
	-- Then written with `text`, and renamed over `target` by `argv`.
	tmp: string,
	text: string,
	argv: { string },
}

-- The steps for `req`, or why it must not run. `read` reads the target and
-- `nonce` names the temporary file; neither runs unless the path checks pass.
function M.plan(req: Request, configPath: string?, read: (path: string) -> Disk, nonce: () -> string): (Plan?, Refusal?)
	local target = req.path
	if target ~= configPath then
		return nil, { error = "refusing to write outside the config path" }
	end
	local dir = string.match(target, "^(.*)/[^/]+$")
	if dir == nil or dir == "" then
		return nil, { error = "the config path has no directory" }
	end
	local disk = read(target)
	if disk.error then
		return nil, { error = disk.error }
	end
	if disk.linked then
		-- The rename would replace the link with a plain file and detach the
		-- config from whatever manages it (stow, home-manager).
		return nil, { error = target .. " is a symlink; edit the file it points to instead" }
	end
	local current = disk.text
	local same = if req.base_hash == nil
		then not disk.exists
		else current ~= nil and Json.hash(current) == req.base_hash
	if not same then
		return nil, { conflict = true }
	end
	local tmp = string.format("%s/.%s.tern-grafana-%s.tmp", dir, string.match(target, "([^/]+)$") or "config", nonce())
	return {
		target = target,
		dir = dir,
		backup = if current ~= nil then target .. ".bak" else nil,
		current = current,
		tmp = tmp,
		text = req.text,
		argv = { "mv", "-f", "--", tmp, target },
	},
		nil
end

-- The error for a rename that exited with a non-zero status.
function M.renameFailed(stderr: string): string
	return "mv failed: " .. (string.match(stderr, "^[^\n]*") or "")
end

-- The error when the config read back after the rename is not the new text.
function M.verify(plan: Plan, written: string?): string?
	if written ~= plan.text then
		return "the file does not hold the new text after the rename; check " .. plan.target
	end
	return nil
end

return M
