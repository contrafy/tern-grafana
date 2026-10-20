# Dashboard block: the picker lists every provisioned dashboard, Tern Panels
# opens with its native stat panels. The ladder below the native rung, on the
# e2e-only dashboard tern-ladder (a symlog heatmap the plugin does not draw):
# Grafana 12 renders it as a PNG, Grafana 11 (no image renderer, opened by
# clicking its URL in the shell) offers the browser with the reason.
D=$(surface dashboard)
REASON="heatmap symlog y scale is not drawn natively"
PANEL="Scrape duration symlog heatmap"

open_block dashboard dashboard || return
bwait dashboard "Open a Grafana dashboard" || return
want=$(jq -sc 'map(.title) | sort' "$E2E_REPO"/dev/grafana/dashboards/*.json)
E2E_WAIT=15 wait_for "the dashboard list" has "$D .pk-row" "$(printf '%s' "$want" | jq length)" || return
eq "picker lists the provisioned dashboards" "$(texts "$D .pk-row .pk-label")" "$want"
shot picker

type_text 'Tern Panels'
sleep 0.5
ctl key enter >/dev/null
bwait dashboard "Down targets" || return
contains "title and context" "$(btext dashboard '.sf-text')" "Tern Panels Tern Fixtures Last 1 hour"
# Fitted stat values are SVG images whose alt text is the value.
contains "down targets stat panel" "$(texts "$D .sf-card-head")" '"Down targets"'
has "$D .tgp-stat-value svg[aria-label='1']" || fail "down targets stat value is not 1"
has "$D .tgp-stat-value .sf-image" 2 || fail "stat panels not drawn natively"
shot lab-panels

# panel_card: the ladder panel's card text.
panel_card() { texts "$D .sf-card" | jq -r --arg p "$PANEL" '.[] | select(startswith($p))'; }

reset_pane
click_url "$G12/d/tern-ladder/tern-ladder" || return
E2E_WAIT=20 wait_for "the lab ladder dashboard" has "$D" || return
bwait dashboard "Grafana render: $REASON" || return
contains "opened on context lab" "$(alltext "$D .sf-text" | head -1)" "Tern Ladder Tern Fixtures Last 1 hour lab"
contains "panel on the PNG rung" "$(alltext "$D .sf-card-head")" "$PANEL png"
E2E_WAIT=30 wait_for "Grafana's PNG" has "$D .sf-card .sf-image" || return
shot g12-png

reset_pane
click_url "$G11/d/tern-ladder/tern-ladder" || return
E2E_WAIT=20 wait_for "the g11 ladder dashboard" has "$D" || return
bwait dashboard "Open in browser (o)" || return
contains "opened on context g11" "$(alltext "$D .sf-text" | head -1)" "Tern Ladder Tern Fixtures Last 1 hour g11"
contains "panel on the browser rung" "$(panel_card)" "$PANEL browser"
contains "reason stated" "$(panel_card)" "$REASON; Grafana has no image renderer"
lacks "$D .sf-card .sf-image" || fail "g11 shows an image for the ladder panel"
shot g11-browser
