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

local function withProps(p: { [string]: any }, props: { [string]: any }?): { [string]: any }
	if props then
		for k, v in props do
			p[k] = v
		end
	end
	return p
end

function M.span(t: string, s: string?): Span
	if s == nil or s == "" then
		return { t = t }
	end
	return { t = t, s = s }
end

function M.spans(list: { SpanLike }): { Span }
	local out: { Span } = table.create(#list)
	for i, s in list do
		out[i] = if type(s) == "string" then { t = s } else s
	end
	return out
end

function M.text(list: { SpanLike }, props: { [string]: any }?): Node
	return { k = "text", p = withProps({ spans = M.spans(list) }, props) }
end

function M.el(tag: string, props: { [string]: any }?, children: { Node }?): Node
	return { k = "el", p = withProps({ tag = tag }, props), c = children }
end

function M.badge(text: string, tone: string, props: { [string]: any }?): Node
	return { k = "badge", p = withProps({ text = text, tone = tone }, props) }
end

function M.col(children: { Node }, props: { [string]: any }?): Node
	return { k = "col", p = withProps({ gap = "sm" }, props), c = children }
end

function M.row(children: { Node }, props: { [string]: any }?): Node
	return { k = "row", p = withProps({ gap = "sm" }, props), c = children }
end

function M.kv(items: { { { SpanLike } } }): Node
	local out = table.create(#items)
	for i, pair in items do
		out[i] = { k = M.spans(pair[1]), v = M.spans(pair[2]) }
	end
	return { k = "kv", p = { items = out } }
end

function M.card(head: { SpanLike }, children: { Node }, props: { [string]: any }?): Node
	return { k = "card", p = withProps({ head = M.spans(head) }, props), c = children }
end

function M.section(head: { SpanLike }, children: { Node }, props: { [string]: any }?): Node
	return { k = "section", p = withProps({ head = M.spans(head) }, props), c = children }
end

function M.code(text: string, lang: string?, start: number?, props: { [string]: any }?): Node
	return { k = "code", p = withProps({ text = text, lang = lang, start = start }, props) }
end

function M.tree(nodes: { TreeNode }, props: { [string]: any }?): Node
	return { k = "tree", p = withProps({ nodes = nodes }, props) }
end

function M.lines(children: { Node }, props: { [string]: any }?): Node
	return { k = "lines", p = withProps({}, props), c = children }
end

function M.rule(label: { SpanLike }?, props: { [string]: any }?): Node
	return { k = "rule", p = withProps(if label then { label = M.spans(label) } else {}, props) }
end

function M.muted(text: string, props: { [string]: any }?): Node
	return M.text({ M.span(text, "muted") }, props)
end

return M
