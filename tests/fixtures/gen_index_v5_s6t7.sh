#!/bin/sh
# S6-T7: regenerate tests/fixtures/index-v5-s6t7/, the text-once reference
# index: fixtures/family-folder/home indexed with `searchd index
# --filename-index` by this checkout's engine (manifest v2.4: the documents
# section record v5 with its file table, the source section `HYBSRC02`;
# both lexical sections `HYBLEX03`). `zig/src/compat_s6t7_test.zig` checks
# that the writer still gives these bytes and that a library before v2.4
# refuses them at the manifest's flags.
#
# Usage, from anywhere inside the repository, with zig 0.16.0 on PATH:
#   sh tests/fixtures/gen_index_v5_s6t7.sh
set -eu
repo=$(git rev-parse --show-toplevel)
(cd "$repo/zig" && zig build >/dev/null)
out="$repo/tests/fixtures/index-v5-s6t7"
mkdir -p "$out"
for name in MANIFEST INDEX-STATE.json documents-1.hybseg lexical-1.hyblex source-1.hybsrc \
    state-1.hybstate filenames-1.hybseg filename-lexical-1.hyblex WRITER.LOCK; do
    rm -f "$out/$name"
done
# A relative folder, so nothing of this machine's paths lands in the index.
(cd "$repo" && ./zig/zig-out/bin/searchd index fixtures/family-folder/home --out "$out" --filename-index >/dev/null)
rm -f "$out/WRITER.LOCK"
ls -l "$out"
