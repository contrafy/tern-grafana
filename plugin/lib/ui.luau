--!strict
-- Plain-table equivalents of the `tern.ui` builders. Tern accepts `{k, p, c}`
-- tables as nodes (`tern.ui.node(k, p, c)` encodes to the same JSON), and
-- building them in Luau is about 50x cheaper than calling the builders, which
-- matters for large tables and per-frame chart views. Prop names follow the
-- SDK's own encoders.

export type Span = { t: string, s: string?, href: string? }
export type Node = { k: string, p: { [string]: any }?, c: { Node }? }
export type SpanLike = Span | string
export type TreeNode = { id: string, label: { Span }, open: boolean?, children: { TreeNode }? }

local M = {}

-- The builders take ownership of the `props` table and of span lists: they
-- become the node's own (pass fresh tables, as every call site does) instead
-- of being copied.

-- `props` with each default it does not set; `defaults` when no props.
local function own(props: { [string]: any }?, defaults: { [string]: any }): { [string]: any }
	if props == nil then
		return defaults
	end
	for k, v in defaults do
		if props[k] == nil then
			props[k] = v
		end
	end
	return props
end

-- `props` with `k` set to `v` unless it sets `k`; a new table when no props.
local function own1(props: { [string]: any }?, k: string, v: any): { [string]: any }
	if props == nil then
		return { [k] = v }
	end
	if props[k] == nil then
		props[k] = v
	end
	return props
end

function M.span(t: string, s: string?): Span
	if s == nil or s == "" then
		return { t = t }
	end
	return { t = t, s = s }
end

-- The list as spans, converting plain strings in place.
function M.spans(list: { SpanLike }): { Span }
	for i, s in list do
		if type(s) == "string" then
			list[i] = { t = s }
		end
	end
	return list :: any
end

function M.text(list: { SpanLike }, props: { [string]: any }?): Node
	return { k = "text", p = own1(props, "spans", M.spans(list)) }
end

function M.el(tag: string, props: { [string]: any }?, children: { Node }?): Node
	return { k = "el", p = own1(props, "tag", tag), c = children }
end

function M.badge(text: string, tone: string, props: { [string]: any }?): Node
	if props == nil then
		return { k = "badge", p = { text = text, tone = tone } }
	end
	return { k = "badge", p = own1(own1(props, "text", text), "tone", tone) }
end

function M.col(children: { Node }, props: { [string]: any }?): Node
	return { k = "col", p = own1(props, "gap", "sm"), c = children }
end

function M.row(children: { Node }, props: { [string]: any }?): Node
	return { k = "row", p = own1(props, "gap", "sm"), c = children }
end

function M.kv(items: { { { SpanLike } } }): Node
	local out = table.create(#items)
	for i, pair in items do
		out[i] = { k = M.spans(pair[1]), v = M.spans(pair[2]) }
	end
	return { k = "kv", p = { items = out } }
end

function M.card(head: { SpanLike }, children: { Node }, props: { [string]: any }?): Node
	return { k = "card", p = own1(props, "head", M.spans(head)), c = children }
end

function M.section(head: { SpanLike }, children: { Node }, props: { [string]: any }?): Node
	return { k = "section", p = own1(props, "head", M.spans(head)), c = children }
end

function M.code(text: string, lang: string?, start: number?, props: { [string]: any }?): Node
	return { k = "code", p = own(props, { text = text, lang = lang, start = start }) }
end

function M.tree(nodes: { TreeNode }, props: { [string]: any }?): Node
	return { k = "tree", p = own1(props, "nodes", nodes) }
end

function M.lines(children: { Node }, props: { [string]: any }?): Node
	return { k = "lines", p = props or {}, c = children }
end

function M.rule(label: { SpanLike }?, props: { [string]: any }?): Node
	return { k = "rule", p = if label then own1(props, "label", M.spans(label)) else props or {} }
end

function M.muted(text: string, props: { [string]: any }?): Node
	return M.text({ M.span(text, "muted") }, props)
end

return M
