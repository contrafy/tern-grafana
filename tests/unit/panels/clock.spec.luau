--!strict
-- grafana-clock-panel 2.1.8 (github.com/grafana/clock-panel at v2.1.8:
-- src/components/CalculateClockOptions.ts, RenderTime.tsx, RenderZone.tsx,
-- src/options.ts, src/external/moment-duration-format.js). Expected strings
-- were produced by the plugin's own code paths under moment 2.29.4,
-- moment-timezone 0.5.48 and the bundled moment-duration-format, so the
-- clock reads the same in Tern as in Grafana.
local t = require("../../lib/test")
local S = require("./support")
local Clock = require("../../../plugin/lib/panels/clock")
local Frame = require("../../../plugin/lib/frame/types")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env
-- 2026-10-09T20:31:48Z, a Friday.
local NOW = env.now_ms
local SEC, MIN, HOUR, DAY = 1000, 60000, 3600000, 86400000

local function at(ms: number): any
	local e = table.clone(env :: any)
	e.now_ms = ms
	return e
end

local function merge(into: { [string]: any }, extra: { [string]: any }?): { [string]: any }
	if extra then
		for k, v in extra do
			into[k] = v
		end
	end
	return into
end

local function opts(extra: { [string]: any }?): any
	return merge({ key = "c", local_offset_min = 0 }, extra)
end

local function clock(options: { [string]: any }): any
	return { type = "grafana-clock-panel", options = options }
end

local function countdown(settings: { [string]: any }, extra: { [string]: any }?): any
	return clock(merge({ mode = "countdown", timezone = "UTC", countdownSettings = settings }, extra))
end

local function timeOf(panel: any, e: any?, o: any?): string
	return Clock.compute(panel, {}, e or env, o or opts()).time
end

describe("clock time mode", function()
	it("shows 24 hour time by default in the panel's timezone", function()
		expect(timeOf(clock({ timezone = "UTC" }))).toBe("20:31:48")
		expect(timeOf(clock({ timezone = "America/New_York" }))).toBe("16:31:48")
	end)

	it("shows 12 hour time and custom moment formats", function()
		expect(timeOf(clock({ timezone = "UTC", clockType = "12 hour" }))).toBe("8:31:48 PM")
		local custom = clock({ timezone = "UTC", clockType = "custom", timeSettings = { customFormat = "dddd HH:mm" } })
		expect(timeOf(custom)).toBe("Friday 20:31")
		-- An empty custom format falls back to 24 hour.
		expect(timeOf(clock({ timezone = "UTC", clockType = "custom", timeSettings = { customFormat = "" } }))).toBe(
			"20:31:48"
		)
	end)

	it("formats moment's localized, ordinal, week and escaped tokens", function()
		expect(Clock.format("LLLL", NOW, 0, "UTC")).toBe("Friday, October 9, 2026 8:31 PM")
		expect(Clock.format("Do MMMM YYYY, [week] W", NOW, 540, "JST")).toBe("10th October 2026, week 41")
		expect(Clock.format("[Today is] dddd", NOW, 0, "UTC")).toBe("Today is Friday")
	end)

	it("handles leap days", function()
		expect(Clock.format("YYYY-MM-DD HH:mm", 1709251199000, 0, "UTC")).toBe("2024-02-29 23:59")
	end)

	it("shows the date in dateFormat above the time", function()
		local r = Clock.compute(
			clock({ timezone = "Asia/Tokyo", dateSettings = { showDate = true, dateFormat = "YYYY-MM-DD" } }),
			{},
			env,
			opts()
		)
		expect(r.date).toBe("2026-10-10")
		expect(r.time).toBe("05:31:48")
	end)

	it("shows the timezone in each zoneFormat", function()
		local function zone(fmt: string, tz: string): { string }?
			return Clock.compute(
				clock({ timezone = tz, timezoneSettings = { showTimezone = true, zoneFormat = fmt } }),
				{},
				env,
				opts()
			).zone
		end
		expect(zone("offsetAbbv", "America/New_York")).toEqual({ "-04:00 EDT" })
		expect(zone("offset", "America/New_York")).toEqual({ "-04:00" })
		expect(zone("abbv", "America/New_York")).toEqual({ "EDT" })
		expect(zone("name", "america/new_york")).toEqual({ "America/New_York" })
		expect(zone("nameOffset", "Europe/London")).toEqual({ "Europe/London", "(+01:00 BST)" })
		expect(zone("offsetAbbv", "Etc/GMT+5")).toEqual({ "-05:00 -05" })
	end)

	it("switches DST at the zone's rule instants", function()
		local berlin = Clock.zone("Europe/Berlin", 0)
		expect(Clock.format("Z z", 1774745999000, Clock.zoneAt(berlin, 1774745999000))).toBe("+01:00 CET")
		expect(Clock.format("Z z", 1774746000000, Clock.zoneAt(berlin, 1774746000000))).toBe("+02:00 CEST")
		local ny = clock({
			timezone = "America/New_York",
			clockType = "custom",
			timeSettings = { customFormat = "HH:mm:ss z" },
		})
		expect(timeOf(ny, at(1772953199000))).toBe("01:59:59 EST")
		expect(timeOf(ny, at(1772953200000))).toBe("03:00:00 EDT")
	end)

	it("uses the dashboard's timezone for 'dashboard', and local time for names moment does not know", function()
		local panel = clock({ timezone = "dashboard", timezoneSettings = { showTimezone = true, zoneFormat = "name" } })
		local utc = Clock.compute(panel, {}, env, opts({ timezone = "utc", local_offset_min = -300 }))
		expect(utc.time).toBe("20:31:48")
		expect(utc.zone).toEqual({ "UTC" })
		-- A dashboard on the browser default: moment().tz("browser") stays
		-- local, and the zone name falls back to the string.
		local browser = Clock.compute(panel, {}, env, opts({ timezone = "", local_offset_min = -300 }))
		expect(browser.time).toBe("15:31:48")
		expect(browser.zone).toEqual({ "browser" })
	end)

	it("describes the clock with the input description", function()
		local r = Clock.compute(
			clock({ timezone = "UTC", descriptionSettings = { source = "input", descriptionText = "Ship it" } }),
			{},
			env,
			opts()
		)
		expect(r.description).toBe("Ship it")
		expect(Clock.compute(clock({}), {}, env, opts()).description).toBeNil()
	end)
end)

