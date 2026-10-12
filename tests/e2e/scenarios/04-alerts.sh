# Alerts inbox on context lab (read from its Alertmanager): the firing count
# matches Alertmanager's own active, unmuted alerts, the always-firing fixture
# alerts are listed, and `v` switches to the rules view with the failing rule
# counted as unhealthy.
A=$(surface alerts)

open_block alerts alerts || return
bwait alerts "firing" '.sf-badge' || return
want=$(curl -fsS --max-time 5 "$AM/api/v2/alerts?active=true&silenced=false&inhibited=false" | jq length)
firing() { texts "$A .sf-badge" | jq -r '.[] | select(endswith(" firing"))' | head -1; }
eq "firing count matches Alertmanager" "$(firing)" "$want firing"
contains "always-firing alert listed" "$(btext alerts '.sf-card-head')" "alertname=TernAlwaysFiring 1 firing"
contains "target-down alert listed" "$(btext alerts '.sf-card-head')" "alertname=TernTargetDown 1 firing"
shot inbox

# The status segment counts the same firing alerts (bar on for this check only).
ctl status-bar on >/dev/null
seg() { texts '#statusline .sl-plugin' | jq -r '.[] | select(endswith(" firing"))' | head -1; }
seg_is() { [ "$(seg)" = "$1" ]; }
E2E_WAIT=40 wait_for "the alerts status segment" seg_is "$want firing"
ctl status-bar off >/dev/null

keys v
bwait alerts "recording" '.sf-badge' || return
contains "failing rule counted" "$(texts "$A .sf-badge")" '"1 unhealthy (p shows only these)"'
contains "Grafana rules listed" "$(btext alerts '.tg-al-row')" "firing ok TernGrafanaAlwaysFiring"
contains "Prometheus rules listed" "$(btext alerts '.tg-al-row')" "TernAlwaysFiring"
shot rules
