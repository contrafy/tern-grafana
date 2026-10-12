# Threshold watch from the sandbox config (`e2e target down`: up{job="down"}
# == 0, always true on the stack) fires and shows in the status line; clicking
# the segment opens its query in a Query block. The status bar is turned on
# for the scenario and off again.
Q=$(surface query)
SEG='#statusline .sl-plugin'

ctl status-bar on >/dev/null
seg_has() { case $(alltext "$SEG") in *"$1"*) true ;; *) false ;; esac; }
E2E_WAIT=40 wait_for "the watch segment" seg_has "watch e2e target down" || {
	ctl status-bar off >/dev/null
	return
}
eq "watch segment text" "$(texts "$SEG" | jq -r '.[] | select(startswith("watch "))')" "watch e2e target down"
shot status

click_text "watch e2e target down" "$SEG" || {
	ctl status-bar off >/dev/null
	return
}
E2E_WAIT=20 wait_for "the watch's query block" has "$Q"
bwait query 'up{instance="node-exporter:9999", job="down"} 0' || return
eq "watch query opened" "$(alltext "$Q .sf-input" | head -1)" '> up{job="down"}'
eq "on the watch's context" "$(texts "$Q .sf-badge" | jq -r '.[0]')" lab
shot query
ctl status-bar off >/dev/null
