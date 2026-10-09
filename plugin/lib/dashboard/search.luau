--!strict
-- Dashboard search (`/api/search?type=dash-db&query=`) for the picker a
-- dashboard block shows when opened without a uid.

local Env = require("../env")
local Response = require("../source/response")
local TransportTypes = require("../transport/types")

type Env = Env.Env

local M = {}

M.LIMIT = 100

export type Hit = { uid: string, title: string, folder: string?, tags: { string } }

function M.request(query: string): TransportTypes.Request
	local q: { { string } } = { { "type", "dash-db" } }
	if query ~= "" then
		table.insert(q, { "query", query })
	end
	table.insert(q, { "limit", tostring(M.LIMIT) })
	return { method = "GET", path = "/api/search", query = q }
end

function M.parse(response: TransportTypes.Response, env: Env): ({ Hit }?, string?)
	local doc, err = Response.json(response, env, "dashboard search")
	if err then
		return nil, err.message
	end
	local out: { Hit } = {}
	for _, item in doc do
		if type(item) ~= "table" then
			continue
		end
		local uid = Env.value(env, item.uid)
		local title = Env.value(env, item.title)
		if type(uid) ~= "string" or type(title) ~= "string" then
			continue
		end
		local tags: { string } = {}
		local rawTags = Env.value(env, item.tags)
		if type(rawTags) == "table" then
			for _, t in rawTags do
				if type(t) == "string" then
					table.insert(tags, t)
				end
			end
		end
		local folder = Env.value(env, item.folderTitle)
		table.insert(
			out,
			{ uid = uid, title = title, folder = if type(folder) == "string" then folder else nil, tags = tags }
		)
	end
	return out, nil
end

return M
