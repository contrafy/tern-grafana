--!strict
-- The logs panel over Loki frames, following Grafana's log row model:
-- public/app/features/logs/logsModel.ts (level from a level field, then
-- the detected_level / level labels, then getLogLevel on the line;
-- dedupLogRows), public/app/features/logs/utils.ts (getLogLevel,
-- getLogLevelFromKey), packages/grafana-data/src/types/logs.ts (LogLevel).
local t = require("../../lib/test")
local Frame = require("../../../plugin/lib/frame/types")
local Logs = require("../../../plugin/lib/panels/logs")
local S = require("./support")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env

-- detected_level counts per capture (Loki labels; `warn` is LogLevel.warning).
local LEVELS = {
	["11.6.16"] = { info = 26, debug = 11, warning = 11, error = 2 },
	["12.4.12"] = { info = 27, debug = 10, warning = 10, error = 3 },
}

-- The same rows read from the lines alone: the access-log lines
-- (`GET /checkout status=200 ...`) carry no level word, so they are
-- unknown, which is why labels are consulted first.
local FROM_LINES = {
	["11.6.16"] = { info = 13, unknown = 13, debug = 11, warning = 11, error = 2 },
	["12.4.12"] = { info = 13, unknown = 14, debug = 10, warning = 10, error = 3 },
}

local function tally(rows: { Logs.Row }): { [string]: number }
	local out: { [string]: number } = {}
	for _, r in rows do
		out[r.level] = (out[r.level] or 0) + 1
	end
	return out
end

local function withoutLabels(frames: { Frame.Frame }): { Frame.Frame }
	local out: { Frame.Frame } = {}
	for _, f in frames do
		local copy = table.clone(f)
		copy.fields = {}
		for _, field in f.fields do
			if field.name ~= "labels" then
				table.insert(copy.fields, field)
			end
		end
		table.insert(out, copy)
	end
	return out
end