describe("clock countdown and countup text", function()
	it("counts down to an input time in the panel's humanized format", function()
		local panel = countdown({ source = "input", endCountdownTime = "2099-12-31T23:59:59+00:00" })
		expect(timeOf(panel)).toBe("73 years, 2 months, 22 days, 3 hours, 28 minutes, 11 seconds")
	end)

	it("counts up from an input time", function()
		local panel = clock({
			mode = "countup",
			timezone = "UTC",
			countupSettings = { source = "input", beginCountupTime = "2020-01-01T00:00:00+00:00" },
		})
		expect(timeOf(panel)).toBe("6 years, 9 months, 7 days, 20 hours, 31 minutes, 48 seconds")
		local leap = clock({
			mode = "countup",
			timezone = "UTC",
			countupSettings = { source = "input", beginCountupTime = "2024-02-29T00:00:00Z" },
		})
		expect(timeOf(leap)).toBe("2 years, 7 months, 9 days, 20 hours, 31 minutes, 48 seconds")
	end)

	it("shows endText once the end time has passed, and beginText before the begin time", function()
		expect(timeOf(countdown({ source = "input", endCountdownTime = "2026-10-09T20:31:48Z" }))).toBe("00:00:00")
		expect(timeOf(countdown({ source = "input", endCountdownTime = "2020-01-01", endText = "Launched" }))).toBe(
			"Launched"
		)
		local future = clock({
			mode = "countup",
			timezone = "UTC",
			countupSettings = { source = "input", beginCountupTime = "2030-01-01", beginText = "soon" },
		})
		expect(timeOf(future)).toBe("soon")
	end)

	it("rolls units over like moment.duration (average months, ms durations)", function()
		expect(Clock.humanize(500)).toBe("0 seconds")
		-- The trailing space after a singular second is the plugin's.
		expect(Clock.humanize(SEC)).toBe("1 second ")
		expect(Clock.humanize(MIN + SEC)).toBe("1 minute, 1 second ")
		expect(Clock.humanize(5 * HOUR)).toBe("5 hours, 0 minutes, 0 seconds")
		expect(Clock.humanize(30 * DAY)).toBe("30 days, 0 hours, 0 minutes, 0 seconds")
		expect(Clock.humanize(31 * DAY)).toBe("1 month, 0 days, 0 hours, 0 minutes, 0 seconds")
		expect(Clock.humanize(365 * DAY)).toBe("11 months, 30 days, 0 hours, 0 minutes, 0 seconds")
		expect(Clock.humanize(366 * DAY)).toBe("1 year, 0 months, 0 days, 0 hours, 0 minutes, 0 seconds")
	end)

	it("formats customFormat 'auto' and templates with moment-duration-format", function()
		local ms = 4102444799000 - NOW
		expect(Clock.formatDuration(ms, nil)).toBe("73 years, 2 months, 22 days")
		expect(Clock.formatDuration(ms, "hh:mm:ss")).toBe("641,907:28:11")
		expect(Clock.formatDuration(45 * SEC, nil)).toBe("0:45")
		expect(Clock.formatDuration(59500, "m:ss")).toBe("1:00")
		expect(Clock.formatDuration(90061001, nil)).toBe("1 day, 1 hour")
		expect(Clock.formatDuration(90061001, "d [days] h [hours]")).toBe("1 day 1 hour")
		expect(Clock.formatDuration(49 * HOUR + 1, "h [hours], m [minutes]")).toBe("49 hours, 0 minutes")
		expect(Clock.formatDuration(31 * DAY, nil)).toBe("1 month")
		local auto = countdown({ source = "input", endCountdownTime = "2026-10-09T20:32:33Z", customFormat = "auto" })
		expect(timeOf(auto)).toBe("0:45")
	end)

	it("keeps the input's wall time in the clock's timezone", function()
		-- moment(input).utcOffset(clockOffset, true): no offset in the input
		-- means "this wall time in the clock's zone".
		local ny = countdown(
			{ source = "input", endCountdownTime = "2026-10-09T21:31:48" },
			{ timezone = "America/New_York" }
		)
		expect(timeOf(ny)).toBe("5 hours, 0 minutes, 0 seconds")
		local kolkata = countdown(
			{ source = "input", endCountdownTime = "2026-10-09T21:31:48" },
			{ timezone = "Asia/Kolkata" }
		)
		expect(timeOf(kolkata)).toBe("00:00:00")
		-- With an offset, the instant is read as the viewer's local wall time
		-- first: a viewer at UTC-5 sees a UTC clock's end five hours early.
		local utc = countdown({ source = "input", endCountdownTime = "2026-10-09T22:31:48Z" })
		expect(timeOf(utc, env, opts({ local_offset_min = -300 }))).toBe("00:00:00")
		expect(timeOf(utc, env, opts({ local_offset_min = 0 }))).toBe("2 hours, 0 minutes, 0 seconds")
	end)

	it("interpolates dashboard variables into the input time", function()
		local panel = countdown({ source = "input", endCountdownTime = "${release}" })
		local o = opts({
			interpolate = function(s: string): string
				return (string.gsub(s, "%${release}", "2026-10-09T21:31:48Z"))
			end,
		})
		expect(timeOf(panel, env, o)).toBe("1 hour, 0 minutes, 0 seconds")
	end)

	it("shows noValueText for an empty input and invalidValueText for an unreadable one", function()
		expect(timeOf(countdown({ source = "input", endCountdownTime = "" }))).toBe("no value found")
		expect(timeOf(countdown({ source = "input", endCountdownTime = "not a date", invalidValueText = "bad" }))).toBe(
			"bad"
		)
		expect(timeOf(countdown({ source = "input", endCountdownTime = "2029-13-01" }))).toBe("invalid value")
	end)
end)

