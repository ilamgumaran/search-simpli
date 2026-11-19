#!/bin/sh
# S6-T8: regenerate tests/fixtures/index-lex4-s6t8/, the v2.5 reference
# index: fixtures/family-folder/home indexed with `searchd index
# --filename-index` by this checkout's engine (manifest v2.5: the content
# lexical section `HYBLEX04`, section 5 at one byte per token; the file-name
# lexical section `HYBLEX03`; documents record v5, source `HYBSRC02`).
# `zig/src/compat_s6t8_test.zig` checks that the writer still gives these
# bytes and that a library before v2.5 refuses them at the manifest's flags.
#
# Usage, from anywhere inside the repository, with zig 0.16.0 on PATH:
#   sh tests/fixtures/gen_index_lex4_s6t8.sh
set -eu
repo=$(git rev-parse --show-toplevel)
(cd "$repo/zig" && zig build >/dev/null)
out="$repo/tests/fixtures/index-lex4-s6t8"
mkdir -p "$out"
for name in MANIFEST INDEX-STATE.json documents-1.hybseg lexical-1.hyblex source-1.hybsrc \
    state-1.hybstate filenames-1.hybseg filename-lexical-1.hyblex WRITER.LOCK; do
    rm -f "$out/$name"
done
# A relative folder, so nothing of this machine's paths lands in the index.
(cd "$repo" && ./zig/zig-out/bin/searchd index fixtures/family-folder/home --out "$out" --filename-index >/dev/null)
rm -f "$out/WRITER.LOCK"
ls -l "$out"
