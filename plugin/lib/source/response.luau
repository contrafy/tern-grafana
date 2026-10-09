--!strict
-- Shared response handling for source parsers: transport failures and HTTP
-- errors through lib/transport/classify, JSON decoding with a parse error
-- that names what was expected.

local Classify = require("../transport/classify")
local Env = require("../env")
local TransportTypes = require("../transport/types")

type Env = Env.Env
type Response = TransportTypes.Response
type QueryError = TransportTypes.QueryError

local M = {}

-- (decoded body or nil, transport/HTTP error or nil). A non-2xx body that is
-- JSON is still returned so callers can surface the server's own error.
function M.json(response: Response, env: Env, what: string): (any, QueryError?)
	local err = Classify.classify(response, env.decode)
	if response.failure or response.status == 0 then
		return nil, err
	end
	local ok, doc = pcall(env.decode, response.body)
	if not ok or type(doc) ~= "table" then
		if err then
			return nil, err
		end
		return nil,
			{
				kind = "parse",
				status = response.status,
				message = string.format("%s: the response is not a JSON object", what),
			}
	end
	return doc, err
end

-- A Prometheus API error body `{status: "error", errorType, error}` as a query
-- error; nil for any other body.
function M.promError(doc: any, env: Env, status: number): QueryError?
	if type(doc) ~= "table" or doc.status ~= "error" then
		return nil
	end
	local message = Env.value(env, doc.error)
	return {
		kind = "query",
		status = status,
		message = if type(message) == "string" and message ~= "" then message else "the query failed",
	}
end

return M
