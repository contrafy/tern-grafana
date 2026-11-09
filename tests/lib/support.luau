--!strict
-- Helpers every block spec needs: an Env with the test JSON codec and kv held
-- in a table, responses from recorded fixtures, effect lookup and view tree
-- search.
local Fixtures = require("./fixtures")
local json = require("./json")

local M = {}

-- An Env with the test codec, `now_ms` 0 and an empty kv; `fields` overrides
-- or adds entries (now_ms, config, ...). Typed `any` so specs can hand it to
-- machines and reach `kv` directly.
function M.env(fields: { [string]: any }?): any
	local kv: { [string]: any } = {}
	local e: { [string]: any } = {
		now_ms = 0,
		decode = json.decode,
		encode = json.encode,
		null = json.null,
		kv = kv,
		kv_get = function(key: string): any
			return kv[key]
		end,
	}
	if fields then
		for k, v in fields do
			e[k] = v
		end
	end
	return e
end

-- Applies kv_set effects the way the runner would.
function M.applyKv(env: any, effects: { any })
	for _, e in effects do
		if e.kind == "kv_set" then
			env.kv[e.key] = e.value
		end
	end
end

-- A response carrying a recorded fixture.
function M.response(path: string, status: number?): any
	return { status = status or 200, headers = {}, body = Fixtures.read(path), timed_out = false }
end

-- A response carrying `body` as is.
function M.body(body: string, status: number?): any
	return { status = status or 200, headers = {}, body = body, timed_out = false }
end

-- The first effect of `kind`.
function M.find(effects: { any }, kind: string): any
	for _, e in effects do
		if e.kind == kind then
			return e
		end
	end
	return nil
end

-- Every effect of `kind`.
function M.all(effects: { any }, kind: string): { any }
	local out = {}
	for _, e in effects do
		if e.kind == kind then
			table.insert(out, e)
		end
	end
	return out
end

-- Depth-first search of a view tree for nodes matching `pred`.
function M.nodes(node: any, pred: (any) -> boolean, out: { any }?): { any }
	local acc = out or {}
	if type(node) ~= "table" then
		return acc
	end
	if pred(node) then
		table.insert(acc, node)
	end
	if type(node.c) == "table" then
		for _, child in node.c do
			M.nodes(child, pred, acc)
		end
	end
	return acc
end

-- The first node whose `p.key` is `key`.
function M.byKey(node: any, key: string): any
	return M.nodes(node, function(n)
		return n.p ~= nil and n.p.key == key
	end)[1]
end

return M
