--!strict
-- A panel's own time range: Grafana's panel query options "Relative time"
-- (timeFrom), "Time shift" (timeShift) and "Hide time info"
-- (hideTimeOverride), as public/app/features/dashboard-scene/scene/
-- panel-timerange/PanelTimeRange.tsx getTimeOverride computes them:
-- - timeFrom replaces a relative dashboard range by describeTextRange of the
--   value ("1h" -> now-1h..now, "Last 1 hour"); an absolute dashboard range
--   is kept;
-- - timeShift moves the range back by the value ("1h" -> raw ends get "-1h",
--   "timeshift -1h"), absolute ends by date math on the times;
-- - the header shows the info blocks unless hideTimeOverride.
-- An invalid value leaves the range as it was with "invalid time override"
-- or "invalid timeshift" as the info.

local Range = require("../time/range")

local M = {}

export type Parent = {
	-- Grafana range strings ("now-6h", ISO times, epoch ms).
	from: string,
	to: string,
	range: Range.Range,
}

export type Override = {
	range: Range.Range,
	-- Range strings after the override (relative when the source was).
	from: string,
	to: string,
	-- The header badge text ("" when none or hidden).
	info: string,
	-- Whether timeFrom or timeShift changed anything.
	overridden: boolean,
}

local SPANS: { [string]: string } = {
	s = "second",
	m = "minute",
	h = "hour",
	d = "day",
	w = "week",
	M = "month",
	y = "year",
}

export type TextRange = { from: string, to: string, display: string, invalid: boolean }

-- rangeutil.ts describeTextRange: a named range (rangeIndex) first, then
-- "Last/Next N <unit>s" for now-N<unit>, else invalid.
function M.describeTextRange(expr: string): TextRange
	local isLast = string.sub(expr, 1, 1) ~= "+"
	if string.find(expr, "now", 1, true) == nil then
		expr = (if isLast then "now-" else "now") .. expr
	end
	local opt: TextRange = if isLast
		then { from = expr, to = "now", display = "", invalid = false }
		else { from = "now", to = expr, display = "", invalid = false }
	local named = Range.describe(opt.from, opt.to)
	if named ~= opt.from .. " to " .. opt.to then
		opt.display = named
		return opt
	end
	local sign, amount, unit = string.match(expr, "^now([%-%+])(%d+)(%w)")
	if sign and amount and unit then
		local span = SPANS[unit :: string]
		if span then
			local n = tonumber(amount) :: number
			local plural = if n > 1 then "s" else ""
			opt.display = (if isLast then "Last " else "Next ") .. tostring(n) .. " " .. span .. plural
		end
	else
		opt.display = opt.from .. " to " .. opt.to
		opt.invalid = true
	end
	return opt
end

local function isRelative(from: string, to: string): boolean
	return Range.isRelative(from) or Range.isRelative(to)
end

-- `interpolate` replaces dashboard variables in the option values.
function M.apply(
	panel: { [string]: any },
	parent: Parent,
	opts: Range.Options,
	interpolate: ((string) -> string)?
): Override
	local out: Override = {
		range = parent.range,
		from = parent.from,
		to = parent.to,
		info = "",
		overridden = false,
	}
	local function text(v: any): string?
		if type(v) ~= "string" or v == "" then
			return nil
		end
		return if interpolate then interpolate(v) else v
	end
	local blocks: { string } = {}
	local timeFrom = text(panel.timeFrom)
	if timeFrom then
		local info = M.describeTextRange(timeFrom)
		if info.invalid then
			out.info = "invalid time override"
			return out
		end
		if isRelative(parent.from, parent.to) then
			local r = Range.resolve(info.from, info.to, opts)
			if r then
				out.range, out.from, out.to = r, info.from, info.to
				out.overridden = true
			end
			table.insert(blocks, info.display)
		end
	end
	local timeShift = text(panel.timeShift)
	if timeShift then
		local info = M.describeTextRange(timeShift)
		if info.invalid then
			out.info = "invalid timeshift"
			return out
		end
		local shift = "-" .. timeShift
		table.insert(blocks, "timeshift " .. shift)
		local from, to
		if isRelative(out.from, out.to) then
			from = Range.parse(out.from .. shift, false, opts)
			to = Range.parse(out.to .. shift, true, opts)
			if from and to then
				out.from, out.to = out.from .. shift, out.to .. shift
			end
		else
			from = Range.parse("now" .. shift, false, { now_ms = out.range.from_ms, offset_min = opts.offset_min })
			to = Range.parse("now" .. shift, true, { now_ms = out.range.to_ms, offset_min = opts.offset_min })
		end
		if from == nil or to == nil then
			out.info = "invalid timeshift"
			return out
		end
		out.range = { from_ms = from :: number, to_ms = to :: number }
		out.overridden = true
	end
	out.info = if panel.hideTimeOverride == true then "" else table.concat(blocks, " ")
	return out
end

return M
