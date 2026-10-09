--!strict
-- Fixture access for specs. Standalone luau cannot read files, so everything under tests/fixtures
-- (responses captured from the dev stack by scripts/fixtures/capture.sh, plus MANIFEST.tsv) is
-- embedded into tests/fixtures/generated.luau by scripts/fixtures/embed.sh (`make fixtures`).
-- Paths are relative to tests/fixtures, e.g. "prometheus/3.15.0/query_vector.json" or
-- "grafana/12.4.12/render_d_solo.png". Reads are byte-exact: binary captures are embedded as
-- base64 and decoded here.

local generated: { files: { [string]: string }, base64: { [string]: string } } = require("../fixtures/generated")

local M = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local SEXTET: { [number]: number } = {}
for i = 1, #ALPHABET do
	SEXTET[string.byte(ALPHABET, i)] = i - 1
end

local function decodeBase64(text: string): string
	local n = #text
	local pad = 0
	if n > 0 and string.byte(text, n) == 61 then
		pad += 1
	end
	if n > 1 and string.byte(text, n - 1) == 61 then
		pad += 1
	end
	local out = buffer.create(n // 4 * 3 - pad)
	local o = 0
	for i = 1, n - pad, 4 do
		local a = SEXTET[string.byte(text, i)] or 0
		local b = SEXTET[string.byte(text, i + 1)] or 0
		local c = SEXTET[string.byte(text, i + 2) or 61] or 0
		local d = SEXTET[string.byte(text, i + 3) or 61] or 0
		local v = bit32.bor(bit32.lshift(a, 18), bit32.lshift(b, 12), bit32.lshift(c, 6), d)
		for shift = 16, 0, -8 do
			if o < buffer.len(out) then
				buffer.writeu8(out, o, bit32.band(bit32.rshift(v, shift), 0xff))
				o += 1
			end
		end
	end
	return buffer.tostring(out)
end

local decoded: { [string]: string } = {}

function M.has(path: string): boolean
	return generated.files[path] ~= nil or generated.base64[path] ~= nil
end

function M.read(path: string): string
	local text = generated.files[path]
	if text ~= nil then
		return text
	end
	local cached = decoded[path]
	if cached ~= nil then
		return cached
	end
	local encoded = generated.base64[path]
	if encoded == nil then
		error(string.format("fixture %q not embedded; run `make fixtures`", path), 2)
	end
	local bytes = decodeBase64(encoded)
	decoded[path] = bytes
	return bytes
end

-- Sorted fixture paths starting with `prefix` ("" lists everything).
function M.list(prefix: string): { string }
	local out: { string } = {}
	for _, set in { generated.files, generated.base64 } do
		for path in set do
			if string.sub(path, 1, #prefix) == prefix then
				table.insert(out, path)
			end
		end
	end
	table.sort(out)
	return out
end

return M
