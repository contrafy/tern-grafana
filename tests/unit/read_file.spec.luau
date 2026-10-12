--!strict
-- Configs managed by stow, chezmoi or home-manager and secrets under
-- sops-nix or agenix are symlinks, which tern.fs.read refuses when given
-- max_bytes. They must still load, the size cap must still hold, and the
-- settings block must know the path is a link before replacing it.
local ReadFile = require("../../plugin/lib/read_file")
local t = require("../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

-- tern.fs.read's documented rules: with max_bytes only a regular file of at
-- most max_bytes; without it any readable path.
local function fs(files: { [string]: { text: string, link: boolean? } })
	local reads = 0
	local function read(path: string, max_bytes: number?): string
		reads += 1
		local f = files[path]
		if f == nil then
			error("No such file or directory")
		end
		if max_bytes ~= nil then
			if f.link then
				error("not a regular file")
			end
			if #f.text > max_bytes then
				error("file too large")
			end
		end
		return f.text
	end
	return read, function(): number
		return reads
	end
end

describe("ReadFile.read", function()
	it("reads a regular file with the bound, in one read", function()
		local read, reads = fs({ ["/c.json"] = { text = "{}" } })
		local text, err, linked = ReadFile.read(read, "/c.json", 10)
		expect(text).toBe("{}")
		expect(err).toBeNil()
		expect(linked).toBe(false)
		expect(reads()).toBe(1)
	end)

	it("reads a symlinked file and says it is a link", function()
		local read = fs({ ["/run/secrets/token"] = { text = "s3cret", link = true } })
		local text, err, linked = ReadFile.read(read, "/run/secrets/token", 10)
		expect(text).toBe("s3cret")
		expect(err).toBeNil()
		expect(linked).toBe(true)
	end)

	it("keeps the size cap for a symlinked file", function()
		local read = fs({ ["/c.json"] = { text = string.rep("x", 11), link = true } })
		local text, err = ReadFile.read(read, "/c.json", 10)
		expect(text).toBeNil()
		expect(err).toContain("larger than 10 bytes")
	end)

	it("refuses an oversize regular file", function()
		local read = fs({ ["/c.json"] = { text = string.rep("x", 11) } })
		local text, err = ReadFile.read(read, "/c.json", 10)
		expect(text).toBeNil()
		expect(err).toContain("larger than 10 bytes")
	end)

	it("passes the reader's error through for a missing file", function()
		local read = fs({})
		local text, err = ReadFile.read(read, "/nope", 10)
		expect(text).toBeNil()
		expect(err).toContain("No such file")
	end)
end)

return nil
