--!strict
-- Largest-Triangle-Three-Buckets downsampling (Sveinn Steinarsson, 2013) on
-- parallel time/value arrays.
--
-- Missing samples (the `missing` sentinel, any non-number, NaN or +-Inf) split
-- the series into runs. Each run is downsampled on its own with a share of the
-- budget proportional to its length and always keeps its first and last
-- sample; each gap keeps one marker (its first sample, unchanged), so a
-- renderer still breaks the line there. Output can exceed `threshold` only when
-- there are more runs and gaps than the budget can hold.

local M = {}

local HUGE = math.huge

local function present(v: any, missing: any): boolean
	return v ~= missing and type(v) == "number" and v == v and v ~= HUGE and v ~= -HUGE
end

-- Appends run s..e of present samples to outT/outV after index `k`; returns
-- the new last index.
local function appendRun(
	times: { number },
	values: { any },
	s: number,
	e: number,
	budget: number,
	outT: { number },
	outV: { any },
	k: number
): number
	local n = e - s + 1
	if budget >= n then
		table.move(times, s, e, k + 1, outT)
		table.move(values, s, e, k + 1, outV)
		return k + n
	end
	k += 1
	outT[k] = times[s]
	outV[k] = values[s]
	if budget >= 3 then
		local every = (n - 2) / (budget - 2)
		local a = s
		for bucket = 0, budget - 3 do
			-- Average of the next bucket is the third triangle vertex.
			local avgStart = s + math.floor((bucket + 1) * every) + 1
			local avgEnd = math.min(s + math.floor((bucket + 2) * every) + 1, e + 1)
			local avgX, avgY = 0, 0
			for i = avgStart, avgEnd - 1 do
				avgX += times[i]
				avgY += values[i]
			end
			local count = avgEnd - avgStart
			avgX /= count
			avgY /= count

			local ax, ay = times[a], values[a] :: number
			local chosen = s + math.floor(bucket * every) + 1
			local maxArea = -1
			for i = chosen, s + math.floor((bucket + 1) * every) do
				local area = math.abs((ax - avgX) * (values[i] - ay) - (ax - times[i]) * (avgY - ay))
				if area > maxArea then
					maxArea = area
					chosen = i
				end
			end
			k += 1
			outT[k] = times[chosen]
			outV[k] = values[chosen]
			a = chosen
		end
	end
	if n > 1 then
		k += 1
		outT[k] = times[e]
		outV[k] = values[e]
	end
	return k
end

-- Returns new arrays, or the inputs themselves when they already fit
-- (`threshold` >= #times or < 3).
function M.downsample(times: { number }, values: { any }, threshold: number, missing: any): ({ number }, { any })
	local n = #times
	if threshold >= n or threshold < 3 then
		return times, values
	end

	-- Runs as {start, end} pairs of present samples, and gap starts.
	local runs: { number } = {}
	local gapCount = 0
	local validCount = 0
	local i = 1
	while i <= n do
		if present(values[i], missing) then
			local s = i
			while i < n do
				local v = values[i + 1]
				if v ~= missing and type(v) == "number" and v == v and v ~= HUGE and v ~= -HUGE then
					i += 1
				else
					break
				end
			end
			table.insert(runs, s)
			table.insert(runs, i)
			validCount += i - s + 1
		else
			while i + 1 <= n and not present(values[i + 1], missing) do
				i += 1
			end
			gapCount += 1
		end
		i += 1
	end

	local budget = math.max(0, threshold - gapCount)
	local outT: { number } = table.create(threshold)
	local outV: { any } = table.create(threshold)
	local k = 0
	local r = 1
	i = 1
	while i <= n do
		if r <= #runs and runs[r] == i then
			local s, e = runs[r], runs[r + 1]
			local len = e - s + 1
			local share = math.max(math.min(len, 2), math.floor(budget * len / validCount))
			k = appendRun(times, values, s, e, share, outT, outV, k)
			r += 2
			i = e + 1
		else
			k += 1
			outT[k] = times[i]
			outV[k] = values[i]
			while i <= n and not present(values[i], missing) do
				i += 1
			end
		end
	end
	return outT, outV
end

return M
