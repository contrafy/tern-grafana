--!strict
-- Reads a typed shell command line (as Tern's `command_started` and
-- `command_finished` report it: typed, not alias-expanded) far enough to say
-- whether it is a deploy the user wants annotated, and to show it safely.
--
-- Matching: the line is split into simple commands at `;`, `&&`, `||`, `|`,
-- `&` and parentheses; wrappers (`FOO=1`, `env`, `sudo`, `doas`, `command`,
-- `exec`, `time`, `nohup`, `nice`, `timeout`, `noglob`) are skipped; the
-- program's basename and its leading subcommand words (global flags and their
-- values skipped) must equal a pattern such as "helm upgrade" or
-- "kubectl rollout restart|undo" (`|` separates alternatives of one word).
--
-- Redaction: values of flags, assignments and `k=v` lists whose name looks
-- like a credential, `Authorization:`-style header values and URL passwords
-- become `***`. Only a redacted line ever leaves this module for display or
-- an annotation.

local M = {}

-- `s`..`e`: the token's bytes in the line as typed (quotes included).
export type Token = { text: string, op: boolean, s: number, e: number }

-- One alternative list per word: { {"kubectl"}, {"rollout"}, {"restart", "undo"} }.
export type Pattern = { source: string, words: { { string } } }

export type Match = {
	-- The matched words joined by "-" ("helm-upgrade", "kubectl-rollout-restart").
	kind: string,
	-- The pattern that matched, as configured.
	pattern: string,
	-- The simple command's words after the wrappers (unredacted; never shown).
	argv: { string },
	namespace: string?,
	service: string?,
}

M.REDACTED = "***"

M.DEFAULT_PATTERNS = table.freeze({
	"helm upgrade",
	"helm install",
	"kubectl apply",
	"kubectl rollout restart|undo",
	"kubectl set image",
	"terraform apply",
	"tofu apply",
	"argocd app sync",
	"flux reconcile",
})

-- Lines longer than this are not parsed (a pasted heredoc is not a deploy).
M.MAX_LINE = 8192

-- Tokenizer -------------------------------------------------------------------------

local OPERATORS = { "&&", "||", ";;", ";", "|", "&", "(", ")", "\n" }