describe("clock query source", function()
	local frames = {
		{
			fields = {
				Frame.field("end", "string", {
					"2026-10-09T19:00:00Z",
					"2026-10-09T23:31:48Z",
					"2026-10-09T21:31:48Z",
					Frame.NULL,
				}),
				Frame.field("label", "string", { "past", "later", "next", "missing" }),
			},
		},
	} :: { Frame.Frame }

	local function query(calc: string, m: string?): any
		local settings = { source = "query", queryField = "end", queryCalculation = calc }
		return clock({
			mode = m or "countdown",
			timezone = "UTC",
			countdownSettings = settings,
			countupSettings = settings,
			descriptionSettings = { source = "query", queryField = "label" },
		})
	end

	it("counts down to the soonest future time with its description (minFuture)", function()
		local r = Clock.compute(query("minFuture"), frames, env, opts())
		expect(r.time).toBe("1 hour, 0 minutes, 0 seconds")
		expect(r.description).toBe("next")
	end)

	it("counts up from the latest past time (maxPast)", function()
		local r = Clock.compute(query("maxPast", "countup"), frames, env, opts())
		expect(r.time).toBe("1 hour, 31 minutes, 48 seconds")
		expect(r.description).toBe("past")
	end)

	it("reduces with lastNotNull, max and min over the field's times", function()
		expect(Clock.compute(query("lastNotNull"), frames, env, opts()).time).toBe("1 hour, 0 minutes, 0 seconds")
		expect(Clock.compute(query("max"), frames, env, opts()).time).toBe("3 hours, 0 minutes, 0 seconds")
		expect(Clock.compute(query("min"), frames, env, opts()).time).toBe("00:00:00")
	end)

	it("shows invalidValueText when 'last' is null, noValueText without data or field", function()
		local last = Clock.compute(query("last"), frames, env, opts())
		expect(last.time).toBe("invalid value")
		expect(last.description).toBe("missing")
		expect(Clock.compute(query("lastNotNull"), {}, env, opts()).time).toBe("no value found")
		expect(Clock.compute(query("lastNotNull"), {}, env, opts()).description).toBe("no description found")
		local wrong = query("last")
		wrong.options.countdownSettings = { source = "query", queryField = "nope", queryCalculation = "last" }
		expect(Clock.compute(wrong, frames, env, opts()).time).toBe("no value found")
	end)

	it("reads epoch ms time fields", function()
		local tf = { { fields = { Frame.field("t", "time", { NOW + 90 * SEC }) } } } :: { Frame.Frame }
		local panel = clock({
			mode = "countdown",
			timezone = "UTC",
			countdownSettings = { source = "query", queryField = "t", queryCalculation = "last" },
		})
		expect(Clock.compute(panel, tf, env, opts()).time).toBe("1 minute, 30 seconds")
	end)

	it("queries only when the active mode's source is query", function()
		expect(Clock.queries(query("last"))).toBe(true)
		expect(Clock.queries(clock({ mode = "time" }))).toBe(false)
		expect(Clock.queries(countdown({ source = "input" }))).toBe(false)
		expect(Clock.queries(clock({ mode = "countup", countdownSettings = { source = "query" } }))).toBe(false)
	end)
end)

