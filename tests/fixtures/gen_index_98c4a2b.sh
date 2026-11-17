#!/bin/sh
# S6-T4 ruling 4: regenerate tests/fixtures/index-98c4a2b/, an index written
# by the engine at commit 98c4a2b (`main` before lexical format v3: manifest
# v2.2, the content lexical section `HYBLEX02`, the file-name lexical section
# `HYBLEX01`, every section XXH3-64). The input is fixtures/family-folder/home
# at that commit, indexed with `searchd index --filename-index` (one root,
# source retained, the file-name channel on). Also tests/fixtures/
# import-filename-98c4a2b/: what that commit's `import-json` writes for an
# interchange file with the file-name channel (manifest without bit 5, both
# lexical sections `HYBLEX01`).
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
# import-json with the file-name channel (an interchange v2 export of
# fixtures/filename-search/corpus by this checkout's Python reference, whose
# exporter 98c4a2b shares): what 98c4a2b writes for it.
imp="$repo/tests/fixtures/import-filename-98c4a2b"
mkdir -p "$imp"
for name in MANIFEST documents-1.hybseg lexical-1.hyblex filenames-1.hybseg filename-lexical-1.hyblex \
    interchange.json WRITER.LOCK; do
    rm -f "$imp/$name"
done
(cd "$repo" && python3 search.py index fixtures/filename-search/corpus --filename-index --out "$work/py-index.json" >/dev/null)
(cd "$repo" && python3 export_zig.py "$work/py-index.json" --out "$imp/interchange.json" --analyzer analyzer-v2 >/dev/null)
"$work/zig/zig-out/bin/searchd" import-json "$work/imported" "$imp/interchange.json" >/dev/null
for name in MANIFEST documents-1.hybseg lexical-1.hyblex filenames-1.hybseg filename-lexical-1.hyblex; do
    cp "$work/imported/$name" "$imp/$name"
done
ls -l "$imp"
echo "build scratch left at $work"
