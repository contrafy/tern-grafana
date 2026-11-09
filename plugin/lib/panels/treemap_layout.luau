--!strict
-- d3-hierarchy 3.1.2 (the d3 7.9 the treemap panel bundles) as the treemap
-- panel calls it: hierarchy(root).sum(value).sort(value desc), then
-- treemap().tile(tiling).size([w, h]) with its paddings and round. The
-- tilings are d3's: squarify (golden ratio), binary, dice, slice and
-- sliceDice. JavaScript's number semantics are kept where d3 leans on
-- them: a zero or NaN value is falsy, Math.max with a NaN is NaN, and
-- Math.round rounds halves up.

local M = {}

-- A tree as the panel builds it (treemap.ts TreemapNode). `value` is the
-- node's own value (`d.value ?? 0`, leaves only in practice); `data` is
-- carried through for the caller.
export type Input = {
	name: string,
	value: number?,
	children: { Input }?,
	data: any?,
}

-- One laid-out node in d3's descendants() order (breadth first, children
-- after the sort), the root first.
export type Tile = {
	input: Input,
	depth: number,
	-- Summed value (own value plus the children's).
	value: number,
	leaf: boolean,
	x0: number,
	y0: number,
	x1: number,
	y1: number,
}

export type Tiling = "treemapSquarify" | "treemapBinary" | "treemapDice" | "treemapSlice" | "treemapSliceDice"

export type Options = {
	tiling: string?,
	round: boolean?,
	padding_inner: number?,
	padding_top: number?,
	padding_right: number?,
	padding_bottom: number?,
	padding_left: number?,
}

type Node = {
	input: Input,
	depth: number,
	value: number,
	children: { Node }?,
	x0: number,
	y0: number,
	x1: number,
	y1: number,
}

-- A row of squarify: a node-like with a value and children.
type Group = { value: number, depth: number, children: { Node } }

type TileFn = (parent: Group, x0: number, y0: number, x1: number, y1: number) -> ()

M.PHI = (1 + math.sqrt(5)) / 2

-- JavaScript truthiness of a number.
local function truthy(n: number): boolean
	return n ~= 0 and n == n
end

-- Math.max: NaN when either is NaN.
local function jsMax(a: number, b: number): number
	if a ~= a or b ~= b then
		return 0 / 0
	end
	return if a > b then a else b
end

-- Math.round: halves toward +Infinity.
local function jsRound(n: number): number
	return math.floor(n + 0.5)
end

-- `+value || 0`.
local function numberOr0(v: number?): number
	if v == nil or v ~= v then
		return 0
	end
	return v
end

function M.dice(parent: Group, x0: number, y0: number, x1: number, y1: number)
	local nodes = parent.children
	local k = if truthy(parent.value) then (x1 - x0) / parent.value else parent.value
	for _, node in nodes do
		node.y0, node.y1 = y0, y1
		node.x0 = x0
		x0 += node.value * k
		node.x1 = x0
	end
end

function M.slice(parent: Group, x0: number, y0: number, x1: number, y1: number)
	local nodes = parent.children
	local k = if truthy(parent.value) then (y1 - y0) / parent.value else parent.value
	for _, node in nodes do
		node.x0, node.x1 = x0, x1
		node.y0 = y0
		y0 += node.value * k
		node.y1 = y0
	end
end

function M.sliceDice(parent: Group, x0: number, y0: number, x1: number, y1: number)
	if parent.depth % 2 == 1 then
		M.slice(parent, x0, y0, x1, y1)
	else
		M.dice(parent, x0, y0, x1, y1)
	end
end

function M.binary(parent: Group, x0: number, y0: number, x1: number, y1: number)
	local nodes = parent.children
	local n = #nodes
	-- sums[i + 1] is d3's sums[i].
	local sums = table.create(n + 1, 0)
	local sum = 0
	for i = 1, n do
		sum += nodes[i].value
		sums[i + 1] = sum
	end
	local function partition(i: number, j: number, value: number, px0: number, py0: number, px1: number, py1: number)
		if i >= j - 1 then
			local node = nodes[i + 1]
			node.x0, node.y0 = px0, py0
			node.x1, node.y1 = px1, py1
			return
		end
		local valueOffset = sums[i + 1]
		local valueTarget = value / 2 + valueOffset
		local k = i + 1
		local hi = j - 1
		while k < hi do
			local mid = (k + hi) // 2
			if sums[mid + 1] < valueTarget then
				k = mid + 1
			else
				hi = mid
			end
		end
		if valueTarget - sums[k] < sums[k + 1] - valueTarget and i + 1 < k then
			k -= 1
		end
		local valueLeft = sums[k + 1] - valueOffset
		local valueRight = value - valueLeft
		if px1 - px0 > py1 - py0 then
			local xk = if truthy(value) then (px0 * valueRight + px1 * valueLeft) / value else px1
			partition(i, k, valueLeft, px0, py0, xk, py1)
			partition(k, j, valueRight, xk, py0, px1, py1)
		else
			local yk = if truthy(value) then (py0 * valueRight + py1 * valueLeft) / value else py1
			partition(i, k, valueLeft, px0, py0, px1, yk)
			partition(k, j, valueRight, px0, yk, px1, py1)
		end
	end
	partition(0, n, parent.value, x0, y0, x1, y1)
end

-- squarifyRatio: rows that keep the worst aspect ratio from growing, each
-- laid along the shorter side of what is left.
function M.squarifyRatio(ratio: number, parent: Group, x0: number, y0: number, x1: number, y1: number)
	local nodes = parent.children
	local n = #nodes
	local i0, i1 = 0, 0
	local value = parent.value
	while i0 < n do
		local dx, dy = x1 - x0, y1 - y0
		local sumValue: number
		repeat
			i1 += 1
			sumValue = nodes[i1].value
		until truthy(sumValue) or i1 >= n
		local minValue, maxValue = sumValue, sumValue
		local alpha = jsMax(dy / dx, dx / dy) / (value * ratio)
		local beta = sumValue * sumValue * alpha
		local minRatio = jsMax(maxValue / beta, beta / minValue)
		while i1 < n do
			local nodeValue = nodes[i1 + 1].value
			sumValue += nodeValue
			if nodeValue < minValue then
				minValue = nodeValue
			end
			if nodeValue > maxValue then
				maxValue = nodeValue
			end
			beta = sumValue * sumValue * alpha
			local newRatio = jsMax(maxValue / beta, beta / minValue)
			if newRatio > minRatio then
				sumValue -= nodeValue
				break
			end
			minRatio = newRatio
			i1 += 1
		end
		local row: Group = { value = sumValue, depth = parent.depth, children = table.move(nodes, i0 + 1, i1, 1, {}) }
		if dx < dy then
			local rowY0, rowY1 = y0, y1
			if truthy(value) then
				y0 += dy * sumValue / value
				rowY1 = y0
			end
			M.dice(row, x0, rowY0, x1, rowY1)
		else
			local rowX0, rowX1 = x0, x1
			if truthy(value) then
				x0 += dx * sumValue / value
				rowX1 = x0
			end
			M.slice(row, rowX0, y0, rowX1, y1)
		end
		value -= sumValue
		i0 = i1
	end
end

function M.squarify(parent: Group, x0: number, y0: number, x1: number, y1: number)
	M.squarifyRatio(M.PHI, parent, x0, y0, x1, y1)
end

local TILINGS: { [string]: TileFn } = {
	treemapSquarify = M.squarify,
	treemapBinary = M.binary,
	treemapDice = M.dice,
	treemapSlice = M.slice,
	treemapSliceDice = M.sliceDice,
}

-- Whether `name` is one of d3's tilings the panel offers.
function M.isTiling(name: string): boolean
	return TILINGS[name] ~= nil
end

local function build(input: Input, depth: number): Node
	local node: Node = { input = input, depth = depth, value = 0, x0 = 0, y0 = 0, x1 = 0, y1 = 0 }
	local kids = input.children
	if kids and #kids > 0 then
		local children: { Node } = table.create(#kids)
		for i, c in kids do
			children[i] = build(c, depth + 1)
		end
		-- node.sum: own value plus the children's, bottom up.
		local sum = numberOr0(input.value)
		for i = #children, 1, -1 do
			sum += children[i].value
		end
		node.value = sum
		-- node.sort: Array.prototype.sort is stable.
		local order: { [Node]: number } = {}
		for i, c in children do
			order[c] = i
		end
		table.sort(children, function(a: Node, b: Node): boolean
			if a.value ~= b.value then
				return a.value > b.value
			end
			return order[a] < order[b]
		end)
		node.children = children
	else
		node.value = numberOr0(input.value)
	end
	return node
end

-- The laid-out tree in descendants() order. `tiling` defaults to squarify
-- (an unknown one too: d3[tiling] would be undefined and treemap.tile
-- throws, which the panel never offers).
function M.layout(root: Input, width: number, height: number, opts: Options?): { Tile }
	local o: Options = opts or {}
	local tile = TILINGS[o.tiling or ""] or M.squarify
	local inner = (o.padding_inner or 0) / 2
	local pTop, pRight = o.padding_top or 0, o.padding_right or 0
	local pBottom, pLeft = o.padding_bottom or 0, o.padding_left or 0
	local top = build(root, 0)
	top.x0, top.y0, top.x1, top.y1 = 0, 0, width, height
	local paddingStack: { [number]: number } = { [0] = 0 }

	-- positionNode, pre-order.
	local function position(node: Node)
		local p = paddingStack[node.depth] or 0
		local x0, y0, x1, y1 = node.x0 + p, node.y0 + p, node.x1 - p, node.y1 - p
		if x1 < x0 then
			x0 = (x0 + x1) / 2
			x1 = x0
		end
		if y1 < y0 then
			y0 = (y0 + y1) / 2
			y1 = y0
		end
		node.x0, node.y0, node.x1, node.y1 = x0, y0, x1, y1
		local children = node.children
		if children then
			p = inner
			paddingStack[node.depth + 1] = p
			x0 += pLeft - p
			y0 += pTop - p
			x1 -= pRight - p
			y1 -= pBottom - p
			if x1 < x0 then
				x0 = (x0 + x1) / 2
				x1 = x0
			end
			if y1 < y0 then
				y0 = (y0 + y1) / 2
				y1 = y0
			end
			tile(node :: any, x0, y0, x1, y1)
			for _, c in children do
				position(c)
			end
		end
	end
	position(top)

	local out: { Tile } = {}
	local queue: { Node } = { top }
	local head = 1
	while head <= #queue do
		local node = queue[head]
		head += 1
		local x0, y0, x1, y1 = node.x0, node.y0, node.x1, node.y1
		if o.round then
			x0, y0, x1, y1 = jsRound(x0), jsRound(y0), jsRound(x1), jsRound(y1)
		end
		table.insert(out, {
			input = node.input,
			depth = node.depth,
			value = node.value,
			leaf = node.children == nil,
			x0 = x0,
			y0 = y0,
			x1 = x1,
			y1 = y1,
		})
		if node.children then
			for _, c in node.children :: { Node } do
				table.insert(queue, c)
			end
		end
	end
	return out
end

return M
