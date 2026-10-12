--!strict
-- Trace and span ids as lowercase hex of their full width. Tempo's
-- /api/traces answers in protobuf JSON, where id bytes are base64
-- ("AILJ8cK9qFDYeOUnYswIFg=="); the OTLP JSON spec, Grafana's data frames and
-- TraceQL search use hex, and Tempo drops a trace id's leading zeros
-- ("82c9f1..." for "0082c9f1..."). Standard-size ids in base64 always carry
-- `=` padding (8 and 16 bytes), so a string of only hex digits is hex.

local M = {}

M.TRACE_HEX = 32
M.SPAN_HEX = 16

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local VALUE: { [string]: number } = {}
for i = 1, #ALPHABET do
	VALUE[string.sub(ALPHABET, i, i)] = i - 1
end
-- URL-safe alphabet too.
VALUE["-"] = 62
VALUE["_"] = 63

-- Hex of base64 bytes; nil when `s` is not base64.
function M.base64Hex(s: string): string?
	local body = string.gsub(s, "=+$", "")
	if body == "" or #body % 4 == 1 then
		return nil
	end
	local out: { string } = {}
	local acc, bits = 0, 0
	for i = 1, #body do
		local v = VALUE[string.sub(body, i, i)]
		if v == nil then
			return nil
		end
		acc = bit32.bor(bit32.lshift(acc, 6), v)
		bits += 6
		if bits >= 8 then
			bits -= 8
			table.insert(out, string.format("%02x", bit32.band(bit32.rshift(acc, bits), 0xff)))
			acc = bit32.band(acc, bit32.lshift(1, bits) - 1)
		end
	end
	return table.concat(out)
end

local function pad(hex: string, width: number): string?
	if #hex > width then
		return nil
	end
	return string.rep("0", width - #hex) .. string.lower(hex)
end

-- `raw` (hex or base64) as hex of `width` digits; nil when empty, malformed
-- or all zeros (OTLP's "no parent").
function M.normalize(raw: any, width: number): string?
	if type(raw) ~= "string" or raw == "" then
		return nil
	end
	local hex: string?
	if string.match(raw, "^%x+$") then
		hex = raw
	else
		hex = M.base64Hex(raw)
	end
	if hex == nil then
		return nil
	end
	local out = pad(hex, width)
	if out == nil or not string.find(out, "[^0]") then
		return nil
	end
	return out
end

function M.trace(raw: any): string?
	return M.normalize(raw, M.TRACE_HEX)
end

function M.span(raw: any): string?
	return M.normalize(raw, M.SPAN_HEX)
end

-- The short form Tempo and Grafana print (leading zeros dropped).
function M.short(id: string): string
	return (string.gsub(id, "^0+", ""))
end

return M
