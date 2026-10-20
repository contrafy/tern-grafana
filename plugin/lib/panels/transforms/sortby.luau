--!strict
-- sortBy: packages/grafana-data/src/transformations/transformers/sortBy.ts
-- with dataframe/processDataFrame.ts sortDataFrameByFields. Each frame's
-- rows are ordered by the listed fields (display name, or `index`); later
-- entries only break ties; a field the frame lacks is skipped.

local Json = require("../json")
local Frame = require("../../frame/types")
local Shared = require("./shared")

type Frame = Frame.Frame
type Ctx = Shared.Ctx

local M = {}

function M.unsupported(_options: any, _ctx: Ctx): string?
	return nil
end

function M.apply(frames: { Frame }, options: any, ctx: Ctx): { Frame }
	local env = ctx.env
	local sort = Json.list(env, Json.path(env, options, "sort"))
	if #frames == 0 or #sort == 0 then
		return frames
	end
	local out: { Frame } = {}
	for _, frame in frames do
		local sorts: { Shared.SortField } = {}
		for _, s in sort do
			local desc = Json.bool(env, Json.path(env, s, "desc")) == true
			local index = Json.num(env, Json.path(env, s, "index"))
			if index == nil then
				local name = Json.path(env, s, "field")
				index = -1
				for i, f in frame.fields do
					if name == Shared.displayName(f, frame) then
						index = i - 1
						break
					end
				end
			end
			table.insert(sorts, { index = (index :: number) + 1, desc = desc })
		end
		table.insert(out, Shared.sortByFields(frame, sorts))
	end
	return out
end

return M
