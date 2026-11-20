#!/bin/zsh
# usage: run_filtered.sh <zig dir of a tree> <cache root (fresh per tree)> <test filter>
# Runs the engine test binary (root.zig, Debug) with --test-filter, using
# literal copies of the build's option files and fastmem object.
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
OPTS=$HOME/workspace/repos/search-simpli-wt/S6-T13-scratch/opts
cd "$1" || exit 2
mkdir -p "$2/local" "$2/global"
zig test $OPTS/fastmem.o -ODebug --dep build_options --dep tool_schemas -Mroot=src/root.zig -Mbuild_options=$OPTS/build_options.zig -Mtool_schemas=$OPTS/tool_schemas.zig -lc --cache-dir "$2/local" --global-cache-dir "$2/global" --test-filter "load every engine module" --test-filter "test_" --test-filter "$3" 2>&1
