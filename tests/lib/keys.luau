--!strict
-- Key events as Tern delivers them to a block's `key` handler. One set of
-- builders for every spec, so a change to the KeyEvent shape is made once.

local M = {}

-- A key by name; a one-character name also types itself unless `text` says
-- otherwise. `mods` sets ctrl/alt/shift/meta.
function M.key(name: string, text: string?, mods: { [string]: boolean }?): any
	local m: { [string]: boolean } = mods or {}
	local t = text
	if t == nil and #name == 1 then
		t = name
	end
	return {
		name = name,
		text = t,
		ctrl = m.ctrl == true,
		alt = m.alt == true,
		shift = m.shift == true,
		meta = m.meta == true,
	}
end

-- A typed character, shifted when it is an upper-case letter.
function M.char(c: string): any
	return M.key(c, c, { shift = string.upper(c) == c and string.lower(c) ~= c })
end

-- A typed `text`, or with `name` a named key (enter, escape, up, ...) that
-- types nothing. Unshifted, as the block specs that use it expect.
function M.press(text: string, name: string?): any
	return {
		name = name or text,
		text = if name then nil else text,
		ctrl = false,
		alt = false,
		shift = false,
		meta = false,
	}
end

return M
