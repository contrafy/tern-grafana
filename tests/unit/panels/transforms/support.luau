--!strict
-- Frames and runners for the transformer specs: frames are built the way
-- the Grafana tests build theirs (toDataFrame with named, typed fields), and
-- every transformation runs through Transform.prepare, the path the panels
-- take.
local FieldConfig = require("../../../../plugin/lib/panels/fieldconfig")
local Frame = require("../../../../plugin/lib/frame/types")
local PS = require("../support")
local Transform = require("../../../../plugin/lib/panels/transform")

local M = {}

M.NULL = Frame.NULL
M.env = table.clone(PS.env)
M.env.local_offset_min = 0
M.panels = PS

function M.f(
	name: string,
	fieldType: Frame.FieldType,
	values: { any },
	labels: { [string]: string }?,
	config: Frame.FieldConfig?
): Frame.Field
	return Frame.field(name, fieldType, values, labels, config)
end

function M.frame(fields: { Frame.Field }, refId: string?, name: string?): Frame.Frame
	return { fields = fields, refId = refId, name = name }
end

-- The frames after the transformations (a list of {id, options, ...}).
function M.run(transformations: { any }, frames: { Frame.Frame }, interpolate: ((string) -> string)?): { Frame.Frame }
	return Transform.prepare({ transformations = transformations }, frames, M.env, interpolate)
end

-- One transformation.
function M.one(id: string, options: any, frames: { Frame.Frame }): { Frame.Frame }
	return M.run({ { id = id, options = options } }, frames)
end

function M.unsupported(id: string, options: any): string?
	return Transform.unsupported({ transformations = { { id = id, options = options } } }, M.env)
end

-- Display names (getFieldDisplayName) of a frame's fields.
function M.names(frame: Frame.Frame, frames: { Frame.Frame }?): { string }
	local out: { string } = {}
	for _, f in frame.fields do
		table.insert(out, FieldConfig.displayName(f, frame, frames or { frame }))
	end
	return out
end

-- Raw field names.
function M.fieldNames(frame: Frame.Frame): { string }
	local out: { string } = {}
	for _, f in frame.fields do
		table.insert(out, f.name)
	end
	return out
end

-- The values of the field with this display name.
function M.col(frame: Frame.Frame, name: string, frames: { Frame.Frame }?): { any }
	for _, f in frame.fields do
		if FieldConfig.displayName(f, frame, frames or { frame }) == name then
			return f.values
		end
	end
	error("no field " .. name)
end

return M
