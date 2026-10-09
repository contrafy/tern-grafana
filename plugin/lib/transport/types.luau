--!strict
-- HTTP request/response shapes shared by every source module and the host
-- transport adapter.

-- `path` is already percent-encoded where needed (see http.escape for
-- segments) and is joined under the endpoint's url and path_prefix.
-- `query` pairs keep their order; a key may repeat (match[]).
export type Request = {
	method: string,
	path: string,
	query: { { string } }?,
	headers: { [string]: string }?,
	body: string?,
}

export type QueryError = {
	kind: "auth" | "network" | "timeout" | "http" | "parse" | "query" | "unsupported",
	message: string,
	status: number?,
}

-- Same shape as tern.fetch's result, whichever transport produced it.
-- `failure` is set when the request never left the plugin (credentials could
-- not be resolved, curl could not run); classify returns it as is.
export type Response = {
	status: number,
	headers: { [string]: string },
	body: string,
	error: string?,
	timed_out: boolean,
	failure: QueryError?,
}

return nil
