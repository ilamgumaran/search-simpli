#!/bin/bash
# S6-T13 verifier load gate: the app check lock absent and the 5-minute load average below 4.0. One line to $GATES.
# Exit 1 = refused (the caller stops; nothing waits or retries).
LOCK="$HOME/workspace/repos/simpli-helper-wt/.check.lock"
[ -e "$LOCK" ] && lock=present || lock=absent
load="$(sysctl -n vm.loadavg | tr -d '{}' | xargs)"
l5="$(echo "$load" | awk '{print $2}')"
ok=1
[ "$lock" = present ] && ok=0
awk -v l="$l5" 'BEGIN{exit !(l >= 4.0)}' && ok=0
v=PASS; [ $ok = 1 ] || v=REFUSED
echo "$(date '+%F %T') $1 $v lock=$lock load=[$load]" >> "$GATES"
[ $ok = 1 ]
