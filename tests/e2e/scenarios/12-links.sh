# Grafana URL routing: clicking a Grafana 12 dashboard URL printed in the shell
# opens the native Dashboard block on context lab with the URL's range; a
# /d-solo/ URL opens the Panel block on that one panel.
D=$(surface dashboard)
P=$(surface panel)

click_url "$G12/d/tern-variables/tern-variables?orgId=1&from=now-6h&to=now" || return
E2E_WAIT=20 wait_for "the dashboard block" has "$D" || return
bwait dashboard "Tern Variables" '.sf-text' || return
contains "dashboard, range and context from the URL" "$(alltext "$D .sf-text" | head -1)" \
	"Tern Variables Tern Fixtures Last 6 hours every 30s lab"
shot dashboard

reset_pane
click_url "$G12/d-solo/tern-panels/tern-panels?orgId=1&panelId=6" || return
E2E_WAIT=20 wait_for "the panel block" has "$P" || return
bwait panel "Down targets" '.sf-card-head' || return
eq "only that panel" "$(texts "$P .sf-card-head")" '["Down targets"]'
# The fitted value is an SVG image; its alt text is the value.
has "$P .tgp-stat-value svg[aria-label='1']" || fail "its native stat value is not 1"
shot panel
