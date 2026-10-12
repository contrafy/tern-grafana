# Logs block on Loki (direct, context lab): the generator's lines arrive with
# one chip per level; clicking the error chip filters the stream selector to
# level="error" and only error lines remain.
G=$(surface logs)

open_block logs logs || return
type_text '{job="loggen"}'
ctl key enter >/dev/null
bwait logs "debug " '.sf-badge' || return
chips=$(texts "$G .sf-badge.sf-act" | jq -c '[.[] | select(test("^(error|warn|info|debug) [0-9]+$")) | sub(" [0-9]+$"; "")]')
eq "one chip per generated level" "$chips" '["error","warn","info","debug"]'
has "$G .tg-lg-row" 10 || fail "fewer than 10 log lines"
levels() { ctl tree "$G .tg-lg-row" | jq -c '[.nodes[].class | capture("tg-lg-(?<l>[a-z]+)$").l] | unique'; }
[ "$(levels | jq length)" -ge 3 ] || fail "lines colored by level: only $(levels)"
contains "header counts the lines" "$(btext logs '.sf-row')" "lines"
shot lines

click_text "error *" "$G .sf-badge.sf-act" || return
bwait logs 'level="error"' '.sf-input' || return
only_errors() { [ "$(levels)" = '["error"]' ]; }
E2E_WAIT=15 wait_for "only error lines" only_errors
eq "query filtered to the level" "$(alltext "$G .sf-input" | head -1)" '> {job="loggen", level="error"}'
shot error-chip
