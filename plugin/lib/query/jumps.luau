--!strict
-- Jumps out of a metrics chart (Query block and dashboard time series
-- panels): `L` opens the Logs block on the stream selector the series' labels
-- name (kept to `logs.correlate_labels`), `enter` on an exemplar opens the
-- Trace block on its trace id. Both keep the context and, for logs, the range.

local Correlate = require("../logs/correlate")
local Frame = require("../frame/types")
local FrameProm = require("../frame/prom")
local LogsOptions = require("../logs/options")
local Scheme = require("../links/scheme")
local Series = require("../render/series")
local ConfigTypes = require("../config/types")
local Tbl = require("../tbl")

type Frame = Frame.Frame
type Labels = { [string]: string }

local M = {}

-- The correlation label list from the config's `logs` section.
function M.correlateLabels(config: ConfigTypes.Config?): { string }
	local o = LogsOptions.read(if config then config.logs else nil)
	return o.correlate_labels
end

-- Labels every series in `frames` shares (one series: all of its labels).
function M.commonLabels(frames: { Frame }): Labels
	local common: Labels? = nil
	for _, s in Series.extract(frames) do
		if common == nil then
			common = Tbl.copy(s.labels)
		else
			for k, v in common :: Labels do
				if s.labels[k] ~= v then
					(common :: Labels)[k] = nil
				end
			end
		end
	end
	return common or {}
end

-- The link for `L`, or why there is none.
function M.logsLink(context: string?, labels: Labels, names: { string }, from: string, to: string): (string?, string?)
	if context == nil then
		return nil, "No context to look for logs in"
	end
	local selector = Correlate.selector(labels, names)
	if selector == nil then
		return nil, "The series share none of the labels that correlate with logs (" .. table.concat(names, ", ") .. ")"
	end
	local link: Scheme.Link = {
		action = "logs",
		params = { context = context, expr = selector, from = from, to = to },
		vars = {},
	}
	local ok, err = Scheme.validate(link)
	if ok == nil then
		return nil, if err then err.message else "invalid logs link"
	end
	return Scheme.encode(link), nil
end

-- The link for `enter` on an exemplar, or why there is none.
function M.traceLink(context: string?, e: FrameProm.Exemplar, label: string?): (string?, string?)
	local id = FrameProm.traceId(e.labels, label)
	if id == nil then
		return nil, "This exemplar carries no trace id"
	end
	if context == nil then
		return nil, "No context to open the trace in"
	end
	local link: Scheme.Link = { action = "trace", params = { context = context, id = string.lower(id) }, vars = {} }
	local ok, err = Scheme.validate(link)
	if ok == nil then
		return nil, "Not a trace id: " .. id .. (if err then " (" .. err.message .. ")" else "")
	end
	return Scheme.encode(link), nil
end

return M
