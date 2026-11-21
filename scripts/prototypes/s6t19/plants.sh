#!/usr/bin/env bash
# S6-T19 ruling 3: planted uses of the two names that left core.api, in a fresh `git archive COMMIT` (its own copy
# SCRATCH/plants-COMMIT, refused if it exists), then the copy's own scripts/check_layers.py; and, with ZIG=1, one
# `zig build test --summary all` of the copy (its own local and global caches) to show Zig refuses the first plant too.
#   [ZIG=1] scripts/prototypes/s6t19/plants.sh COMMIT SCRATCH
# Never removes anything.
set -uo pipefail
commit="$1"; scratch="$2"
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -P "$here/../../.." && pwd)"
dir="$scratch/plants-$commit"
if [ -e "$dir" ]; then echo "plants.sh: $dir exists" >&2; exit 2; fi
mkdir -p "$dir" && git -C "$repo" archive "$commit" | tar -x -C "$dir"
src="$dir/zig/src"
printf 'test "planted" {\n    _ = @import("core").api.analyzer_v2.analyzer_id;\n}\n' >> "$src/ops/filename_response.zig"
printf 'const analyzer_v2 = @import("core").api.analyzer_v2;\ntest "planted" {\n    _ = analyzer_v2.analyzer_id;\n}\n' >> "$src/interfaces/rpc.zig"
printf 'test "planted" {\n    _ = manifest.decode;\n}\n' >> "$src/interfaces/abi.zig"
printf 'const planted = @import("core").api.manifest.decode;\n' >> "$src/ops/service.zig"
echo "## the plants (git diff --no-index of each planted file against $commit's)"
for rel in ops/filename_response.zig interfaces/rpc.zig interfaces/abi.zig ops/service.zig; do
  git -C "$repo" show "$commit:zig/src/$rel" > "$dir/orig.zig"
  git diff --no-index -U0 "$dir/orig.zig" "$src/$rel" | grep -E '^[+@]' | grep -v '^+++' | sed "s#^@@#$rel @@#"
done
echo "## check_layers.py"
(cd "$dir" && python3 -I scripts/check_layers.py --root "$dir" 2>&1 | sed "s#$dir#<copy>#g")
echo "check_layers.py exit ${PIPESTATUS[0]}"
if [ "${ZIG:-0}" = 1 ]; then
  # Only the first plant stays for the build, so the error names it.
  for rel in interfaces/rpc.zig interfaces/abi.zig ops/service.zig; do git -C "$repo" show "$commit:zig/src/$rel" > "$src/$rel"; done
  echo "## zig build test --summary all, with only the plant in ops/filename_response.zig"
  (cd "$dir/zig" && zig build test --summary all --cache-dir "$dir/.zig-local-cache" --global-cache-dir "$dir/.zig-global-cache") \
    > "$dir/zig.txt" 2>&1
  code=$?
  grep -E "error:|Build Summary" "$dir/zig.txt" | sed "s#$dir#<copy>#g" | awk '!seen[$0]++'
  echo "zig build test exit $code"
fi
