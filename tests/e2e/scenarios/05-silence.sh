# Silence from an alert, previewed and cancelled: `s` on the first alert opens
# the silence form prefilled with its labels, `S` shows the confirmation panel,
# `n` cancels. Alertmanager must hold exactly the silences it held before (the
# e2e suite never creates a silence).
S=$(surface silence)
before=$(am_silences | jq -c '[.[].id] | sort') || {
	fail "cannot list Alertmanager silences"
	return
}

open_block alerts alerts || return
bwait alerts "firing" '.sf-badge' || return
keys j s
E2E_WAIT=20 wait_for "the silence block" has "$S" || return
bwait silence "add matcher" || return
contains "matchers prefilled from the alert" "$(btext silence '.tg-sil-field')" 'matcher alertname="'
contains "server named" "$(btext silence)" "Alertmanager $AM"

# The comment is required; it is the selected field.
contains "comment selected" "$(btext silence '.is-sel')" "comment required"
keys enter
type_text "e2e preview only"
keys enter S
bwait silence "Create this silence?" || return
contains "confirmation lists matchers" "$(btext silence '.sf-kv-item')" 'alertname="'
contains "confirmation shows the comment" "$(btext silence '.sf-kv-item')" "e2e preview only"
shot confirm

keys n
bwait silence "Cancelled: nothing was sent." || return
eq "Alertmanager silences unchanged" "$(am_silences | jq -c '[.[].id] | sort')" "$before"
lacks "$S .sf-card-head" || fail "the confirmation panel is still shown"
eq "no e2e silence on Alertmanager" "$(am_silences | jq '[.[] | select(.comment == "e2e preview only")] | length')" 0
shot cancelled
keys escape