-- Splits `line` into words (quotes and backslashes removed) and operators.
-- Unterminated quotes run to the end of the line.
function M.tokenize(line: string): { Token }
	local out: { Token } = {}
	local i, n = 1, #line
	local buf: { string } = {}
	local inWord = false
	local start = 1
	local function begin()
		if not inWord then
			inWord = true
			start = i
		end
	end
	local function flush()
		if inWord then
			table.insert(out, { text = table.concat(buf), op = false, s = start, e = i - 1 })
			table.clear(buf)
			inWord = false
		end
	end
	while i <= n do
		local c = string.sub(line, i, i)
		if c == " " or c == "\t" or c == "\r" then
			flush()
			i += 1
		elseif c == "'" then
			begin()
			local close = string.find(line, "'", i + 1, true) or (n + 1)
			table.insert(buf, string.sub(line, i + 1, close - 1))
			i = close + 1
		elseif c == '"' then
			begin()
			i += 1
			while i <= n do
				local d = string.sub(line, i, i)
				if d == '"' then
					i += 1
					break
				elseif d == "\\" and i < n and string.find('"\\$`', string.sub(line, i + 1, i + 1), 1, true) then
					table.insert(buf, string.sub(line, i + 1, i + 1))
					i += 2
				else
					table.insert(buf, d)
					i += 1
				end
			end
		elseif c == "\\" then
			begin()
			if i < n and string.sub(line, i + 1, i + 1) ~= "\n" then
				table.insert(buf, string.sub(line, i + 1, i + 1))
			end
			i += 2
		else
			local op: string? = nil
			for _, o in OPERATORS do
				if string.sub(line, i, i + #o - 1) == o then
					op = o
					break
				end
			end
			-- `2>&1` and `&>` are redirections, not background operators.
			if op == "&" and (string.sub(line, i - 1, i - 1) == ">" or string.sub(line, i + 1, i + 1) == ">") then
				op = nil
			end
			if op then
				flush()
				table.insert(out, { text = op, op = true, s = i, e = i + #op - 1 })
				i += #op
			else
				begin()
				table.insert(buf, c)
				i += 1
			end
		end
	end
	flush()
	return out
end

-- The simple commands of a line: word lists between operators.
function M.commands(tokens: { Token }): { { string } }
	local out: { { string } } = {}
	local cur: { string } = {}
	for _, t in tokens do
		if t.op then
			if #cur > 0 then
				table.insert(out, cur)
				cur = {}
			end
		else
			table.insert(cur, t.text)
		end
	end
	if #cur > 0 then
		table.insert(out, cur)
	end
	return out
end

-- Wrappers --------------------------------------------------------------------------

local function isAssignment(w: string): boolean
	return string.match(w, "^[%a_][%w_]*=") ~= nil
end

local function isFlag(w: string): boolean
	return #w > 1 and string.sub(w, 1, 1) == "-"
end

-- Wrapper -> its flags that take a separate value.
local WRAPPERS: { [string]: { [string]: boolean } } = {
	sudo = {
		["-u"] = true,
		["-g"] = true,
		["-h"] = true,
		["-p"] = true,
		["-C"] = true,
		["-r"] = true,
		["-t"] = true,
		["-U"] = true,
		["-D"] = true,
		["-T"] = true,
		["--user"] = true,
		["--group"] = true,
		["--host"] = true,
		["--prompt"] = true,
		["--chdir"] = true,
	},
	doas = { ["-u"] = true, ["-C"] = true },
	env = { ["-u"] = true, ["-C"] = true, ["-S"] = true, ["--unset"] = true, ["--chdir"] = true },
	command = {},
	builtin = {},
	exec = { ["-a"] = true },
	noglob = {},
	nohup = {},
	time = {},
	nice = { ["-n"] = true },
	timeout = { ["-s"] = true, ["-k"] = true, ["--signal"] = true, ["--kill-after"] = true },
}

local function basename(path: string): string
	return string.match(path, "([^/]+)/*$") or path
end

-- The last path segment ("/srv/shop/" -> "shop"; "/" stays "/").
M.basename = basename

-- The command's words after leading assignments and wrappers.
function M.unwrap(words: { string }): { string }
	local i = 1
	while i <= #words do
		local w = words[i]
		if isAssignment(w) or w == "!" then
			i += 1
			continue
		end
		local name = basename(w)
		local flags = WRAPPERS[name]
		if flags == nil then
			break
		end
		i += 1
		while i <= #words do
			local a = words[i]
			if a == "--" then
				i += 1
				break
			elseif isFlag(a) then
				i += if flags[a] then 2 else 1
			elseif name == "env" and isAssignment(a) then
				i += 1
			else
				break
			end
		end
		-- `timeout 5m cmd`: the duration is the wrapper's operand.
		if name == "timeout" and i <= #words then
			i += 1
		end
	end
	return table.move(words, i, #words, 1, {})
end

-- Patterns --------------------------------------------------------------------------

-- Global flags (kubectl, helm, argocd, flux, terraform) whose value is a
-- separate word: skipped when finding subcommand words and positionals.
local VALUE_FLAGS: { [string]: boolean } = {}
for _, f in
	{
		"-n",
		"--namespace",
		"--context",
		"--kube-context",
		"--kubeconfig",
		"--cluster",
		"--user",
		"-s",
		"--server",
		"--as",
		"--as-group",
		"--token",
		"--auth-token",
		"--request-timeout",
		"--config",
		"-f",
		"--filename",
		"--values",
		"--set",
		"--set-string",
		"--set-file",
		"--set-json",
		"--version",
		"--timeout",
		"-o",
		"--output",
		"-l",
		"--selector",
		"-var",
		"--var",
		"-var-file",
		"--revision",
		"--repo",
		"-k",
		"--kustomize",
		"--grpc-web-root-path",
		"--port-forward-namespace",
		"--app-namespace",
		"--project",
		"--field-manager",
	}
do
	VALUE_FLAGS[f] = true
end

local function isRedirect(w: string): boolean
	return string.match(w, "^%d*[<>]") ~= nil or string.match(w, "^&>") ~= nil
end

-- Positional words after the program: flags, their values and redirections
-- skipped.
local function positionals(argv: { string }): { string }
	local out: { string } = {}
	local i = 2
	while i <= #argv do
		local w = argv[i]
		if w == "--" then
			table.move(argv, i + 1, #argv, #out + 1, out)
			break
		elseif isRedirect(w) then
			-- `> file` takes the next word; `>file` and `2>&1` do not.
			i += if string.match(w, "^%d*[<>]+&?$") or w == "&>" then 2 else 1
		elseif isFlag(w) then
			i += if VALUE_FLAGS[w] then 2 else 1
		else
			table.insert(out, w)
			i += 1
		end
	end
	return out
end

-- Parses "kubectl rollout restart|undo"; nil for an empty pattern.
function M.compile(source: string): Pattern?
	local words: { { string } } = {}
	for word in string.gmatch(source, "%S+") do
		local alts: { string } = {}
		for alt in string.gmatch(word, "[^|]+") do
			table.insert(alts, alt)
		end
		if #alts == 0 then
			return nil
		end
		table.insert(words, alts)
	end
	if #words == 0 then
		return nil
	end
	return { source = source, words = words }
end

function M.compileAll(sources: { string }): { Pattern }
	local out: { Pattern } = {}
	for _, s in sources do
		local p = M.compile(s)
		if p then
			table.insert(out, p)
		end
	end
	return out
end

-- Namespace and service derivation -------------------------------------------------

-- Kubernetes object names and namespaces (DNS subdomain characters).
local function k8sName(v: string?): string?
	if v == nil or #v == 0 or #v > 253 then
		return nil
	end
	return if string.match(v, "^[%w][%w_.%-]*$") then v else nil
end

-- Programs whose `-n<ns>` (no space) is the namespace shorthand; terraform's
-- single-dash flags (`-no-color`) must not read as one.
local SHORT_NAMESPACE = { kubectl = true, helm = true, flux = true, argocd = true, oc = true }

local function namespaceOf(argv: { string }): string?
	local short = SHORT_NAMESPACE[basename(argv[1])] == true
	for i = 2, #argv do
		local w = argv[i]
		if w == "-n" or w == "--namespace" then
			return k8sName(argv[i + 1])
		end
		local v = string.match(w, "^%-%-namespace=(.*)$") or string.match(w, "^%-n=(.*)$")
		if v then
			return k8sName(v)
		end
		local glued = if short then string.match(w, "^%-n([%w].*)$") else nil
		if glued then
			return k8sName(glued)
		end
	end
	return nil
end

-- `deployment/web` -> web; `deployment web` -> web.
local function resourceName(rest: { string }): string?
	local first = rest[1]
	if first == nil then
		return nil
	end
	local slash = string.match(first, "/([^/]+)$")
	if slash then
		return k8sName(slash)
	end
	return k8sName(rest[2])
end

-- A plain name (helm release, argocd app), not a path or chart reference.
local function plainName(v: string?): string?
	if v == nil or string.find(v, "[/:]") or string.sub(v, 1, 1) == "." then
		return nil
	end
	return k8sName(v)
end

local SERVICE: { [string]: (rest: { string }) -> string? } = {
	["helm upgrade"] = function(rest)
		return plainName(rest[1])
	end,
	["helm install"] = function(rest)
		return plainName(rest[1])
	end,
	["kubectl rollout restart"] = resourceName,
	["kubectl rollout undo"] = resourceName,
	["kubectl set image"] = resourceName,
	["argocd app sync"] = function(rest)
		return plainName(rest[1])
	end,
	["flux reconcile"] = function(rest)
		if rest[1] == "source" then
			return k8sName(rest[3])
		end
		return k8sName(rest[2])
	end,
}

local function matchWords(p: Pattern, argv: { string }, pos: { string }): { string }?
	local program = basename(argv[1])
	if not table.find(p.words[1], program) then
		return nil
	end
	local matched = { program }
	for k = 2, #p.words do
		local w = pos[k - 1]
		if w == nil or not table.find(p.words[k], w) then
			return nil
		end
		table.insert(matched, w)
	end
	return matched
end

-- The first simple command of `line` that a pattern matches.
function M.match(line: string, patterns: { Pattern }): Match?
	if #line > M.MAX_LINE or #patterns == 0 then
		return nil
	end
	for _, words in M.commands(M.tokenize(line)) do
		local argv = M.unwrap(words)
		if #argv == 0 then
			continue
		end
		local pos = positionals(argv)
		for _, p in patterns do
			local matched = matchWords(p, argv, pos)
			if matched then
				local key = table.concat(matched, " ")
				local derive = SERVICE[key]
				local rest = table.move(pos, #matched, #pos, 1, {})
				return {
					kind = table.concat(matched, "-"),
					pattern = p.source,
					argv = argv,
					namespace = namespaceOf(argv),
					service = if derive then derive(rest) else nil,
				}
			end
		end
	end
	return nil
end

-- Redaction -------------------------------------------------------------------------

local SECRET_WORDS = {
	"password",
	"passwd",
	"passphrase",
	"token",
	"secret",
	"apikey",
	"api-key",
	"api_key",
	"credential",
	"private-key",
	"private_key",
	"privatekey",
	"access-key",
	"access_key",
}

-- Whether a flag, variable or key name looks like it holds a credential.
function M.isSecretName(name: string): boolean
	local lower = string.lower(name)
	for _, w in SECRET_WORDS do
		if string.find(lower, w, 1, true) then
			return true
		end
	end
	-- FOO_KEY=, db.key=: a bare `key` suffix (not `keyring`, `key-file`).
	return string.match(lower, "[_.%-]key$") ~= nil or lower == "key"
end

-- `a=1,b.password=2` -> `a=1,b.password=***`; nil when nothing changed.
local function redactPairs(v: string): string?
	local changed = false
	local parts: { string } = {}
	for part in string.gmatch(v .. ",", "([^,]*),") do
		local k = string.match(part, "^([^=]+)=")
		if k and M.isSecretName(k) then
			table.insert(parts, k .. "=" .. M.REDACTED)
			changed = true
		else
			table.insert(parts, part)
		end
	end
	return if changed then table.concat(parts, ",") else nil
end

local function redactUrl(v: string): string?
	local pre, user, post = string.match(v, "^(.-://)([^/@:]*):[^/@]*@(.*)$")
	if pre then
		return (pre :: string) .. (user :: string) .. ":" .. M.REDACTED .. "@" .. (post :: string)
	end
	return nil
end

-- `Authorization: Bearer x` (one quoted word) -> `Authorization: ***`.
local function redactHeader(v: string): string?
	local name = string.match(v, "^([%w%-_]+):")
	if name and (string.lower(name) == "authorization" or string.lower(name) == "cookie" or M.isSecretName(name)) then
		return name .. ": " .. M.REDACTED
	end
	return nil
end

-- The redacted value of one word, or nil when it needs none.
local function redactWord(w: string): string?
	local flag, value = string.match(w, "^(%-%-?[%w][%w%-_.]*)=(.*)$")
	if flag then
		if M.isSecretName(flag) then
			return flag .. "=" .. M.REDACTED
		end
		local inner = redactPairs(value :: string) or redactUrl(value :: string)
		return if inner then flag .. "=" .. inner else nil
	end
	return redactPairs(w) or redactUrl(w) or redactHeader(w)
end

local SAFE_WORD = "^[%w%%+,./:=@_%-%*]+$"

local function quote(w: string): string
	if w ~= "" and string.match(w, SAFE_WORD) then
		return w
	end
	return "'" .. string.gsub(w, "'", "'\\''") .. "'"
end

-- `line` with secret-looking values replaced by `***`. Only redacted words
-- change (re-quoted); everything else stays exactly as typed.
function M.redact(line: string): string
	local tokens = M.tokenize(line)
	local changed: { Token } = {}
	local secretNext = false
	for _, t in tokens do
		if t.op then
			secretNext = false
			continue
		end
		if secretNext and not isFlag(t.text) then
			t.text = M.REDACTED
			table.insert(changed, t)
			secretNext = false
			continue
		end
		secretNext = false
		if isFlag(t.text) and not string.find(t.text, "=", 1, true) then
			secretNext = M.isSecretName(t.text)
		else
			local r = redactWord(t.text)
			if r then
				t.text = r
				table.insert(changed, t)
			end
		end
	end
	if #changed == 0 then
		return line
	end
	local parts: { string } = {}
	local pos = 1
	for _, t in changed do
		table.insert(parts, string.sub(line, pos, t.s - 1))
		table.insert(parts, quote(t.text))
		pos = t.e + 1
	end
	table.insert(parts, string.sub(line, pos))
	return table.concat(parts)
end

return M
