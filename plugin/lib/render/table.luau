--!strict
-- Frames as an instant-vector table, the way Grafana's Prometheus table view
-- shows them: one row per series with Time, `__name__`, every label as a
-- column (sorted) and the series' latest sample as Value. Rows can carry a
-- click action (e.g. open the series as a graph).

local Format = require("../units/format")
local Frame = require("../frame/types")
local Grid = require("./grid")
local Range = require("../time/range")
local ui = require("../ui")

type Frame = Frame.Frame
type Node = ui.Node

export type Options = {
	unit: string?,
	decimals: number?,
	key: string?,
	offset_min: number?,
	-- Default true.
	show_time: boolean?,
	-- Click action name for a row, from its 1-based index and labels.
	row_action: ((index: number, labels: { [string]: string }) -> string?)?,
}

export type Row = {
	labels: { [string]: string },
	time: number?,
	value: number?,
	cells: { string },
}

local M = {}

M.NO_VALUE = "-"

-- Column heads and rows (cells already formatted).
function M.rows(frames: { Frame }, opts: Options?): ({ Grid.Column }, { Row })
	local o: Options = opts or {}
	type Sample = { labels: { [string]: string }, time: number?, value: any, unit: string?, decimals: number? }
	local samples: { Sample } = {}
	local keySet: { [string]: boolean } = {}
	local hasName = false
	for _, frame in frames do
		local tf = Frame.timeField(frame)
		for _, field in Frame.numberFields(frame) do
			local n = #field.values
			local labels: { [string]: string } = field.labels or {}
			for k in labels do
				if k == "__name__" then
					hasName = true
				else
					keySet[k] = true
				end
			end
			local t = if tf and n > 0 then tf.values[n] else nil
			local config = field.config
			table.insert(samples, {
				labels = labels,
				time = if type(t) == "number" then t else nil,
				value = if n > 0 then field.values[n] else nil,
				unit = if config then config.unit else nil,
				decimals = if config then config.decimals else nil,
			})
		end
	end
	local keys: { string } = {}
	for k in keySet do
		table.insert(keys, k)
	end
	table.sort(keys)

	local showTime = o.show_time ~= false
	-- Value always stays; extra label columns beyond the grid's limit go.
	local room = Grid.MAX_COLUMNS - 1 - (if showTime then 1 else 0) - (if hasName then 1 else 0)
	while #keys > room do
		table.remove(keys)
	end
	local columns: { Grid.Column } = {}
	if showTime then
		table.insert(columns, { head = "Time" })
	end
	if hasName then
		table.insert(columns, { head = "__name__" })
	end
	for _, k in keys do
		table.insert(columns, { head = k })
	end
	table.insert(columns, { head = "Value", numeric = true })

	local rows: { Row } = table.create(#samples)
	for i, s in samples do
		local cells: { string } = {}
		if showTime then
			table.insert(cells, if s.time then Range.formatMs(s.time, o.offset_min) else "")
		end
		if hasName then
			table.insert(cells, s.labels.__name__ or "")
		end
		for _, k in keys do
			table.insert(cells, s.labels[k] or "")
		end
		local value = if type(s.value) == "number" then s.value else nil
		local unit = o.unit or s.unit
		local decimals = if o.decimals ~= nil then o.decimals else s.decimals
		table.insert(cells, if value == nil then M.NO_VALUE else Format.text(value, unit, decimals))
		rows[i] = { labels = s.labels, time = s.time, value = value, cells = cells }
	end
	return columns, rows
end

function M.view(frames: { Frame }, opts: Options?): Node
	local o: Options = opts or {}
	local columns, rows = M.rows(frames, o)
	if #rows == 0 then
		return ui.muted("No data", { key = o.key or "table" })
	end
	local gridRows: { Grid.Row } = table.create(#rows)
	for i, r in rows do
		local cells: { Node } = table.create(#r.cells)
		for k, c in r.cells do
			cells[k] = Grid.text(c)
		end
		gridRows[i] = {
			key = "r" .. i,
			cells = cells,
			action = if o.row_action then o.row_action(i, r.labels) else nil,
		}
	end
	return Grid.grid(o.key or "table", columns, gridRows, "tern-grafana.table")
end

return M
