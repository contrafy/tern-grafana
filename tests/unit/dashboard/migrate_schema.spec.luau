--!strict
-- Grafana's schema steps that tern-legacy (schema 14) does not exercise,
-- each one a difference a user would see if Tern skipped it: hidden
-- variables shown, old value mappings ignored, series hidden from the plot
-- still in the tooltip, a hidden time axis, links pointing nowhere, panels
-- sharing an id. Decoded JSON is never changed (the panel registry caches by
-- table identity).
local MigrateSchema = require("../../../plugin/lib/dashboard/migrate_schema")
local S = require("./support")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env()

local function migrate(text: string): any
	return MigrateSchema.migrate(json.decode(text), env)
end

describe("dashboard schema migration", function()
	it("hides variables saved with hideVariable/hideLabel before schema 12", function()
		local d = migrate([[{"schemaVersion": 11, "templating": {"list": [
			{"name": "a", "type": "custom", "hideVariable": true, "refresh": true},
			{"name": "b", "hideLabel": true},
			{"name": "c", "type": "constant", "query": "x", "hide": 0}]}}]])
		local list = d.templating.list
		expect({ list[1].hide, list[1].refresh, list[2].hide }).toEqual({ 2, 1, 1 })
		expect({ list[3].type, list[3].current.value }).toEqual({ "textbox", "x" })
	end)

	it("upgrades old value mappings, keeping lists already in the new format", function()
		local d = migrate([[{"schemaVersion": 29, "panels": [
			{"id": 1, "type": "stat", "gridPos": {"x": 0, "y": 0, "w": 6, "h": 3}, "fieldConfig": {"defaults": {
				"thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "red", "value": 1}]},
				"mappings": [{"id": 0, "type": 1, "value": "1", "text": "1"}, {"id": 1, "type": 2, "from": "5", "to": "10", "text": "high"},
					{"id": 2, "type": 1, "value": "null", "text": "N/A"}]}, "overrides": []}},
			{"id": 2, "type": "stat", "gridPos": {"x": 6, "y": 0, "w": 6, "h": 3}, "fieldConfig": {"defaults": {
				"mappings": [{"type": "range", "options": {"from": 1, "to": 2, "result": {"text": "r"}}},
					{"type": "value", "options": {"a": {"text": "A"}}}]}, "overrides": []}}]}]])
		local want: any = {
			{ type = "value", options = { ["1"] = { text = "1", color = "red" } } } :: any,
			{ type = "range", options = { from = 5, to = 10, result = { text = "high" } } } :: any,
			{ type = "special", options = { match = "null", result = { text = "N/A" } } } :: any,
		}
		expect(d.panels[1].fieldConfig.defaults.mappings).toEqual(want)
		expect(d.panels[2].fieldConfig.defaults.mappings[1].type).toBe("range")
	end)

	it(
		"keeps a timeseries' time axis when its value axes are hidden, and hides hidden series from the tooltip",
		function()
			local d = migrate(
				[[{"schemaVersion": 34, "panels": [{"id": 1, "type": "timeseries",
			"gridPos": {"x": 0, "y": 0, "w": 12, "h": 8},
			"fieldConfig": {"defaults": {"custom": {"axisPlacement": "hidden"}}, "overrides": [
				{"matcher": {"id": "byName", "options": "x"}, "properties": [{"id": "custom.hideFrom", "value": {"viz": true, "legend": false}}]}]}}]}]]
			)
			local overrides = d.panels[1].fieldConfig.overrides
			expect(overrides[1].properties[1].value).toEqual({ viz = true, legend = false, tooltip = true })
			expect(overrides[2]).toEqual({
				matcher = { id = "byType", options = "time" },
				properties = { { id = "custom.axisPlacement", value = "auto" } },
			})
		end
	)

	it("merges after labelsToFields, turns text2 into text and rewrites old panel links", function()
		local d = migrate(
			[[{"schemaVersion": 18, "panels": [
			{"id": 1, "type": "table", "gridPos": {"x": 0, "y": 0, "w": 12, "h": 8},
				"transformations": [{"id": "labelsToFields", "options": {}}],
				"links": [{"title": "Node", "dashboard": "Node Exporter Full", "includeVars": true, "params": "a=1", "targetBlank": true}]},
			{"id": 2, "type": "text2", "gridPos": {"x": 12, "y": 0, "w": 12, "h": 8}, "options": {"content": "x", "angular": {}}}]}]]
		)
		expect({ d.panels[1].transformations[1].id, d.panels[1].transformations[2].id }).toEqual({
			"labelsToFields",
			"merge",
		})
		expect(d.panels[1].links).toEqual({
			{ title = "Node", url = "dashboard/db/node-exporter-full?$__all_variables&a=1", targetBlank = true },
		})
		expect(d.panels[2].type).toBe("text")
		expect(d.panels[2].options.angular).toBeNil()
	end)

	it("gives duplicate and missing ids the next free id and sorts panels by gridPos", function()
		local raw = json.decode([[{"schemaVersion": 42, "panels": [
			{"id": 3, "type": "stat", "gridPos": {"x": 12, "y": 0, "w": 12, "h": 3}},
			{"id": 3, "type": "stat", "gridPos": {"x": 0, "y": 0, "w": 12, "h": 3}},
			{"type": "row", "gridPos": {"x": 0, "y": 3, "w": 24, "h": 1}, "collapsed": true, "panels": [{"id": 3, "type": "text"}]},
			{"id": 9, "repeatPanelId": 3, "type": "stat", "gridPos": {"x": 0, "y": 9, "w": 6, "h": 3}}]}]])
		local before = json.encode(raw)
		local d = MigrateSchema.migrate(raw, env)
		local ids = {}
		for i, p in d.panels do
			ids[i] = p.id
		end
		expect(ids).toEqual({ 10, 3, 11 })
		expect(d.panels[3].panels[1].id).toBe(12)
		expect(json.encode(raw)).toBe(before)
		expect(rawequal(d.panels[2], raw.panels[1])).toBe(true)
	end)
end)

return nil
