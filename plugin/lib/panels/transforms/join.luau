--!strict
-- joinByField (and its legacy id seriesToColumns) and the join behind it:
-- packages/grafana-data/src/transformations/transformers/joinByField.ts,
-- joinDataFrames.ts (joinDataFrames, joinTabular, and uPlot's join with its
-- null modes), ensureColumns.ts (calculateField's join of time series).
--
-- Modes: "outer" (default) aligns every frame on the sorted union of the
-- join values (gaps are JavaScript undefined, Shared.GAP); "inner" keeps the
-- join values present in every frame; "outerTabular" is the SQL-style full
-- outer join. Without `byField` the first time field joins; frames without
-- the join field are dropped (an inner join then has no rows).

local Json = require("../json")
local Frame = require("../../frame/types")
local Shared = require("./shared")
local Tbl = require("../../tbl")

type Frame = Frame.Frame
type Field = Frame.Field
type Ctx = Shared.Ctx
type FieldMatcher = Shared.FieldMatcher

local M = {}

local GAP = Shared.GAP

-- uPlot null modes.
local NULL_REMOVE, NULL_RETAIN, NULL_EXPAND = 0, 1, 2

-- pickBestJoinField: the first time field when the first frame has one.
-- Otherwise Grafana looks for a number field name common to every frame,
-- but compares the first frame with itself, so nothing ever matches.
local function pickBestJoinField(frames: { Frame }): FieldMatcher
	if Shared.timeField(frames[1]) then
		return function(field: Field, frame: Frame): boolean
			return field.type == "time" and (Shared.timeField(frame)) == field
		end
	end
	return function(): boolean
		return false
	end
end

local function nullModeOf(field: Field): number
	local custom = field.config and field.config.custom
	local span = if custom then custom.spanNulls else nil
	if span == true then
		return NULL_REMOVE
	elseif span == -1 then
		return NULL_RETAIN
	end
	return NULL_EXPAND
end

-- Sets gaps next to nulls to null (uPlot nullExpand).
local function nullExpand(yVals: { any }, nullIdxs: { number }, alignedLen: number)
	local lastNullIdx = -1
	for _, nullIdx in nullIdxs do
		if nullIdx > lastNullIdx then
			local xi = nullIdx - 1
			while xi >= 1 and Shared.nullish(yVals[xi]) do
				yVals[xi] = Frame.NULL
				xi -= 1
			end
			xi = nullIdx + 1
			while xi <= alignedLen and Shared.nullish(yVals[xi]) do
				yVals[xi] = Frame.NULL
				lastNullIdx = xi
				xi += 1
			end
		end
	end
end

local function allHeadersSame(tables: { { { any } } }): boolean
	local vals0 = tables[1][1]
	local len0 = #vals0
	for i = 2, #tables do
		local vals1 = tables[i][1]
		if #vals1 ~= len0 then
			return false
		end
		if vals1 ~= vals0 then
			for j = 1, len0 do
				if vals1[j] ~= vals0[j] then
					return false
				end
			end
		end
	end
	return true
end

local function lessX(a: any, b: any): boolean
	if type(a) == "number" and type(b) == "number" then
		return a < b
	end
	return Shared.jsString(a) < Shared.jsString(b)
end

-- uPlot's join (outer alignment on the union of x values).
local function alignedJoin(tables: { { { any } } }, nullModes: { { number } }): { { any } }
	if allHeadersSame(tables) then
		local columns: { { any } } = {}
		for _, c in tables[1] do
			table.insert(columns, c)
		end
		for i = 2, #tables do
			for c = 2, #tables[i] do
				table.insert(columns, tables[i][c])
			end
		end
		local fields: { Field } = {}
		for _, values in columns do
			table.insert(fields, Frame.field("", "number", values))
		end
		local sorted = Shared.maybeSort({ fields = fields }, 1)
		local out: { { any } } = {}
		for _, f in sorted.fields do
			table.insert(out, f.values)
		end
		return out
	end
	local seen: { [any]: boolean } = {}
	local xs: { any } = {}
	for _, t in tables do
		for _, x in t[1] do
			local key = if x == nil then GAP else x
			if not seen[key] then
				seen[key] = true
				table.insert(xs, key)
			end
		end
	end
	table.sort(xs, lessX)
	local alignedLen = #xs
	local xIdx: { [any]: number } = {}
	for i, x in xs do
		xIdx[x] = i
	end
	local data: { { any } } = { xs }
	for ti, t in tables do
		local tx = t[1]
		for si = 2, #t do
			local ys = t[si]
			local yVals: { any } = table.create(alignedLen, GAP)
			local mode = nullModes[ti][si]
			local nullIdxs: { number } = {}
			for i = 1, #ys do
				local y = ys[i]
				local at = xIdx[if tx[i] == nil then GAP else tx[i]]
				if at then
					if y == Frame.NULL then
						if mode ~= NULL_REMOVE then
							yVals[at] = y
							if mode == NULL_EXPAND then
								table.insert(nullIdxs, at)
							end
						end
					elseif y ~= nil then
						yVals[at] = y
					end
				end
			end
			nullExpand(yVals, nullIdxs, alignedLen)
			table.insert(data, yVals)
		end
	end
	return data
end

-- A JavaScript object key's text and whether it is an array index (index
-- keys enumerate first, ascending; the rest in insertion order).
local function objectKey(v: any): (string, number?)
	local s = Shared.jsString(v)
	local n = tonumber(s)
	if n and n >= 0 and n < 4294967295 and n % 1 == 0 and Shared.jsString(n) == s then
		return s, n
	end
	return s, nil
