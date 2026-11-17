#!/bin/sh
# S6-T4 ruling 4: regenerate tests/fixtures/index-v3-s6t4/, the lexical v3
# reference index: fixtures/family-folder/home indexed with
# `searchd index --filename-index` (manifest v2.3, both lexical sections
# `HYBLEX03`). `zig/src/compat_98c4a2b_test.zig` checks that the writer
# still gives its lexical, file-name and state sections and that a library
# before v3 refuses it at the manifest's flags. S6-T7: since manifest v2.4
# the writer's documents and source sections are record v5 and `HYBSRC02`,
# so the fixture is written by the engine at a534678 (`main` before S6-T7),
# and `zig/src/compat_s6t7_test.zig` checks that it opens, answers and
# updates under this library.
#
# Usage, from anywhere inside the repository, with zig 0.16.0 on PATH:
#   sh tests/fixtures/gen_index_v3_s6t4.sh
# The output is deterministic: a second run leaves `git status` clean. The
# build's scratch directory is left in place and printed (delete it by hand).
set -eu
pin=a534678
repo=$(git rev-parse --show-toplevel)
work=$(mktemp -d)
git -C "$repo" archive "$pin" zig contracts fixtures/family-folder/home | tar -x -C "$work"
(cd "$work/zig" && zig build -Doptimize=ReleaseSafe --cache-dir "$work/.zig-cache" >/dev/null)
out="$repo/tests/fixtures/index-v3-s6t4"
mkdir -p "$out"
for name in MANIFEST INDEX-STATE.json documents-1.hybseg lexical-1.hyblex source-1.hybsrc \
    state-1.hybstate filenames-1.hybseg filename-lexical-1.hyblex WRITER.LOCK; do
    rm -f "$out/$name"
done
# A relative folder, so nothing of this machine's paths lands in the index.
(cd "$work" && ./zig/zig-out/bin/searchd index fixtures/family-folder/home --out "$out" --filename-index >/dev/null)
rm -f "$out/WRITER.LOCK"
ls -l "$out"
echo "scratch: $work"
