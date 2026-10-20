--!strict
-- Blocks pause auto-refresh while their tab is in the background, from a kv
-- record the window writes. A mistake must cost a refresh, never a stale view
-- on screen: only a pane the record knows and does not show is hidden.
local Visibility = require("../../plugin/lib/visibility")
local t = require("../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

-- A split node of Tern's TabTree: direction plus children [1] and [2].
local function split(dir: string, a: any, b: any): any
	local node: any = { split = dir }
	node[1], node[2] = a, b
	return node
end

-- Tern's TabLayout: a split tree with panes at the leaves.
local SPLIT: any = {
	root = split("right", { pane = 5 }, split("down", { pane = 7 }, { pane = 9 })),
	floats = { { pane = 11, over = 7, corner = "br" } },
	zoomed = false,
	focus = 7,
}

describe("Visibility.visible", function()
	it("lists every tiled leaf and floating block of the active tab", function()
		expect(Visibility.visible(SPLIT :: any, 7)).toEqual({ 5, 7, 9, 11 })
	end)

	it("shows only the focused block of a zoomed tab, and its floats", function()
		local zoomed = table.clone(SPLIT)
		zoomed.zoomed = true
		expect(Visibility.visible(zoomed :: any, 7)).toEqual({ 7, 11 })
	end)

	it("still counts the focused pane without a layout", function()
		expect(Visibility.visible(nil, 3)).toEqual({ 3 })
		expect(Visibility.visible(nil, nil)).toEqual({})
	end)
end)

describe("Visibility.hidden", function()
	local record = Visibility.record({ 9, 5, 13, 7, 5 }, { 7, 5 })

	it("keeps the record sorted and free of duplicates (the window compares signatures)", function()
		expect(record).toEqual({ known = { 5, 7, 9, 13 }, visible = { 5, 7 } })
		expect(Visibility.signature(record)).toBe(Visibility.signature(Visibility.record({ 13, 9, 7, 5 }, { 5, 7 })))
		expect(Visibility.signature(record) == Visibility.signature(Visibility.record({ 5, 7, 9, 13 }, { 5 }))).toBe(
			false
		)
	end)

	it("hides a known pane the active tab does not show", function()
		expect(Visibility.hidden(record, 13)).toBe(true)
		expect(Visibility.hidden(record, 7)).toBe(false)
	end)

	it("treats unknown panes, a missing record and malformed values as visible", function()
		-- Opened after the record was written, or shown by another window.
		expect(Visibility.hidden(record, 21)).toBe(false)
		expect(Visibility.hidden(nil, 13)).toBe(false)
		expect(Visibility.hidden("garbage", 13)).toBe(false)
		expect(Visibility.hidden({ known = 13 }, 13)).toBe(false)
		expect(Visibility.hidden(record, nil)).toBe(false)
	end)

	it("reads the record through Env for the block's own pane", function()
		local env: any = {
			pane = 13,
			kv_get = function(key: string): any
				return if key == Visibility.KEY then record else nil
			end,
		}
		expect(Visibility.isHidden(env)).toBe(true)
		env.pane = 5
		expect(Visibility.isHidden(env)).toBe(false)
		-- Specs and code paths without kv or a pane never pause.
		expect(Visibility.isHidden({ pane = 13 } :: any)).toBe(false)
	end)
end)

return nil