for _, version in S.VERSIONS do
	describe("logs on tern-panels, Grafana " .. version, function()
		-- Panel 12 "Generated logs": sortOrder Descending, dedup none.
		it("takes each row's level from the detected_level label", function()
			local rows = Logs.rows(S.panel(version, 12), S.frames(version, "loki_logs"), env)
			expect(#rows).toBe(50)
			expect(tally(rows)).toEqual(LEVELS[version])
		end)

		-- Without labels, getLogLevel finds the level word in logfmt and
		-- JSON lines alike ({"level":"warn"} -> warning).
		it("falls back to the level word in the line", function()
			local rows = Logs.rows(S.panel(version, 12), withoutLabels(S.frames(version, "loki_logs")), env)
			expect(tally(rows)).toEqual(FROM_LINES[version])
		end)

		it("sorts newest first, or oldest first with sortOrder Ascending", function()
			local panel = S.clone(S.panel(version, 12))
			local rows = Logs.rows(panel, S.frames(version, "loki_logs"), env)
			for i = 2, #rows do
				assert((rows[i - 1].time_ms :: number) >= (rows[i].time_ms :: number), "descending")
			end
			panel.options.sortOrder = "Ascending"
			local asc = Logs.rows(panel, S.frames(version, "loki_logs"), env)
			for i = 2, #asc do
				assert((asc[i - 1].time_ms :: number) <= (asc[i].time_ms :: number), "ascending")
			end
		end)

		it("finds the labels shared by every row", function()
			local rows = Logs.rows(S.panel(version, 12), S.frames(version, "loki_logs"), env)
			expect(Logs.commonLabels(rows)).toEqual({ env = "dev", job = "loggen" })
		end)

		-- showLabels shows what differs between rows; common labels stay
		-- hidden unless showCommonLabels.
		it("renders time, a level tag in its tone, unique labels and the line", function()
			local panel = S.clone(S.panel(version, 12))
			local plain: any = Logs.view(panel, S.frames(version, "loki_logs"), env, { key = "l" })
			local first = plain.c[1]
			expect(first.p.wrap).toBe("word")
			expect(string.match(first.p.spans[1].t, "^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d%.%d%d%d $") ~= nil).toBe(true)
			local tag = first.p.spans[2]
			local rows = Logs.rows(panel, S.frames(version, "loki_logs"), env)
			expect(tag.s).toBe(Logs.tone(rows[1].level))
			expect((string.find(S.text(first), "job=", 1, true))).toBeNil()
			local labeled: any =
				Logs.view(panel, S.frames(version, "loki_logs"), env, { key = "l", show_labels = true })
			local text = S.text(labeled.c[1])
			expect(string.find(text, "app=checkout", 1, true) ~= nil).toBe(true)
			expect((string.find(text, "job=loggen", 1, true))).toBeNil()
			panel.options.showCommonLabels = true
			local all: any = Logs.view(panel, S.frames(version, "loki_logs"), env, { key = "l", show_labels = true })
			expect(string.find(S.text(all.c[1]), "job=loggen", 1, true) ~= nil).toBe(true)
		end)
	end)
end

describe("logs level detection (logs/utils.ts)", function()
	it("reads level names and syslog numbers (getLogLevelFromKey)", function()
		expect(Logs.levelFromKey("WARN")).toBe("warning")
		expect(Logs.levelFromKey("eror")).toBe("error")
		expect(Logs.levelFromKey("emerg")).toBe("critical")
		expect(Logs.levelFromKey("notice")).toBe("info")
		expect(Logs.levelFromKey("3")).toBe("error")
		expect(Logs.levelFromKey(7)).toBe("debug")
		expect(Logs.levelFromKey("1abc")).toBe("unknown")
		expect(Logs.levelFromKey("verbose")).toBe("unknown")
	end)

	-- getLogLevel: whole words only, the earliest one in the line wins.
	it("finds the earliest level word in a line", function()
		expect(Logs.level("ERROR while handling warn event")).toBe("error")
		expect(Logs.level("handled warn event; no error")).toBe("warning")
		expect(Logs.level("terror and debugging")).toBe("unknown")
		expect(Logs.level('ts=1 lvl=DBUG msg="x"')).toBe("debug")
		expect(Logs.level("")).toBe("unknown")
	end)

	-- LogLevelColor read as tones.
	it("tones levels like Grafana's level colors", function()
		expect(Logs.tone("critical")).toBe("accent")
		expect(Logs.tone("error")).toBe("error")
		expect(Logs.tone("warning")).toBe("warning")
		expect(Logs.tone("info")).toBe("success")
		expect(Logs.tone("debug")).toBe("info")
		expect(Logs.tone("unknown")).toBe("muted")
	end)
end)

describe("logs dedup (logsModel.ts dedupLogRows)", function()
	local function row(line: string): Logs.Row
		return { line = line, level = "info", labels = {}, duplicates = 0 }
	end
	local lines = {
		row('level=debug msg="cart loaded" items=5'),
		row('level=debug msg="cart loaded" items=4'),
		row('level=debug msg="cart loaded" items=4'),
		row('level=info msg="order placed" order_id=465'),
		row("2026-10-09T20:31:48.123Z started"),
		row("2026-10-09T20:31:49.456Z started"),
	}

	it("folds exact repeats, ignoring ISO timestamps", function()
		local out = Logs.dedup(lines, "exact")
		expect(#out).toBe(4)
		expect(out[2].duplicates).toBe(1)
		expect(out[4].duplicates).toBe(1)
	end)

	it("folds lines that differ only in digits with numbers", function()
		local out = Logs.dedup(lines, "numbers")
		expect(#out).toBe(3)
		expect(out[1].duplicates).toBe(2)
	end)

	-- `level=debug msg="cart loaded" items=5` and `level=info msg="order
	-- placed" order_id=465` share the skeleton `= =" " =`.
	it("folds lines with the same punctuation skeleton with signature", function()
		local out = Logs.dedup(lines, "signature")
		expect(#out).toBe(2)
		expect(out[1].duplicates).toBe(3)
		expect(out[2].duplicates).toBe(1)
	end)

	it("keeps every row with none", function()
		expect(#Logs.dedup(lines, "none")).toBe(6)
	end)
end)

return nil