end

-- joinTabular: SQL-style inner (outer = false) or full outer join on the
-- first column of each table, left to right.
local function joinTabular(tables: { { { any } } }, outer: boolean): { { any } }
	local ltable = tables[1]
	for ti = 2, #tables do
		local rtable = tables[ti]
		local rfield = rtable[1]
		local index: { [string]: { number } } = {}
		local named: { string } = {}
		local indexed: { { key: string, n: number } } = {}
		for i = 1, #rfield do
			local key, n = objectKey(rfield[i])
			local idxs = index[key]
			if idxs == nil then
				idxs = {}
				index[key] = idxs
				if n then
					table.insert(indexed, { key = key, n = n })
				else
					table.insert(named, key)
				end
			end
			table.insert(idxs, i)
		end
		-- Grafana records matched keys by their raw value and looks them up
		-- by object key text, so a number key never reads as matched and its
		-- right rows repeat as unmatched in an outer join.
		local matchedKeys: { [any]: boolean } = {}
		local unmatchedLeft: { number } = {}
		local unmatchedRight: { number } = {}
		local matched: { { l: number, r: { number } } } = {}
		local lfield = ltable[1]
		for i = 1, #lfield do
			local v = lfield[i]
			if not Shared.nullish(v) then
				local idxs = index[(objectKey(v))]
				if idxs then
					table.insert(matched, { l = i, r = idxs })
					if outer then
						matchedKeys[v] = true
					end
				elseif outer then
					table.insert(unmatchedLeft, i)
				end
			elseif outer then
				table.insert(unmatchedLeft, i)
			end
		end
		if outer then
			table.sort(indexed, function(a, b): boolean
				return a.n < b.n
			end)
			local order: { string } = {}
			for _, k in indexed do
				table.insert(order, k.key)
			end
			for _, k in named do
				table.insert(order, k)
			end
			for _, k in order do
				if not matchedKeys[k] then
					for _, i in index[k] do
						table.insert(unmatchedRight, i)
					end
				end
			end
		end
		local leftSrc: { number } = {}
		local rightSrc: { number } = {}
		for _, m in matched do
			for _, r in m.r do
				table.insert(leftSrc, m.l)
				table.insert(rightSrc, r)
			end
		end
		for _, l in unmatchedLeft do
			table.insert(leftSrc, l)
			table.insert(rightSrc, -1)
		end
		for _, r in unmatchedRight do
			table.insert(leftSrc, -1)
			table.insert(rightSrc, r)
		end
		local count = #leftSrc
		local joined: { { any } } = {}
		local ljoin, rjoin = ltable[1], rtable[1]
		local joinCol: { any } = table.create(count)
		for r = 1, count do
			local li = leftSrc[r]
			joinCol[r] = if li ~= -1 then ljoin[li] else rjoin[rightSrc[r]]
		end
		table.insert(joined, joinCol)
		for c = 2, #ltable do
			local src = ltable[c]
			local col: { any } = table.create(count)
			for r = 1, count do
				local li = leftSrc[r]
				col[r] = if li ~= -1 then src[li] else Frame.NULL
			end
			table.insert(joined, col)
		end
		for c = 2, #rtable do
			local src = rtable[c]
			local col: { any } = table.create(count)
			for r = 1, count do
				local ri = rightSrc[r]
				col[r] = if ri ~= -1 then src[ri] else Frame.NULL
			end
			table.insert(joined, col)
		end
		ltable = joined
	end
	return ltable
end

export type JoinOptions = {
	frames: { Frame },
	joinBy: FieldMatcher?,
	mode: string?,
}

