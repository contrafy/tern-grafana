# Ops block, Targets tab on Prometheus 3 (direct): the counts show the one
# down target, and the down pool (job `down`, node-exporter:9999, a closed
# port) comes first with its scrape error.
O=$(surface ops)

open_block ops ops || return
bwait ops "1 down" '.sf-badge' || return
contains "server named from build info" "$(btext ops '.sf-text')" "Prometheus API 3"
contains "direct route" "$(btext ops '.sf-text')" "direct"
contains "down target counted" "$(texts "$O .sf-badge")" '"1 down"'
eq "down pool first" "$(alltext "$O .sf-card-head" | head -1)" "down 0/1 up 1 down"
contains "down target row" "$(btext ops '.tg-op-down')" "down node-exporter:9999"
contains "scrape error shown" "$(btext ops '.tg-op-down')" "connection refused"
shot targets

keys u
sleep 0.5
eq "unhealthy only keeps the down pool" "$(alltext "$O .sf-card-head")" "down 0/1 up 1 down"
keys u
