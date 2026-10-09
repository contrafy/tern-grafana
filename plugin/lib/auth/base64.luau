--!strict
-- RFC 4648 base64 (standard alphabet, padded). Pure Luau so basic auth headers
-- can be built and tested without the `tern` global.

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local CHARS: { string } = table.create(64)
for i = 1, 64 do
	CHARS[i] = string.sub(ALPHABET, i, i)
end

local M = {}

function M.encode(bytes: string): string
	local n = #bytes
	local out: { string } = table.create(math.ceil(n / 3) * 4)
	for i = 1, n, 3 do
		local a, b, c = string.byte(bytes, i, i + 2)
		local word = bit32.lshift(a, 16) + bit32.lshift(b or 0, 8) + (c or 0)
		table.insert(out, CHARS[bit32.extract(word, 18, 6) + 1])
		table.insert(out, CHARS[bit32.extract(word, 12, 6) + 1])
		table.insert(out, if b then CHARS[bit32.extract(word, 6, 6) + 1] else "=")
		table.insert(out, if c then CHARS[bit32.extract(word, 0, 6) + 1] else "=")
	end
	return table.concat(out)
end

return M
