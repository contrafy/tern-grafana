--!strict
-- Which typed lines count as deploys decides when Grafana gets an annotation
-- and an impact watch opens: wrappers and env prefixes must not hide a deploy,
-- look-alikes must not trigger one, and the namespace/service the impact
-- queries are scoped by must come from the right words. Redaction decides
-- what of the line reaches Grafana, the approve block and logs: nothing that
-- looks like a credential may survive.
local Command = require("../../../plugin/lib/annotations/command")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local DEFAULTS = Command.compileAll(Command.DEFAULT_PATTERNS)

local function match(line: string, patterns: { string }?): Command.Match?
	return Command.match(line, if patterns then Command.compileAll(patterns) else DEFAULTS)
end

describe("annotations command matching", function()
	it("matches every default deploy pattern and names its kind", function()
		local cases: { { string } } = {
			{ "helm upgrade web ./chart", "helm-upgrade" },
			{ "helm install web ./chart", "helm-install" },
			{ "kubectl apply -f deploy.yaml", "kubectl-apply" },
			{ "kubectl rollout restart deployment/web", "kubectl-rollout-restart" },
			{ "kubectl rollout undo deployment/web", "kubectl-rollout-undo" },
			{ "kubectl set image deployment/web web=img:2", "kubectl-set-image" },
			{ "terraform apply -auto-approve", "terraform-apply" },
			{ "tofu apply", "tofu-apply" },
			{ "argocd app sync web", "argocd-app-sync" },
			{ "flux reconcile kustomization apps", "flux-reconcile" },
		}
		for _, c in cases do
			local m = match(c[1])
			expect(m and m.kind).toBe(c[2])
		end
	end)

	it("ignores read-only and look-alike commands", function()
		for _, line in
			{
				"helm list",
				"helm template web ./chart",
				"kubectl get pods",
				"kubectl rollout status deployment/web",
				"terraform plan",
				"echo helm upgrade web",
				"git commit -m 'helm upgrade'",
				"helmfile apply",
				"argocd app get web",
				"",
			}
		do
			expect(match(line)).toBeNil()
		end
	end)

	it("sees through env prefixes and wrappers", function()
		for _, line in
			{
				"FOO=1 helm upgrade web ./chart",
				"KUBECONFIG=/tmp/k FOO=bar kubectl apply -f x.yaml",
				"command kubectl apply -f x.yaml",
				"sudo kubectl apply -f x.yaml",
				"sudo -u deploy -E kubectl apply -f x.yaml",
				"env -i PATH=/bin kubectl apply -f x.yaml",
				"time helm upgrade web ./chart",
				"nohup terraform apply",
				"timeout 5m terraform apply",
				"nice -n 10 helm upgrade web ./chart",
				"/usr/local/bin/helm upgrade web ./chart",
				"exec kubectl apply -f x.yaml",
			}
		do
			expect(match(line) ~= nil).toBe(true)
		end
	end)

	it("skips global flags and their values before the subcommand", function()
		local m = match("kubectl --context prod -n shop apply -f x.yaml")
		expect(m and m.kind).toBe("kubectl-apply")
		expect(m and m.namespace).toBe("shop")
		local h = match("helm --kube-context prod upgrade --install web ./chart")
		expect(h and h.kind).toBe("helm-upgrade")
		expect(h and h.service).toBe("web")
		expect(match("terraform -chdir=infra apply") ~= nil).toBe(true)
	end)

	it("finds the deploy inside a command list or pipeline", function()
		local m = match("cd infra && terraform apply -auto-approve | tee apply.log")
		expect(m and m.kind).toBe("terraform-apply")
		expect(match("make build; helm upgrade web ./chart") ~= nil).toBe(true)
		expect(match("(cd x && kubectl apply -f y.yaml)") ~= nil).toBe(true)
		expect(match("kubectl apply -f y.yaml 2>&1 >/tmp/log") ~= nil).toBe(true)
	end)

	it("derives namespace and service from argv", function()
		local cases: { { any } } = {
			{ "helm upgrade --install web ./chart -n shop", "shop", "web" },
			{ "helm upgrade web ./chart --namespace=shop", "shop", "web" },
			{ "helm install oci://reg/chart --generate-name", nil, nil },
			{ "kubectl rollout restart deployment/api -nshop", "shop", "api" },
			{ "kubectl rollout restart deployment api --namespace shop", "shop", "api" },
			{ "kubectl set image deploy/web web=img:2 -n shop", "shop", "web" },
			{ "kubectl apply -f x.yaml -n shop", "shop", nil },
			{ "argocd app sync payments", nil, "payments" },
			{ "flux reconcile helmrelease podinfo -n apps", "apps", "podinfo" },
			{ "flux reconcile source git flux-system", nil, "flux-system" },
			{ "terraform apply -no-color", nil, nil },
		}
		for _, c in cases do
			local m = match(c[1]) :: Command.Match
			expect(m ~= nil).toBe(true)
			expect(m.namespace).toBe(c[2])
			expect(m.service).toBe(c[3])
		end
	end)

	it("uses configured patterns instead of the defaults, with alternatives", function()
		local custom = { "make deploy|release", "k apply" }
		expect(match("make deploy ENV=prod", custom) and (match("make deploy ENV=prod", custom) :: any).kind).toBe(
			"make-deploy"
		)
		expect(match("make release", custom) ~= nil).toBe(true)
		expect(match("k apply -f x.yaml", custom) ~= nil).toBe(true)
		expect(match("helm upgrade web ./chart", custom)).toBeNil()
		expect(match("helm upgrade web ./chart", {})).toBeNil()
	end)
end)

