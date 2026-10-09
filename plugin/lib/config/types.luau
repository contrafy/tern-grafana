--!strict
-- Validated shape of the user's config file (docs/configuration.md). The file
-- only describes where secrets come from; no field ever holds one.

-- Where a token or password is read from, in the host half, on demand.
export type SecretSource =
	{ from: "cmd", field: string, argv: { string } }
	| { from: "env", field: string, name: string }
	| { from: "file", field: string, path: string }

export type Auth =
	{ type: "none" }
	| { type: "bearer", token: SecretSource }
	| { type: "basic", username: string, password: SecretSource }

-- Absent when no TLS option is set; any present field forces the curl transport.
export type Tls = {
	ca_file: string?,
	cert_file: string?,
	key_file: string?,
	insecure: boolean,
}

export type EndpointName = "grafana" | "prometheus" | "alertmanager" | "loki" | "tempo"

-- Datasource uids Grafana routes each signal through when no direct endpoint is set.
export type Datasources = {
	prometheus: string?,
	loki: string?,
	tempo: string?,
	alertmanager: string?,
}

export type Endpoint = {
	-- http(s) URL without a trailing slash, query or fragment.
	url: string,
	auth: Auth,
	-- Non-secret extra headers (for example X-Scope-OrgID).
	headers: { [string]: string },
	-- "" or "/seg/seg": no trailing slash.
	path_prefix: string,
	tls: Tls?,
	timeout_ms: number,
	-- Grafana only.
	org_id: number?,
	datasources: Datasources?,
	browser_url: string?,
}

export type Context = {
	name: string,
	grafana: Endpoint?,
	prometheus: Endpoint?,
	alertmanager: Endpoint?,
	loki: Endpoint?,
	tempo: Endpoint?,
}

export type Config = {
	version: number,
	default_context: string?,
	contexts: { [string]: Context },
	-- Feature sections owned by later milestones, kept exactly as decoded.
	query: any,
	alerts: any,
	annotations: any,
	impact: any,
	watches: any,
	hosts: any,
}

export type Problem = { path: string, message: string }

export type Signal = "metrics" | "logs" | "traces" | "alerts" | "dashboards" | "annotations"

return nil
