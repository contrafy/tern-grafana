--!strict
-- Test-only JSON codec mimicking `tern.json`, so pure modules can be fed the
-- same tables they get in Tern:
--   * object members whose value is null are dropped;
--   * arrays decode to plain sequences (Tern's array tag is not observable here);
--   * null array items and a top-level null decode to the `null` sentinel
--     (stands in for `tern.json.null`; pass it to modules under test as their
--     injected null);
--   * all numbers decode to Luau numbers.
-- Malformed input raises an error naming the byte offset. `encode` sorts
-- object keys so encoded output is stable across runs.

local null = table.freeze({})

local function decodeError(text: string, pos: number, what: string): never
	local near = string.sub(text, pos, pos + 15)
	error(string.format("json: %s at byte %d near %q", what, pos, near), 0)
end

local function skipWhitespace(text: string, pos: number): number
	local _, last = string.find(text, "^[ \t\r\n]*", pos)
	return (last :: number) + 1
end

local ESCAPES: { [string]: string } = {
	['"'] = '"',
	["\\"] = "\\",
	["/"] = "/",
	b = "\b",
	f = "\f",
	n = "\n",
	r = "\r",
	t = "\t",
}

local function parseString(text: string, pos: number): (string, number)
	local parts = {}
	local i = pos + 1
	while true do
		local chunkEnd = string.find(text, '["\\%c]', i)
		if not chunkEnd then
			return decodeError(text, pos, "unterminated string")
		end
		table.insert(parts, string.sub(text, i, chunkEnd - 1))
		local c = string.sub(text, chunkEnd, chunkEnd)
		if c == '"' then
			return table.concat(parts), chunkEnd + 1
		elseif c == "\\" then
			local e = string.sub(text, chunkEnd + 1, chunkEnd + 1)
			if e == "u" then
				local hex = string.match(text, "^%x%x%x%x", chunkEnd + 2)
				if not hex then
					return decodeError(text, chunkEnd, "invalid unicode escape")
				end
				local code = tonumber(hex, 16) :: number
				i = chunkEnd + 6
				if code >= 0xD800 and code <= 0xDBFF then
					local low = string.match(text, "^\\u(%x%x%x%x)", i)
					local lowCode = if low then tonumber(low, 16) :: number else 0
					if lowCode < 0xDC00 or lowCode > 0xDFFF then
						decodeError(text, chunkEnd, "unpaired surrogate")
					end
					code = 0x10000 + (code - 0xD800) * 0x400 + (lowCode - 0xDC00)
					i += 6
				elseif code >= 0xDC00 and code <= 0xDFFF then
					decodeError(text, chunkEnd, "unpaired surrogate")
				end
				table.insert(parts, utf8.char(code))
			else
				local replacement = ESCAPES[e]
				if not replacement then
					return decodeError(text, chunkEnd, "invalid escape")
				end
				table.insert(parts, replacement)
				i = chunkEnd + 2
			end
		else
			decodeError(text, chunkEnd, "control character in string")
		end
	end
end

local parseValue: (text: string, pos: number) -> (any, number)

local function parseArray(text: string, pos: number): ({ any }, number)
	local result = {}
	local i = skipWhitespace(text, pos + 1)
	if string.sub(text, i, i) == "]" then
		return result, i + 1
	end
	while true do
		local value
		value, i = parseValue(text, i)
		table.insert(result, value)
		i = skipWhitespace(text, i)
		local c = string.sub(text, i, i)
		if c == "]" then
			return result, i + 1
		elseif c ~= "," then
			decodeError(text, i, "expected ',' or ']'")
		end
		i = skipWhitespace(text, i + 1)
	end
end

local function parseObject(text: string, pos: number): ({ [string]: any }, number)
	local result = {}
	local i = skipWhitespace(text, pos + 1)
	if string.sub(text, i, i) == "}" then
		return result, i + 1
	end
	while true do
		if string.sub(text, i, i) ~= '"' then
			decodeError(text, i, "expected object key")
		end
		local key
		key, i = parseString(text, i)
		i = skipWhitespace(text, i)
		if string.sub(text, i, i) ~= ":" then
			decodeError(text, i, "expected ':'")
		end
		local value
		value, i = parseValue(text, skipWhitespace(text, i + 1))
		if value ~= null then
			result[key] = value
		end
		i = skipWhitespace(text, i)
		local c = string.sub(text, i, i)
		if c == "}" then
			return result, i + 1
		elseif c ~= "," then
			decodeError(text, i, "expected ',' or '}'")
		end
		i = skipWhitespace(text, i + 1)
	end
end

local LITERALS: { [string]: any } = { ["true"] = true, ["false"] = false, ["null"] = null }

function parseValue(text: string, pos: number): (any, number)
	local c = string.sub(text, pos, pos)
	if c == "{" then
		return parseObject(text, pos)
	elseif c == "[" then
		return parseArray(text, pos)
	elseif c == '"' then
		return parseString(text, pos)
	end
	local number = string.match(text, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
	if number and string.match(number, "^-?0%d") == nil then
		local value = tonumber(number)
		if value then
			return value, pos + #number
		end
	end
	for word, value in LITERALS do
		if string.sub(text, pos, pos + #word - 1) == word then
			return value, pos + #word
		end
	end
	return decodeError(text, pos, "unexpected token")
end

local function decode(text: string): any
	local value, pos = parseValue(text, skipWhitespace(text, 1))
	pos = skipWhitespace(text, pos)
	if pos <= #text then
		decodeError(text, pos, "trailing data")
	end
	return value
end

local function encodeString(s: string): string
	local escaped = string.gsub(s, '[%c"\\]', function(c: string): string
		if c == '"' then
			return '\\"'
		elseif c == "\\" then
			return "\\\\"
		elseif c == "\n" then
			return "\\n"
		elseif c == "\r" then
			return "\\r"
		elseif c == "\t" then
			return "\\t"
		end
		return string.format("\\u%04x", string.byte(c))
	end)
	return '"' .. escaped .. '"'
end

local function isArray(t: { [any]: any }): boolean
	local n = 0
	for k in t do
		if type(k) ~= "number" then
			return false
		end
		n += 1
	end
	return n > 0 and n == #t
end

local function encode(value: any): string
	if value == nil or value == null then
		return "null"
	end
	local kind = type(value)
	if kind == "boolean" then
		return if value then "true" else "false"
	elseif kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			error("json: cannot encode non-finite number", 0)
		end
		if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
			return string.format("%d", value)
		end
		return string.format("%.17g", value)
	elseif kind == "string" then
		return encodeString(value)
	elseif kind == "table" then
		if isArray(value) then
			local parts = table.create(#value)
			for i, v in value do
				parts[i] = encode(v)
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local keys: { string } = {}
		for k in value do
			if type(k) ~= "string" then
				error("json: object keys must be strings", 0)
			end
			table.insert(keys, k)
		end
		table.sort(keys)
		local parts = table.create(#keys)
		for i, k in keys do
			parts[i] = encodeString(k) .. ":" .. encode(value[k])
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	error("json: cannot encode a " .. kind, 0)
end

return {
	decode = decode,
	encode = encode,
	null = null,
}