-- joinDataFrames: one frame joined by the first matching field.
function M.joinDataFrames(o: JoinOptions): Frame?
	local frames = o.frames
	if #frames == 0 then
		return nil
	end
	local matcher = o.joinBy or pickBestJoinField(frames)
	if #frames == 1 then
		local frame = frames[1]
		local joinIndex: number? = nil
		for i, f in frame.fields do
			if matcher(f, frame, frames) then
				joinIndex = i
				break
			end
		end
		if joinIndex == nil then
			if o.mode == "inner" then
				return { fields = {} }
			end
			return frame
		end
		return Shared.maybeSort(frame, joinIndex)
	end
	local nullModes: { { number } } = {}
	local allData: { { { any } } } = {}
	local originalFields: { Field } = {}
	local dropped = false
	for _, frame in frames do
		if #frame.fields == 0 then
			dropped = true
			continue
		end
		local modes: { number } = { NULL_REMOVE }
		local join: Field? = nil
		local fields: { Field } = {}
		for _, field in frame.fields do
			if join == nil and matcher(field, frame, frames) then
				join = field
			else
				table.insert(modes, nullModeOf(field))
				-- `field.labels ?? {}`: a joined field always has labels, which
				-- keeps a second Time column out of the time-field display name
				-- shortcut (it becomes "Time 2", fieldState.ts).
				local labels: { [string]: string } = field.labels or {}
				local name = field.name
				if frame.name then
					if field.name == "Value" then
						name = frame.name
					elseif labels.name == nil then
						local l = Tbl.copy(labels)
						l.name = frame.name
						labels = l
					end
				end
				local copy = Tbl.copy(field)
				copy.name = name
				copy.labels = labels
				table.insert(fields, copy)
			end
		end
		if join == nil then
			dropped = true
			continue
		end
		if #originalFields == 0 then
			table.insert(originalFields, join)
		end
		table.insert(nullModes, modes)
		local a: { { any } } = { join.values }
		for _, f in fields do
			table.insert(a, f.values)
			table.insert(originalFields, f)
		end
		table.insert(allData, a)
	end
	if #allData == 0 then
		return { fields = originalFields }
	end
	if dropped and o.mode == "inner" then
		local empty: { Field } = {}
		for _, f in originalFields do
			table.insert(empty, Shared.withValues(f, {}))
		end
		return { fields = empty }
	end
	local joined = if o.mode == "outerTabular"
		then joinTabular(allData, true)
		elseif o.mode == "inner" then joinTabular(allData, false)
		else alignedJoin(allData, nullModes)
	local out: { Field } = {}
	for i, f in originalFields do
		table.insert(out, Shared.withValues(f, joined[i] or {}))
	end
	return { fields = out }
end

-- joinByField.transformer.
function M.joinByField(
	frames: { Frame },
	byField: string?,
	mode: string?,
	refId: string?,
	keepUnjoined: boolean?,
	ctx: Ctx
): { Frame }
	if #frames > 1 then
		local joinBy = if byField and byField ~= "" then Shared.byName(ctx.env, byField) else nil
		local participants = frames
		local unjoined: { Frame } = {}
		if keepUnjoined and joinBy then
			participants = {}
			for _, frame in frames do
				local hit = false
				for _, f in frame.fields do
					if joinBy(f, frame, frames) then
						hit = true
						break
					end
				end
				table.insert(if hit then participants else unjoined, frame)
			end
			if #participants == 0 then
				return frames
			end
		end
		local joined = M.joinDataFrames({ frames = participants, joinBy = joinBy, mode = mode })
		if joined then
			local copy = Tbl.copy(joined)
			copy.refId = refId or Shared.dynamicRefId("joinByField", participants)
			local out: { Frame } = { copy }
			for _, f in unjoined do
				table.insert(out, f)
			end
			return out
		end
	end
	return Shared.staticRefId(frames, refId)
end

-- ensureColumns: time series sharing a time field name are joined by it.
function M.ensureColumns(frames: { Frame }, ctx: Ctx): { Frame }
	local name: string? = nil
	for _, frame in frames do
		local tf = Shared.timeField(frame)
		if tf == nil then
			return frames
		end
		if name == nil then
			name = tf.name
		elseif name ~= tf.name then
			return frames
		end
	end
	if #frames > 1 and name then
		return M.joinByField(frames, name, nil, nil, nil, ctx)
	end
	return frames
end

function M.unsupported(_options: any, _ctx: Ctx): string?
	return nil
end

function M.apply(frames: { Frame }, options: any, ctx: Ctx): { Frame }
	local env = ctx.env
	local mode = Json.str(env, Json.path(env, options, "mode")) or "outer"
	return M.joinByField(
		frames,
		Json.str(env, Json.path(env, options, "byField")),
		mode,
		Json.str(env, Json.path(env, options, "refId")),
		Json.bool(env, Json.path(env, options, "keepUnjoinedFrames")),
		ctx
	)
end

return M
