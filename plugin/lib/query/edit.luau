--!strict
-- One-line text editing for a block-owned `input` node. Tern draws the field
-- but never edits it: every key reaches the block, which keeps the text and
-- the caret. The caret is a 0-based byte offset kept on a UTF-8 boundary;
-- `utf16` converts it for the node's `cursor` prop.

export type Line = { text: string, cursor: number }

local M = {}

local function isCont(text: string, i: number): boolean
	local b = string.byte(text, i)
	return b ~= nil and b >= 0x80 and b < 0xC0
end

-- Byte offset one character left/right of `cursor`.
function M.prevChar(text: string, cursor: number): number
	local c = cursor
	if c <= 0 then
		return 0
	end
	c -= 1
	while c > 0 and isCont(text, c + 1) do
		c -= 1
	end
	return c
end

function M.nextChar(text: string, cursor: number): number
	local c = cursor
	if c >= #text then
		return #text
	end
	c += 1
	while c < #text and isCont(text, c + 1) do
		c += 1
	end
	return c
end

local function isWord(text: string, i: number): boolean
	local ch = string.sub(text, i, i)
	return ch ~= "" and (string.match(ch, "[%w_:]") ~= nil or (string.byte(ch) :: number) >= 0x80)
end

function M.prevWord(text: string, cursor: number): number
	local c = cursor
	while c > 0 and not isWord(text, c) do
		c -= 1
	end
	while c > 0 and isWord(text, c) do
		c -= 1
	end
	return c
end

function M.nextWord(text: string, cursor: number): number
	local c = cursor
	while c < #text and not isWord(text, c + 1) do
		c += 1
	end
	while c < #text and isWord(text, c + 1) do
		c += 1
	end
	return c
end

-- Typed or pasted text: a one-line field, so line breaks and tabs become spaces.
function M.clean(s: string): string
	return (string.gsub(s, "[\r\n\t]", " "))
end

function M.insert(l: Line, s: string): Line
	local t = M.clean(s)
	return {
		text = string.sub(l.text, 1, l.cursor) .. t .. string.sub(l.text, l.cursor + 1),
		cursor = l.cursor + #t,
	}
end

-- Deletes bytes a .. b (0-based, half-open) and puts the caret at a.
local function cut(l: Line, a: number, b: number): Line
	if a >= b then
		return l
	end
	return { text = string.sub(l.text, 1, a) .. string.sub(l.text, b + 1), cursor = a }
end

-- The line after an editing key, nil when the key does not edit.
function M.key(l: Line, key: Key): Line?
	local name = key.name
	local word = key.alt or (key.ctrl and (name == "left" or name == "right" or name == "backspace"))
	if name == "left" then
		return { text = l.text, cursor = if word then M.prevWord(l.text, l.cursor) else M.prevChar(l.text, l.cursor) }
	elseif name == "right" then
		return { text = l.text, cursor = if word then M.nextWord(l.text, l.cursor) else M.nextChar(l.text, l.cursor) }
	elseif name == "home" or (key.ctrl and name == "a") then
		return { text = l.text, cursor = 0 }
	elseif name == "end" or (key.ctrl and name == "e") then
		return { text = l.text, cursor = #l.text }
	elseif name == "backspace" then
		if word then
			return cut(l, M.prevWord(l.text, l.cursor), l.cursor)
		end
		return cut(l, M.prevChar(l.text, l.cursor), l.cursor)
	elseif name == "delete" or (key.ctrl and name == "d") then
		return cut(l, l.cursor, M.nextChar(l.text, l.cursor))
	elseif key.ctrl and name == "w" then
		return cut(l, M.prevWord(l.text, l.cursor), l.cursor)
	elseif key.ctrl and name == "u" then
		return cut(l, 0, l.cursor)
	elseif key.ctrl and name == "k" then
		return cut(l, l.cursor, #l.text)
	elseif name == "paste" then
		return M.insert(l, key.text or "")
	end
	local t = key.text
	if t and t ~= "" and not key.ctrl and not key.meta and not string.find(t, "%c") then
		return M.insert(l, t)
	end
	return nil
end

-- UTF-16 code units in the first `cursor` bytes (Tern's offsets).
function M.utf16(text: string, cursor: number): number
	local units = 0
	local prefix = string.sub(text, 1, cursor)
	local ok = pcall(function()
		for _, cp in utf8.codes(prefix) do
			units += if cp > 0xFFFF then 2 else 1
		end
	end)
	return if ok then units else #prefix
end

return M
