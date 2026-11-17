#!/bin/bash
# S6-T5 verifier: Debug zig build test in one plant copy with its own empty caches.
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
P=<vscratch>/plants2.noindex
n=$1; mkdir -p $P/$n-cache/g $P/$n-cache/l $P/$n-tmp
export TMPDIR=$P/$n-tmp
cd $P/$n/zig
start=$(date +%T)
zig build test --summary all --global-cache-dir $P/$n-cache/g --cache-dir $P/$n-cache/l > $P/$n.log 2>&1
echo "$n exit $? $start-$(date +%T)" >> $P/$n.log
