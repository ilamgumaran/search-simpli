#!/bin/sh
# S6-T4 ruling 4: regenerate tests/fixtures/index-v3-s6t4/, the lexical v3
# reference index: fixtures/family-folder/home indexed with
# `searchd index --filename-index` by this checkout's engine (manifest v2.3,
# both lexical sections `HYBLEX03`). `zig/src/compat_98c4a2b_test.zig` checks
# that the writer still gives these bytes and that a library before v3
# refuses them at the manifest's flags.
#
# Usage, from anywhere inside the repository, with zig 0.16.0 on PATH:
#   sh tests/fixtures/gen_index_v3_s6t4.sh
set -eu
repo=$(git rev-parse --show-toplevel)
(cd "$repo/zig" && zig build >/dev/null)
out="$repo/tests/fixtures/index-v3-s6t4"
mkdir -p "$out"
for name in MANIFEST INDEX-STATE.json documents-1.hybseg lexical-1.hyblex source-1.hybsrc \
    state-1.hybstate filenames-1.hybseg filename-lexical-1.hyblex WRITER.LOCK; do
    rm -f "$out/$name"
done
# A relative folder, so nothing of this machine's paths lands in the index.
(cd "$repo" && ./zig/zig-out/bin/searchd index fixtures/family-folder/home --out "$out" --filename-index >/dev/null)
rm -f "$out/WRITER.LOCK"
ls -l "$out"
