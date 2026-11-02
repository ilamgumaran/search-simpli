#!/bin/sh
# S4-T1 ruling 2: regenerate tests/fixtures/index-292cb568/, an index written
# by the engine at commit 292cb568 (the commit the consumer app pins; its
# phones hold indexes in this format: manifest v2 without flag 4, sections
# with FNV-1a 64 checksums). The input is fixtures/family-folder/home at that
# commit, indexed with `searchd index` (one root, source retained).
#
# Usage, from anywhere inside the repository, with zig 0.16.0 on PATH:
#   sh tests/fixtures/gen_index_292cb568.sh
# The output is deterministic: a second run leaves `git status` clean.
set -eu
pin=292cb568
repo=$(git rev-parse --show-toplevel)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git -C "$repo" archive "$pin" zig contracts fixtures/family-folder/home | tar -x -C "$work"
(cd "$work/zig" && zig build -Doptimize=ReleaseSafe --cache-dir "$work/.zig-cache" >/dev/null)
out="$repo/tests/fixtures/index-292cb568"
rm -rf "$out"
# A relative folder, so nothing of this machine's paths lands in the index.
(cd "$work" && ./zig/zig-out/bin/searchd index fixtures/family-folder/home --out "$out" >/dev/null)
rm -f "$out/WRITER.LOCK"
ls -l "$out"
