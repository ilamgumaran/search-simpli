#!/bin/sh
# S6-T9: regenerate tests/fixtures/index-refs-s6t9/, the v2.6 reference
# index: fixtures/family-folder/home indexed with `searchd index
# --filename-index` by this checkout's engine (manifest v2.6: the state
# section `HYBSTA03`, each retained file's record referring to its source
# record; the file-name catalog record v6, ids and stems derived; as v2.5,
# the content lexical section `HYBLEX04`, the file-name lexical section
# `HYBLEX03`, documents record v5, source `HYBSRC02`).
# `zig/src/compat_s6t9_test.zig` checks that the writer still gives these
# bytes and that a library before v2.6 refuses them at the manifest's flags.
#
# Usage, from anywhere inside the repository, with zig 0.16.0 on PATH:
#   sh tests/fixtures/gen_index_refs_s6t9.sh
set -eu
repo=$(git rev-parse --show-toplevel)
(cd "$repo/zig" && zig build >/dev/null)
out="$repo/tests/fixtures/index-refs-s6t9"
mkdir -p "$out"
for name in MANIFEST INDEX-STATE.json documents-1.hybseg lexical-1.hyblex source-1.hybsrc \
    state-1.hybstate filenames-1.hybseg filename-lexical-1.hyblex WRITER.LOCK; do
    rm -f "$out/$name"
done
# A relative folder, so nothing of this machine's paths lands in the index.
(cd "$repo" && ./zig/zig-out/bin/searchd index fixtures/family-folder/home --out "$out" --filename-index >/dev/null)
rm -f "$out/WRITER.LOCK"
ls -l "$out"
