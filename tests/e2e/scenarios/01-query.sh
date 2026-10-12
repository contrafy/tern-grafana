# Query block from the palette: a range query draws the native SVG chart with
# one legend row per series; `t` switches to the instant table, one row per
# series. Reads Prometheus 3 directly (context lab).
Q=$(surface query)

ctl palette '"Grafana: Query"' >/dev/null
sleep 0.6
ctl key enter >/dev/null
E2E_WAIT=20 wait_for "the query block" has "$Q" || return
bwait query "Write a query and press Enter." || return

type_text 'sum by (job) (up)'
ctl key enter >/dev/null
bwait query '{job="down"} 0' || return
eq "chart drawn as an image" "$(count "$Q .sf-image svg.tg-chart")" 1
eq "header badges: context and mode" "$(texts "$Q .sf-badge")" '["lab","graph"]'
contains "header names range and step" "$(alltext "$Q .sf-row" | head -1)" "Last 1 hourstep 15s"
contains "legend lists the up series" "$(btext query)" '{job="prometheus"} 1'
shot graph

keys escape t
bwait query "instant" || return
contains "table header" "$(texts "$Q .tg-table .tg-h")" '["Time","job","Value"]'
eq "one value cell per job" "$(count "$Q .tg-table .tg-c.tg-num")" 6
contains "down target in the table" "$(texts "$Q .tg-table .tg-c")" '"down"'
shot table
