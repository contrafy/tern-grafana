--!strict
-- Compares two benchmark reports (tests/bench/out/*.json) passed as text,
-- because standalone luau cannot read files (tests/bench/bench.sh compare):
--
--   .tools/bin/luau tests/bench/compare.luau -a "$(cat BASE)" "$(cat NEW)" [THRESHOLD_PCT]
--
-- Prints every metric both reports have, base -> new and the change. Timed
-- metrics compare medians and are flagged when they moved more than the
-- threshold (default 10%); counts and bytes are flagged on any change.
-- Never fails: whether a change matters is a judgment, not a gate.

local json = require("../lib/json")

local args = { ... }
local base = json.decode((assert(args[1], "compare.luau: missing base report")))
local new = json.decode((assert(args[2], "compare.luau: missing new report")))
local threshold = tonumber(args[3] or "") or 10

local function value(v: any): number?
	if type(v) == "number" then
		return v
	elseif type(v) == "table" and type(v.median) == "number" then
		return v.median
	end
	return nil
end

local function fmt(v: number): string
	if v == math.floor(v) and math.abs(v) < 1e15 then
		return tostring(v)
	elseif math.abs(v) >= 100 then
		return string.format("%.0f", v)
	end
	return string.format("%.3f", v)
end

local function pad(s: string, n: number): string
	return s .. string.rep(" ", math.max(1, n - #s))
end

local function describe(meta: any): string
	if type(meta) ~= "table" then
		return "?"
	end
	return string.format(
		"%s %s%s, %s, %s",
		tostring(meta.date),
		tostring(meta.commit),
		if meta.plugin_dirty == "yes" then "+dirty" else "",
		tostring(meta.luau_flags),
		tostring(meta.cpu)
	)
end

print("base: " .. describe(base.meta))
print("new:  " .. describe(new.meta))

local names: { string } = {}
for name in new.scenarios do
	table.insert(names, name)
end
table.sort(names)

local flagged = 0
for _, name in names do
	local b = base.scenarios[name]
	if b == nil then
		print("\n## " .. name .. " (new scenario)")
		continue
	end
	print("\n## " .. name)
	local keys: { string } = {}
	for k in new.scenarios[name].metrics do
		table.insert(keys, k)
	end
	table.sort(keys)
	for _, k in keys do
		local nv = value(new.scenarios[name].metrics[k])
		local bv = value(b.metrics[k])
		if nv == nil or bv == nil then
			continue
		end
		local timed = type(new.scenarios[name].metrics[k]) == "table"
		local pct = if bv ~= 0 then (nv - bv) / math.abs(bv) * 100 else (if nv == 0 then 0 else math.huge)
		local flag = if timed then math.abs(pct) > threshold else nv ~= bv
		if flag then
			flagged += 1
		end
		print(
			string.format(
				"  %s %12s -> %-12s %s%s",
				pad(k, 36),
				fmt(bv),
				fmt(nv),
				if pct == math.huge then "new" else string.format("%+.1f%%", pct),
				if flag then (if nv < bv then "  (lower)" else "  (higher)") else ""
			)
		)
	end
end
for name in base.scenarios do
	if new.scenarios[name] == nil then
		print("\n## " .. name .. " (missing in new report)")
	end
end
print(string.format("\n%d metric(s) moved beyond %g%% (timed) or changed (counts, bytes)", flagged, threshold))
