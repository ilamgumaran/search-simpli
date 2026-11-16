#!/bin/sh
# S6-T4 ruling 4: regenerate tests/fixtures/index-98c4a2b/, an index written
# by the engine at commit 98c4a2b (`main` before lexical format v3: manifest
# v2.2, the content lexical section `HYBLEX02`, the file-name lexical section
# `HYBLEX01`, every section XXH3-64). The input is fixtures/family-folder/home
# at that commit, indexed with `searchd index --filename-index` (one root,
# source retained, the file-name channel on).
#
# Usage, from anywhere inside the repository, with zig 0.16.0 on PATH:
#   sh tests/fixtures/gen_index_98c4a2b.sh
# The output is deterministic: a second run leaves `git status` clean. The
# build's scratch directory is left in place and printed (delete it by hand).
set -eu
pin=98c4a2b
repo=$(git rev-parse --show-toplevel)
work=$(mktemp -d)
git -C "$repo" archive "$pin" zig contracts fixtures/family-folder/home | tar -x -C "$work"
(cd "$work/zig" && zig build -Doptimize=ReleaseSafe --cache-dir "$work/.zig-cache" >/dev/null)
out="$repo/tests/fixtures/index-98c4a2b"
mkdir -p "$out"
for name in MANIFEST INDEX-STATE.json documents-1.hybseg lexical-1.hyblex source-1.hybsrc \
    state-1.hybstate filenames-1.hybseg filename-lexical-1.hyblex WRITER.LOCK; do
    rm -f "$out/$name"
done
# A relative folder, so nothing of this machine's paths lands in the index.
(cd "$work" && ./zig/zig-out/bin/searchd index fixtures/family-folder/home --out "$out" --filename-index >/dev/null)
rm -f "$out/WRITER.LOCK"
ls -l "$out"
echo "build scratch left at $work"
