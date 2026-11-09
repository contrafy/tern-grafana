--!strict
-- Alert states of a dashboard's panels, as Grafana 13 shows them in panel
-- headers (public/app/features/dashboard-scene/scene/AlertStatesDataLayer.ts
-- and loadPanelAlertStateCandidates.ts; the icon from @grafana/scenes 9
-- VizPanelRenderer getAlertStateStyles):
--
-- - one `GET /api/prometheus/grafana/api/v1/rules?dashboard_uid=<uid>`
--   (Grafana-managed rules linked to the dashboard), only while the range
--   ends at "now" (canWork: `raw.to !== 'now'` stops the layer);
-- - an alerting rule with a `__panelId__` annotation is a candidate for
--   that panel; the most severe per panel wins (firing > pending > other),
--   the first among equals (selectMostSevereAlertCandidatePerPanel);
-- - promAlertStateToAlertState: firing is "alerting", pending "pending",
--   anything else (inactive, recovering) "ok";
-- - the header icon: heart-break for alerting, heart otherwise, in the
--   error, warning and success text colors.
--
-- A failed request leaves the panels without a state (Grafana notifies
-- and shows no icon).

local Env = require("../env")
local Json = require("../panels/json")
local Response = require("../source/response")
local TransportTypes = require("../transport/types")

type Env = Env.Env

local M = {}

export type State = "alerting" | "pending" | "ok"

M.PATH = "/api/prometheus/grafana/api/v1/rules"
-- Nerd Font glyphs (md-heart, md-heart_broken) for Grafana's heart icons.
M.HEART = utf8.char(0xF02D1)
M.HEART_BREAK = utf8.char(0xF02D4)

function M.request(dashboardUid: string): TransportTypes.Request
	return { method = "GET", path = M.PATH, query = { { "dashboard_uid", dashboardUid } } }
end

-- canWork's range check: the raw `to` of the dashboard range.
function M.applies(to: string?): boolean
	return to == "now"
end

local SEVERITY: { [string]: number } = { firing = 2, pending = 1 }

local function fromProm(state: string): State
	if state == "firing" then
		return "alerting"
	elseif state == "pending" then
		return "pending"
	end
	return "ok"
end

-- The rules answer as each linked panel's state by panel id; nil and the
-- error message when the request failed.
function M.parse(response: TransportTypes.Response, env: Env): ({ [number]: State }?, string?)
	local doc, err = Response.json(response, env, "alert rules")
	if err or doc == nil then
		return nil, if err then err.message else "alert rules: no response"
	end
	local best: { [number]: string } = {}
	for _, g in Json.list(env, Json.path(env, doc, "data", "groups")) do
		for _, r in Json.list(env, Json.path(env, g, "rules")) do
			if Json.str(env, Json.path(env, r, "type")) ~= "alerting" then
				continue
			end
			local raw = Json.str(env, Json.path(env, r, "annotations", "__panelId__"))
			local id = if raw and raw ~= "" then tonumber(raw) else nil
			if id == nil then
				continue
			end
			local state = Json.str(env, Json.path(env, r, "state")) or ""
			local current = best[id]
			if current == nil or (SEVERITY[state] or 0) > (SEVERITY[current] or 0) then
				best[id] = state
			end
		end
	end
	local out: { [number]: State } = {}
	for id, state in best do
		out[id] = fromProm(state)
	end
	return out, nil
end

-- The header icon: a Nerd glyph and its span style.
function M.icon(state: string): (string, string)
	if state == "alerting" then
		return M.HEART_BREAK, "icon error"
	elseif state == "pending" then
		return M.HEART, "icon warning"
	end
	return M.HEART, "icon success"
end

return M
