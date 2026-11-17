#!/bin/bash
# S6-T5 second verification: a ReleaseSmall library of one plant copy (its own caches), then the Dart
# query_report test against it with SEARCH_SIMPLI_LIBRARY_PATH set for that one command only.
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$HOME/development/flutter/bin:$PATH
P=$HOME/workspace/repos/search-simpli-wt/S6-T5-vscratch/plants2.noindex
n=$1
export TMPDIR=$P/$n-tmp
cd $P/$n/zig
zig build lib -Doptimize=ReleaseSmall --global-cache-dir $P/$n-cache/g --cache-dir $P/$n-cache/lrs > $P/$n-lib.log 2>&1 || { echo "$n lib build failed"; exit 1; }
lib=$P/$n/zig/zig-out/lib/aarch64-macos/libsearch_simpli.dylib
cd $P/$n/bindings/dart/search_simpli
dart pub get --offline > $P/$n-pub.log 2>&1 || { echo "$n pub get failed"; exit 1; }
env SEARCH_SIMPLI_LIBRARY_PATH=$lib dart test test/query_report_test.dart > $P/$n-dart.log 2>&1
echo "$n dart exit $? $(tr '\r' '\n' < $P/$n-dart.log | grep -v '^$' | tail -1)"
