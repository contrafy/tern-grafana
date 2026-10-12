# Settings block on the sandbox's generated config: the file validates, both
# contexts are listed with lab as the default, and `t` on lab's prometheus
# endpoint reaches the server and reports its version. Nothing is edited.
ST=$(surface settings)

open_block settings settings || return
bwait settings "valid" || return
contains "config path" "$(btext settings)" "$E2E_CFG"
contains "valid badge" "$(texts "$ST .sf-badge")" '"valid"'
contains "default context badge" "$(texts "$ST .sf-badge")" '"default lab"'
contains "both contexts listed" "$(texts "$ST .tg-set-ctx .tg-set-name")" '["g11 1 endpoint","lab 5 endpointsdefault"]'

# Select lab's prometheus endpoint with j, then test it.
sel() { alltext "$ST .tg-set-sel .tg-set-name" | head -1; }
i=0
until [ "$(sel)" = prometheus ] || [ $i -ge 12 ]; do
	ctl key j >/dev/null
	sleep 0.2
	i=$((i + 1))
done
eq "prometheus endpoint selected" "$(sel)" prometheus
ctl key t >/dev/null
bwait settings "health: Prometheus 3." ".tg-set-sel *" || return
contains "version reported on the endpoint" "$(btext settings '.tg-set-sel *')" "http://localhost:9090"
shot tested
