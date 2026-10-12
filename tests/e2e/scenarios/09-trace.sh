# Trace block on Tempo (direct, context lab): the default search `{}` lists the
# generated traces, and `enter` on the selected hit opens its waterfall with
# the summary's span count matching the rows drawn.
T=$(surface trace)

open_block traces trace || return
bwait trace "traces, searched" || return
contains "Tempo routed directly" "$(btext trace '.sf-text')" "Tempo direct"
contains "default TraceQL" "$(btext trace '.sf-text')" "TraceQL {} / edit"
has "$T .tg-tr-hit" || fail "no search hits"
hits=$(texts "$T .tg-tr-hit" | jq -r '.[]')
[ "$(printf '%s\n' "$hits" | grep -c -E ' (frontend|payments) ')" -ge 1 ] || fail "no frontend or payments hit: $hits"
shot search

keys enter
bwait trace "spans" || return
spans=$(alltext "$T .sf-text" | sed -n 's/.* \([0-9][0-9]*\) spans .*/\1/p' | head -1)
[ -n "$spans" ] || fail "summary without a span count"
eq "one waterfall row per span" "$(count "$T .tg-tr-row.sf-act")" "$spans"
contains "trace id shown" "$(btext trace '.sf-text')" "trace "
shot waterfall
