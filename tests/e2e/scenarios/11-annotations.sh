# Deploy annotation on a finished `helm upgrade` (the fake helm in the
# sandbox's bin/; config: annotations on for `helm upgrade`, context lab): the
# approve block opens beside the shell with exactly what would be posted, and
# Dismiss closes it. Grafana must hold exactly the helm-upgrade annotations it
# held before (the e2e suite never posts one).
AN=$(surface annotate)
helm_annotations() { g12_api '/api/annotations?tags=helm-upgrade&limit=1000' | jq -c '[.[].id] | sort'; }
before=$(helm_annotations) || {
	fail "cannot list Grafana annotations"
	return
}

sh_line clear
type_line "helm upgrade e2e-web ./chart -n e2e"
E2E_WAIT=20 wait_for "the approve block" has "$AN" || return
bwait annotate "Dismiss" || return
contains "context named" "$(btext annotate '.sf-row')" "Annotate deploy in lab"
contains "kind and exit" "$(texts "$AN .sf-badge")" '["helm-upgrade","exit 0"]'
contains "text to post" "$(btext annotate '.tg-an-text')" "helm upgrade e2e-web ./chart -n e2e succeeded after"
contains "target Grafana" "$(btext annotate '.sf-kv-item')" "Grafana$G12"
contains "tags" "$(btext annotate '.sf-kv-item')" "Tagstern, deploy, helm-upgrade"
eq "choices" "$(texts "$AN .tg-an-btn")" '["Always","Once","Never","Dismiss"]'
shot approve

click_text Dismiss "$AN .tg-an-btn" || return
E2E_WAIT=10 wait_for "the approve block to close" lacks "$AN"
eq "nothing posted to Grafana" "$(helm_annotations)" "$before"
