# Dashboard block: the picker lists the three provisioned dashboards, Tern
# Panels opens with its native stat panels. The same dashboard on Grafana 11
# (no image renderer), opened by clicking its URL in the shell, shows the
# heatmap on the browser rung with the reason.
D=$(surface dashboard)

open_block dashboard dashboard || return
bwait dashboard "Open a Grafana dashboard" || return
E2E_WAIT=15 wait_for "the dashboard list" has "$D .pk-row" 3 || return
eq "picker lists the provisioned dashboards" "$(texts "$D .pk-row .pk-label")" \
	'["Tern Logs and Traces","Tern Panels","Tern Variables"]'
shot picker

type_text Panels
sleep 0.5
ctl key enter >/dev/null
bwait dashboard "Down targets" || return
contains "title and context" "$(btext dashboard '.sf-text')" "Tern Panels Tern Fixtures Last 1 hour"
contains "down targets stat value" "$(texts "$D .sf-card")" '"Down targets1"'
has "$D .tgp-stat-value" 2 || fail "stat panels not drawn natively"

reset_pane
click_url "$G11/d/tern-panels/tern-panels" || return
E2E_WAIT=20 wait_for "the g11 dashboard block" has "$D" || return
bwait dashboard "Span latency heatmap" || return
contains "opened on context g11" "$(btext dashboard '.sf-text')" "Tern Panels Tern Fixtures Last 1 hour every 30s g11"
heat=$(texts "$D .sf-card" | jq -r '.[] | select(startswith("Span latency heatmap"))')
contains "heatmap on the browser rung" "$heat" "browser"
contains "heatmap reason" "$heat" "heatmap panels are not rendered natively yet; Grafana has no image renderer"
contains "browser action offered" "$heat" "Open in browser (o)"
shot g11-heatmap