describe("annotations command redaction", function()
	it("redacts credential-looking values and nothing else", function()
		local cases: { { string } } = {
			{ "helm upgrade web ./chart", "helm upgrade web ./chart" },
			{ "helm upgrade web ./chart --password hunter2", "helm upgrade web ./chart --password ***" },
			{ "argocd login x --auth-token=abc.def", "argocd login x --auth-token=***" },
			{ "kubectl --token abc apply -f x.yaml", "kubectl --token *** apply -f x.yaml" },
			{ "GH_TOKEN=ghp_abc helm upgrade web .", "GH_TOKEN=*** helm upgrade web ." },
			{ "DB_PASSWORD='s3 cr3t' terraform apply", "DB_PASSWORD=*** terraform apply" },
			{ "AWS_SECRET_ACCESS_KEY=xyz terraform apply", "AWS_SECRET_ACCESS_KEY=*** terraform apply" },
			{ "DD_API_KEY=xyz helm upgrade a b", "DD_API_KEY=*** helm upgrade a b" },
			{
				"helm upgrade web . --set image.tag=1.2,db.password=p4ss --set-string auth.token=t",
				"helm upgrade web . --set image.tag=1.2,db.password=*** --set-string auth.token=***",
			},
			{
				"terraform apply -var 'db_password=x' -var region=eu",
				"terraform apply -var db_password=*** -var region=eu",
			},
			{
				"helm upgrade web oci://user:pa55@reg.example/chart",
				"helm upgrade web oci://user:***@reg.example/chart",
			},
			{ "curl -H 'Authorization: Bearer abc' https://x", "curl -H 'Authorization: ***' https://x" },
		}
		for _, c in cases do
			expect(Command.redact(c[1])).toBe(c[2])
		end
	end)

	it("changes only the redacted words and keeps the rest exactly as typed", function()
		expect(Command.redact("sudo -n true 2>/dev/null; GH_TOKEN=abc kubectl set image deploy/web web=$IMG")).toBe(
			"sudo -n true 2>/dev/null; GH_TOKEN=*** kubectl set image deploy/web web=$IMG"
		)
	end)

	it("keeps operators and quotes words it rewrites", function()
		expect(Command.redact("FOO_TOKEN=a helm upgrade 'my app' . && echo done")).toBe(
			"FOO_TOKEN=*** helm upgrade 'my app' . && echo done"
		)
	end)

	it("never leaves the secret anywhere in the output", function()
		local secret = "Zq9-SECRETMARK"
		for _, line in
			{
				"helm upgrade web . --password " .. secret,
				"helm upgrade web . --password=" .. secret,
				"API_TOKEN=" .. secret .. " helm upgrade web .",
				"helm upgrade web . --set a.secretKey=" .. secret,
				"terraform apply -var=client_secret=" .. secret,
				'kubectl apply -f x --token "' .. secret .. '"',
			}
		do
			expect((string.find(Command.redact(line), secret, 1, true))).toBeNil()
		end
	end)
end)

return nil