describe("clock refresh, support and view", function()
	it("ticks every second unless it refreshes with the dashboard", function()
		expect(Clock.liveMs(clock({}), env)).toBe(1000)
		expect(Clock.liveMs(clock({ refresh = "sec" }), env)).toBe(1000)
		expect(Clock.liveMs(clock({ refresh = "dashboard" }), env)).toBeNil()
		expect(Clock.liveMs(clock({ refreshSettings = { syncWithDashboard = true } }), env)).toBeNil()
	end)

	it("leaves the clock panel 3.x digital style to the image ladder", function()
		local ok, why = Clock.supports(clock({ style = "digital" }), env)
		expect(ok).toBe(false)
		expect(why).toBe("the digital clock style (clock panel 3.x) is not rendered natively")
		expect((Clock.supports(clock({}), env))).toBe(true)
	end)

	it("maps fonts, weight, monospace and background to classes", function()
		local node: any = Clock.view(
			clock({
				timezone = "UTC",
				fontMono = true,
				bgColor = "transparent",
				timeSettings = { fontSize = "36px", fontWeight = "bold" },
				dateSettings = { showDate = true },
				descriptionSettings = { source = "input", descriptionText = "x", fontSize = "2rem" },
			}),
			{},
			env,
			opts()
		)
		expect(node.p.class).toBe("tgp-clock tgp-clock-mono")
		local classes: { [string]: string } = {}
		for _, c in node.c do
			classes[c.p.key] = c.p.class
		end
		expect(classes.date).toBe("tgp-clock-date tgp-clock-fs20")
		expect(classes.time).toBe("tgp-clock-time tgp-clock-fs36 tgp-clock-bold")
		expect(classes.desc).toBe("tgp-clock-desc tgp-clock-fs28")
		expect(S.text(node)).toBe("2026-10-0920:31:48x")
	end)

	it("snaps font sizes and colors backgrounds like Grafana's palette", function()
		expect(Clock.fontClass("12px", "h2")).toBe("tgp-clock-fs12")
		expect(Clock.fontClass("50px", "h2")).toBe("tgp-clock-fs48")
		expect(Clock.fontClass("", "h2")).toBe("tgp-clock-fs24")
		expect(Clock.bgClass("")).toBeNil()
		expect(Clock.bgClass("dark-red")).toBe("tgp-clock-bg-dark-red")
		expect(Clock.bgClass("#00ff00")).toBe("tgp-bg tgp-success")
	end)
end)

