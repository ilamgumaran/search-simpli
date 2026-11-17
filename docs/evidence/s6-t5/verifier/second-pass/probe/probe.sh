#!/bin/bash
# S6-T5 second verification, a probe beside the rule's runs (not one of them): prose-10k only,
# nmain / nhead / ntroff (the head with abi.zig passing a null trace), five rounds in rotating
# orders fixed here, gate.sh before every library, bench.py per library.  probe.sh INDEXDIR TAG
set -u
V=$HOME/workspace/repos/search-simpli-wt/S6-T5-vscratch
S=$V/s6t4h
index="$1"; tag="$2"
export GATES=$V/probe/gates.txt
orders=("nmain nhead ntroff" "nhead ntroff nmain" "ntroff nmain nhead" "nmain ntroff nhead" "nhead nmain ntroff")
for r in 1 2 3 4 5; do
  for name in ${orders[$((r-1))]}; do
    bash "$S/gate.sh" "probe $tag r$r $name" > /dev/null || { echo "gate refused $tag r$r $name"; exit 1; }
    python3 -I "$S/bench.py" bench "$V/libs/$name/libsearch_simpli.dylib" "$index" "$V/q/prose-10k.json" "$name" "$r" "$V/probe/$tag.jsonl" > /dev/null || exit 2
  done
done
echo "done $tag $(date +%T)"
