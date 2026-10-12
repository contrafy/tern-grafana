--!strict
-- Per-context consent to post deploy annotations, remembered in kv
-- `tern-grafana.annotations.approval` as `{ [context] = "always" | "never" }`.
-- No entry means ask: the approve block offers Always / Once / Never, and
-- "Once" posts without remembering anything, so the next deploy asks again.

local M = {}

M.KEY = "tern-grafana.annotations.approval"

export type Remembered = "always" | "never"
export type Approvals = { [string]: Remembered }
export type Choice = "always" | "once" | "never"
export type Decision = "post" | "ask" | "skip"

-- The kv value, keeping only well-formed entries.
function M.read(raw: any): Approvals
	local out: Approvals = {}
	if type(raw) ~= "table" then
		return out
	end
	for ctx, v in raw do
		if type(ctx) == "string" and (v == "always" or v == "never") then
			out[ctx] = v
		end
	end
	return out
end

-- What to do for a matching command in `context`.
function M.decide(approvals: Approvals, context: string): Decision
	local v = approvals[context]
	if v == "always" then
		return "post"
	elseif v == "never" then
		return "skip"
	end
	return "ask"
end

-- The kv value after the user chose `choice` for `context`, or nil when it
-- does not change (Once remembers nothing).
function M.apply(raw: any, context: string, choice: Choice): Approvals?
	if choice == "once" then
		return nil
	end
	local out = M.read(raw)
	out[context] = choice :: Remembered
	return out
end

-- The kv value with `context`'s decision forgotten (it asks again).
function M.forget(raw: any, context: string): Approvals
	local out = M.read(raw)
	out[context] = nil
	return out
end

-- Contexts with a remembered decision, sorted.
function M.list(approvals: Approvals): { { context: string, decision: Remembered } }
	local out: { { context: string, decision: Remembered } } = {}
	for ctx, v in approvals do
		table.insert(out, { context = ctx, decision = v :: Remembered })
	end
	table.sort(out, function(a, b)
		return a.context < b.context
	end)
	return out
end

return M