-- The provisioned tern-all-panels clocks (panels 37-41) as both Grafanas
-- serve them, panel 40's TestData frames from the recorded /api/ds/query.
-- The viewer sits at UTC; the dashboard timezone is "utc".
local function allPanels(version: string, id: number): any
	local doc = S.decode("grafana/" .. version .. "/dashboard_tern_all_panels.json")
	for _, p in doc.dashboard.panels do
		if p.id == id then
			return p
		end
	end
	error("no panel " .. id)
end

for _, version in S.VERSIONS do
	describe("clock on tern-all-panels, Grafana " .. version, function()
		local o = opts({ timezone = "utc" })

		it("panel 37: Berlin time with date, offset and abbreviation, and description", function()
			local r = Clock.compute(allPanels(version, 37), {}, env, o)
			expect(r.date).toBe("2026-10-09")
			expect(r.time).toBe("22:31:48")
			expect(r.zone).toEqual({ "+02:00 CEST" })
			expect(r.description).toBe("Berlin office")
		end)

		it("panel 38: countdown to 2100 on a dark-blue background", function()
			local panel = allPanels(version, 38)
			local r = Clock.compute(panel, {}, env, o)
			expect(r.time).toBe("73 years, 2 months, 22 days, 3 hours, 28 minutes, 11 seconds")
			expect(r.description).toBe("Until the 2100 launch")
			local node: any = Clock.view(panel, {}, env, o)
			expect(node.p.class).toBe("tgp-clock tgp-clock-bg-dark-blue")
		end)

		it("panel 39: countup since 2020 in monospace", function()
			local panel = allPanels(version, 39)
			expect(Clock.compute(panel, {}, env, o).time).toBe(
				"6 years, 9 months, 7 days, 20 hours, 31 minutes, 48 seconds"
			)
			local node: any = Clock.view(panel, {}, env, o)
			expect(node.p.class).toBe("tgp-clock tgp-clock-mono")
		end)

		it("panel 40: countdown to the soonest future deadline of the TestData frame", function()
			local panel = allPanels(version, 40)
			expect(Clock.queries(panel)).toBe(true)
			local r = Clock.compute(panel, S.frames(version, "all_panels_40"), env, o)
			expect(r.time).toBe("71 years, 2 months, 22 days, 3 hours, 28 minutes, 12 seconds")
			expect(r.description).toBe("code freeze")
		end)

		it("panel 41: custom 12 hour New York time with a long date and the zone name", function()
			local r = Clock.compute(allPanels(version, 41), {}, env, o)
			expect(r.date).toBe("Friday, October 9")
			expect(r.time).toBe("04:31:48 PM")
			expect(r.zone).toEqual({ "America/New_York" })
		end)

		it("needs no query for input clocks and ticks every second", function()
			for _, id in { 37, 38, 39, 41 } do
				expect(Clock.queries(allPanels(version, id))).toBe(false)
				expect(Clock.liveMs(allPanels(version, id), env)).toBe(1000)
			end
		end)
	end)
end

return nil
