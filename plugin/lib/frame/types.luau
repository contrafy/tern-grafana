--!strict
-- The Frame model every source normalizes to (docs/architecture.md, Data
-- model). A time series is one frame with a time field and one number field
-- carrying the series labels, the shape of Grafana's multi-frame time series,
-- so Grafana and Prometheus-direct results reach the same renderers.
--
-- Values are dense: a missing sample is `NULL`, never nil, so `#values` and
-- index alignment with the time field always hold. Times are epoch ms.

local TransportTypes = require("../transport/types")

export type FieldType = "time" | "number" | "string" | "boolean" | "other"

export type FieldConfig = {
	unit: string?,
	displayName: string?,
	decimals: number?,
	min: number?,
	max: number?,
}

export type Field = {
	name: string,
	type: FieldType,
	values: { any },
	labels: { [string]: string }?,
	config: FieldConfig?,
}

export type Notice = { severity: string, text: string }

export type FrameMeta = {
	type: string?,
	executedQueryString: string?,
	notices: { Notice }?,
}

export type Frame = {
	name: string?,
	refId: string?,
	fields: { Field },
	meta: FrameMeta?,
}

export type QueryError = TransportTypes.QueryError

export type QueryResult = { ok: true, frames: { Frame }, warnings: { string } } | { ok: false, error: QueryError }

local M = {}

-- The missing-value sentinel. Converters map JSON null (and absent samples
-- after a join) to it; it is distinct from every number, string and table.
M.NULL = newproxy(false) :: any

function M.isNull(v: any): boolean
	return v == nil or v == M.NULL
end

-- `v` when it is a plottable number (not missing, NaN or +-Inf), else nil.
function M.finite(v: any): number?
	if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
		return v
	end
	return nil
end

function M.field(
	name: string,
	fieldType: FieldType,
	values: { any },
	labels: { [string]: string }?,
	config: FieldConfig?
): Field
	return { name = name, type = fieldType, values = values, labels = labels, config = config }
end

-- One series: a "Time" field and a "Value" number field with the labels.
function M.timeSeries(
	labels: { [string]: string },
	times: { number },
	values: { any },
	config: FieldConfig?,
	name: string?
): Frame
	return {
		name = name,
		fields = {
			M.field("Time", "time", times),
			M.field("Value", "number", values, labels, config),
		},
	}
end

function M.timeField(frame: Frame): Field?
	for _, f in frame.fields do
		if f.type == "time" then
			return f
		end
	end
	return nil
end

function M.numberFields(frame: Frame): { Field }
	local out: { Field } = {}
	for _, f in frame.fields do
		if f.type == "number" then
			table.insert(out, f)
		end
	end
	return out
end

-- Label keys sorted, `__name__` excluded: Prometheus sorts labels, and a
-- stable order keeps names and table columns from shuffling between polls.
function M.labelKeys(labels: { [string]: string }?): { string }
	local keys: { string } = {}
	if labels then
		for k in labels do
			if k ~= "__name__" then
				table.insert(keys, k)
			end
		end
	end
	table.sort(keys)
	return keys
end

-- `{a="1", b="2"}`, Grafana's formatLabels; "" for no labels.
function M.formatLabels(labels: { [string]: string }?): string
	local keys = M.labelKeys(labels)
	if #keys == 0 or labels == nil then
		return ""
	end
	local parts: { string } = table.create(#keys)
	for i, k in keys do
		parts[i] = string.format('%s="%s"', k, labels[k])
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

-- Grafana's renderLegendFormat: every `{{ label }}` becomes the label's value,
-- or "" when the series has no such label.
function M.legendFormat(format: string, labels: { [string]: string }?): string
	local out = string.gsub(format, "{{%s*(.-)%s*}}", function(name: string): string
		return if labels then labels[name] or "" else ""
	end)
	return out
end

-- The series name a legend shows, as the Prometheus datasource defaults it:
-- an explicit displayName, else a legend format (not "" or "__auto"), else
-- `metric{a="b"}`, else the frame name, else the field name.
function M.displayName(field: Field, frame: Frame?, legend: string?): string
	local config = field.config
	if config and config.displayName and config.displayName ~= "" then
		return config.displayName
	end
	local labels = field.labels
	if legend and legend ~= "" and legend ~= "__auto" then
		return M.legendFormat(legend, labels)
	end
	local metric = if labels then labels.__name__ else nil
	local rest = M.formatLabels(labels)
	if metric and metric ~= "" then
		return metric .. rest
	elseif rest ~= "" then
		return rest
	elseif frame and frame.name and frame.name ~= "" then
		return frame.name
	end
	return field.name
end

return M
