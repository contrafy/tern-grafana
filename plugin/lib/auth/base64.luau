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

local SEXTET: { [number]: number } = {}
for i = 1, 64 do
	SEXTET[string.byte(ALPHABET, i)] = i - 1
end
-- base64url too, as browsers decode data: URLs leniently.
SEXTET[string.byte("-")] = 62
SEXTET[string.byte("_")] = 63

-- The bytes of `text` (whitespace and padding ignored), nil when it holds a
-- character outside the alphabet.
function M.decode(text: string): string?
	local clean = string.gsub(text, "[%s=]", "")
	local out: { string } = table.create(#clean // 4 * 3 + 3)
	local word, bits = 0, 0
	for i = 1, #clean do
		local v = SEXTET[string.byte(clean, i)]
		if v == nil then
			return nil
		end
		word = bit32.band(bit32.lshift(word, 6) + v, 0xffffff)
		bits += 6
		if bits >= 8 then
			bits -= 8
			table.insert(out, string.char(bit32.extract(word, bits, 8)))
		end
	end
	return table.concat(out)
end

return M
