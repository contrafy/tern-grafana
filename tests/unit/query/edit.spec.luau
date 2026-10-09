--!strict
-- Tern never edits a block's input field: these keys are the whole editor.
-- The caret must stay on character boundaries (a split UTF-8 sequence would
-- corrupt the query) and convert to the UTF-16 offsets Tern draws with.
-- `|` marks the caret in the strings below.
local Edit = require("../../../plugin/lib/query/edit")
local S = require("./support")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function press(marked: string, name: string, txt: string?, mods: { [string]: boolean }?): string
	local at = string.find(marked, "|", 1, true) :: number
	local text = string.sub(marked, 1, at - 1) .. string.sub(marked, at + 1)
	local l = Edit.key({ text = text, cursor = at - 1 }, S.key(name, txt, mods))
	if l == nil then
		return "unhandled"
	end
	return string.sub(l.text, 1, l.cursor) .. "|" .. string.sub(l.text, l.cursor + 1)
end

describe("Edit.key", function()
	it("inserts typed text at the caret", function()
		expect(press("up|", "{")).toBe("up{|")
		expect(press("r|te", "a")).toBe("ra|te")
		expect(press("a|", "space", " ")).toBe("a |")
	end)

	it("pastes on one line", function()
		expect(press("|", "paste", "sum(\n  rate(x[5m])\n)")).toBe("sum(   rate(x[5m]) )|")
	end)

	it("deletes around the caret", function()
		expect(press("rate|", "backspace")).toBe("rat|")
		expect(press("|rate", "backspace")).toBe("|rate")
		expect(press("|rate", "delete")).toBe("|ate")
		expect(press("rate|", "delete")).toBe("rate|")
	end)

	it("moves by character, word and line", function()
		expect(press("a|b", "left")).toBe("|ab")
		expect(press("a|b", "right")).toBe("ab|")
		expect(press("sum(rate(x))|", "left", nil, { alt = true })).toBe("sum(rate(|x))")
		expect(press("|sum(rate(x))", "right", nil, { alt = true })).toBe("sum|(rate(x))")
		expect(press("ab|c", "a", "a", { ctrl = true })).toBe("|abc")
		expect(press("|abc", "e", "e", { ctrl = true })).toBe("abc|")
		expect(press("a|bc", "end")).toBe("abc|")
	end)

	it("kills words and line halves", function()
		expect(press("rate(node_cpu|", "w", "w", { ctrl = true })).toBe("rate(|")
		expect(press("rate(|node_cpu", "u", "u", { ctrl = true })).toBe("|node_cpu")
		expect(press("rate(|node_cpu", "k", "k", { ctrl = true })).toBe("rate(|")
		expect(press("a b|", "backspace", nil, { alt = true })).toBe("a |")
	end)

	it("leaves command keys alone", function()
		expect(press("x|", "r", "r", { ctrl = true })).toBe("unhandled")
		expect(press("x|", "c", "c", { meta = true })).toBe("unhandled")
		expect(press("x|", "f5", nil)).toBe("unhandled")
	end)

	it("steps over multi-byte characters as one", function()
		expect(press('x{a="é|"}', "left")).toBe('x{a="|é"}')
		expect(press('x{a="|é"}', "right")).toBe('x{a="é|"}')
		expect(press('x{a="é|"}', "backspace")).toBe('x{a="|"}')
	end)
end)

describe("Edit.utf16", function()
	it("counts UTF-16 units before the caret", function()
		expect(Edit.utf16("abc", 2)).toBe(2)
		expect(Edit.utf16("é", 2)).toBe(1)
		-- U+1F600 is four UTF-8 bytes and a surrogate pair in UTF-16.
		expect(Edit.utf16("a" .. utf8.char(0x1F600) .. "b", 5)).toBe(3)
	end)
end)

return nil
