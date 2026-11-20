#!/bin/bash
# S6-T13 load gate (the S6-T9 verifier's): the app check lock absent, the 5-minute load BELOW 4.0, and no toolchain
# at 20 % CPU or more in the second sample of top's top eight. One line to $GATES; exit 1 = refused.
GATES="${GATES:-$(dirname "$0")/gates.txt}"
LOCK="$HOME/workspace/repos/simpli-helper-wt/.check.lock"
now="$(date '+%Y-%m-%d %H:%M:%S')"
label="${1:-check}"
if [ -e "$LOCK" ]; then lock=present; else lock=absent; fi
load="$(sysctl -n vm.loadavg | tr -d '{}' | xargs)"
load5="$(echo "$load" | awk '{print $2}')"
top8="$(top -l 2 -o cpu -n 8 -stats command,cpu 2>/dev/null | awk '/^COMMAND/{n++; next} n==2 && NF>=2 {printf "%s %s;", $1, $NF}')"
bad="$(echo "$top8" | tr ';' '\n' | awk '$NF + 0 >= 20 {print $1}' | grep -E '^(dart|dartvm|dartaotruntime|flutter|flutter_tester|zig|xcodebuild|python3|Python|swift|swift-frontend|clang|ld)$' | sort -u | xargs)"
ok=1; reason=""
[ "$lock" = present ] && { ok=0; reason="$reason lock;"; }
awk -v l="$load5" 'BEGIN{exit !(l >= 4.0)}' && { ok=0; reason="$reason load5>=4.0;"; }
[ -n "$bad" ] && { ok=0; reason="$reason toolchain:$bad;"; }
if [ $ok = 1 ]; then verdict=PASS; else verdict="REFUSED($reason )"; fi
echo "$now $label gate $verdict lock=$lock load=[$load] top8: $top8" >> "$GATES"
echo "$now $label gate $verdict lock=$lock load=[$load]"
[ $ok = 1 ]
