--!strict
-- Reads a small file (the config, a token or password file) through the
-- given reader (tern.fs.read) with a size cap that also holds for symlinks.
--
-- tern.fs.read with max_bytes refuses a symlink, yet a symlinked config
-- (stow, chezmoi, home-manager) or secret (sops-nix and agenix paths under
-- /run/secrets) is a normal setup. So a bounded read is tried first (a
-- regular file is never read past the cap), and when it is refused the file
-- is read without the bound and the cap enforced on the text.

local M = {}

export type Reader = (path: string, max_bytes: number?) -> string

-- (text, err, linked): the file's text, or why it cannot be used. `linked`
-- is true when the bounded read was refused but the plain one worked: the
-- path is not a regular file (a symlink), so replacing it with a rename
-- would cut the link.
function M.read(read: Reader, path: string, max_bytes: number): (string?, string?, boolean)
	local ok, text = pcall(read, path, max_bytes)
	if ok and type(text) == "string" then
		return text, nil, false
	end
	local okAny, anyText = pcall(read, path)
	if not okAny or type(anyText) ~= "string" then
		return nil, tostring(anyText), false
	end
	if #anyText > max_bytes then
		return nil, string.format("the file is larger than %d bytes", max_bytes), false
	end
	return anyText, nil, true
end

return M
