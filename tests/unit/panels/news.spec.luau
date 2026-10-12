--!strict
-- The news panel (public/app/plugins/panel/news at v12.4.0: feed.ts, rss.ts,
-- atom.ts, utils.ts feedToDataFrame, component/News.tsx) over the RSS feed
-- both Grafanas serve for panel 32 of tern-all-panels.
local t = require("../../lib/test")
local S = require("./support")
local Fixtures = require("../../lib/fixtures")
local News = require("../../../plugin/lib/panels/news")
local Registry = require("../../../plugin/lib/panels/registry")
local Scheme = require("../../../plugin/lib/links/scheme")
local describe, it, expect = t.describe, t.it, t.expect

local CTX = { time = { from_ms = 0, to_ms = 1 }, dashboard_uid = "tern-all-panels" }

local function panel(version: string): any
	for _, p in S.decode("grafana/" .. version .. "/dashboard_tern_all_panels.json").dashboard.panels do
		if p.id == 32 then
			return p
		end
	end
	error("no news panel")
end

local function response(body: string, status: number?): any
	return { status = status or 200, headers = {}, body = body, timed_out = false }
end

for _, version in S.VERSIONS do
	describe("news " .. version, function()
		local body = Fixtures.read("grafana/" .. version .. "/news_feed.xml")

		it("reads a relative feed URL from the dashboard's Grafana", function()
			local p = panel(version)
			expect((Registry.supports(p, S.env))).toBe(true)
			expect(Registry.queries(p, S.env)).toBe(false)
			local reqs = Registry.requests(p, CTX, S.env)
			expect(#reqs).toBe(1)
			expect(reqs[1].signal).toBe("dashboards")
			expect(reqs[1].request.path).toBe("/public/tern-news/feed.xml")
		end)

		it("takes title, link, text content and date from each RSS item", function()
			local items = (News.parse(nil, "feed", response(body), S.env) :: any).items
			expect(#items).toBe(3)
			expect(items[1].title).toBe("Checkout latency back to normal")
			expect(items[1].link).toBe("https://example.com/status/checkout-latency")
			-- CDATA HTML loses its tags, as feedToDataFrame strips them.
			expect(items[1].content).toBe("p95 latency for checkout dropped below 400 ms after the cache rollout.")
			expect(items[3].content).toBe("Organization-wide maintenance finished on schedule.")
		end)

		it("shows MMM DD, the title as a browser link and the text", function()
			local node = Registry.view(panel(version), {}, S.env, {
				key = "p",
				local_offset_min = 0,
				extra = { feed = News.parse(nil, "feed", response(body), S.env) },
			})
			local text = S.text(node)
			expect(text).toContain("Jul 07Checkout latency back to normalp95 latency")
			expect(text).toContain("Jul 06Payments error budget at 80 percent")
			expect(text).toContain("Jul 03Maintenance window completed")
			local title = S.find(node, function(x: any): boolean
				return x.k == "text" and x.p.key == "t"
			end)
			local l = Scheme.decode(title.p.spans[1].href) :: any
			expect(l.action).toBe("browse")
			expect(l.params.url).toBe("https://example.com/status/checkout-latency")
		end)
	end)
end

describe("news", function()
	it("fetches an absolute feed as an external GET and Grafana's blog by default", function()
		local reqs =
			Registry.requests({ type = "news", options = { feedUrl = "https://example.com/a.xml?x=1" } }, CTX, S.env)
		expect(reqs[1].signal).toBe("external")
		expect(reqs[1].request.path).toBe("https://example.com/a.xml?x=1")
		local def = Registry.requests({ type = "news", options = {} }, CTX, S.env)
		expect(def[1].request.path).toBe(News.DEFAULT_FEED_URL)
	end)

	it("splits a Grafana path's query string into pairs", function()
		local reqs = Registry.requests({ type = "news", options = { feedUrl = "/api/feed?a=b%20c&d" } }, CTX, S.env)
		expect(reqs[1].request.path).toBe("/api/feed")
		expect(reqs[1].request.query).toEqual({ { "a", "b c" }, { "d", "" } })
	end)

	it("is not native for a URL relative to the browser page", function()
		local ok, why = Registry.supports({ type = "news", options = { feedUrl = "feed.xml" } }, S.env)
		expect(ok).toBe(false)
		expect(why).toContain("feed.xml")
	end)

	it("reads Atom entries: link href, content, published else updated", function()
		local atom = [[<?xml version="1.0"?>
<feed xmlns="http://www.w3.org/2005/Atom"><title>F</title>
<entry><title>One &amp; two</title><link rel="alternate" href="https://e.x/1"/>
<content type="html">&lt;b&gt;Bold&lt;/b&gt; text</content><updated>2026-07-01T10:00:00Z</updated></entry>
<entry><title>Two</title><link href="https://e.x/2"/><published>2026-07-02T23:30:00-02:00</published></entry>
</feed>]]
		local items = News.parseFeed(atom) :: any
		expect(#items).toBe(2)
		expect(items[1].title).toBe("One & two")
		expect(items[1].link).toBe("https://e.x/1")
		expect(items[1].content).toBe("Bold text")
		expect(items[1].date_ms).toBe(1782900000000)
		expect(items[2].date_ms).toBe(1783042200000)
	end)

	it("parses RFC 822 dates with offsets and zone names, else an invalid date", function()
		expect(News.parseDate("Tue, 07 Jul 2026 09:30:00 GMT")).toBe(1783416600000)
		expect(News.parseDate("07 Jul 2026 11:30 +0200")).toBe(1783416600000)
		expect(News.parseDate("Tue, 07 Jul 2026 05:30:00 EDT")).toBe(1783416600000)
		expect(News.parseDate("")).toBeNil()
		expect(News.parseDate("yesterday")).toBeNil()
	end)

	it("does not expand DTD entities and bounds the feed size", function()
		local evil = [[<?xml version="1.0"?><!DOCTYPE r [<!ENTITY x "boom">]><rss><channel>
<item><title>&x;</title><link>javascript:alert(1)</link></item></channel></rss>]]
		local items = News.parseFeed(evil) :: any
		expect(items[1].title).toBe("&x;")
		expect(News.link(items[1].link)).toBeNil()
		local big, err = News.parseFeed(string.rep("a", News.MAX_BYTES + 1))
		expect(big).toBeNil()
		expect(err).toContain("KiB")
	end)

	it("shows Grafana's error title when the feed cannot be read", function()
		local node = Registry.view({ type = "news", options = {} }, {}, S.env, {
			key = "p",
			extra = { feed = News.parse(nil, "feed", response("nope", 404), S.env) },
		})
		expect(S.text(node)).toContain("Error loading RSS feed")
		expect(S.text(node)).toContain("404")
	end)
end)

return nil
