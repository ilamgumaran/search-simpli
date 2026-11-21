#!/usr/bin/env bash
# S6-T16: the Zig proofs, each in a fresh `git archive` copy with its own local and global caches.
#
#   scripts/prototypes/s6t16/proofs.sh names COMMIT MAIN SCRATCH   # zig build test of both, Debug and ReleaseSmall,
#                                                                  # through check_test_counts.py --run; every test
#                                                                  # binary run directly; names and outcomes compared
#   scripts/prototypes/s6t16/proofs.sh searchd COMMIT MAIN SCRATCH # ReleaseSmall searchd of both, cmp
#   scripts/prototypes/s6t16/proofs.sh abi COMMIT MAIN SCRATCH     # zig build test-abi of both, Debug and ReleaseSmall
#   scripts/prototypes/s6t16/proofs.sh plants COMMIT SCRATCH       # the guard's plants (below)
#
# Zig on PATH. Builds run one after another, never two at once. Never removes anything.
set -uo pipefail
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -P "$here/../../.." && pwd)"

fresh() {  # fresh COMMIT DIR: a git archive of COMMIT in DIR (made once)
  if [ ! -d "$2" ]; then mkdir -p "$2" && git -C "$repo" archive "$1" | tar -x -C "$2"; fi
}

caches() {  # caches DIR: zig build's cache arguments for DIR
  echo "--cache-dir $1/.zig-local-cache --global-cache-dir $1/.zig-global-cache"
}

zigb() {  # zigb DIR ARGS...: zig build in DIR/zig with DIR's own caches
  local dir="$1"; shift
  # shellcheck disable=SC2046
  (cd "$dir/zig" && zig build "$@" $(caches "$dir"))
}

summary() {  # summary FILE: the Build Summary and the step lines
  grep -E "Build Summary|run test|abi_test" "$1" | grep -v " w$" | sed -E 's/ [0-9.]+(ms|s|m|us) MaxRSS:[0-9]+[KMG]//'
}

names() {  # names DIR: every test binary of DIR's zig build test, run from DIR/zig; one sorted line per test
  local bin
  for step in core operations interfaces tests test; do
    bin=$(find "$1/.zig-local-cache/o" -type f -name "$step" -perm -u+x | head -1)
    [ -n "$bin" ] || { echo "MISSING binary $step"; continue; }
    (cd "$1/zig" && "$bin" 2>&1) | sed -E -e 's/^[0-9]+\/[0-9]+ //' -e 's/[0-9]+(\.[0-9]+)? ?ms/N ms/g' -e 's/growth [0-9.]+x/growth Nx/g' \
      | sed "s/^/$step: /"
  done | LC_ALL=C sort
}

case "$1" in
  names)
    commit="$2"; main="$3"; scratch="$4"
    for mode in Debug ReleaseSmall; do
      for c in "$main" "$commit"; do
        dir="$scratch/names-$c-$mode"; fresh "$c" "$dir"
        # shellcheck disable=SC2046
        (cd "$dir" && python3 -I scripts/check_test_counts.py --root "$dir" --run -- -Doptimize="$mode" $(caches "$dir")) \
          > "$dir/counts.txt" 2>&1
        echo "$c $mode: check_test_counts.py --run -- -Doptimize=$mode: exit $?"
        summary "$dir/counts.txt"
        grep -E "^check_(test_counts|layers):" "$dir/counts.txt"
        (cd "$dir" && python3 -I scripts/check_layers.py) | sed "s/^/  $c: /"
        names "$dir" > "$dir/names.txt"
        echo "  $c $mode: $(wc -l < "$dir/names.txt" | tr -d ' ') lines; $(grep -c 'OK$' "$dir/names.txt") OK," \
             "$(grep -c 'SKIP$' "$dir/names.txt") SKIP, $(grep -cE 'FAIL|error' "$dir/names.txt") FAIL or error"
      done
      if diff "$scratch/names-$main-$mode/names.txt" "$scratch/names-$commit-$mode/names.txt" > "$scratch/names-$mode.diff"; then
        echo "$mode: names and outcomes of $main and $commit: the same $(wc -l < "$scratch/names-$commit-$mode/names.txt" | tr -d ' ') lines"
      else
        echo "$mode: names and outcomes DIFFER:"; head -40 "$scratch/names-$mode.diff"
      fi
    done
    ;;
  searchd)
    commit="$2"; main="$3"; scratch="$4"
    for c in "$commit" "$main"; do
      dir="$scratch/searchd-$c"; fresh "$c" "$dir"
      zigb "$dir" -Doptimize=ReleaseSmall --prefix "$dir/out" > "$dir/build.txt" 2>&1
      echo "$c: zig build -Doptimize=ReleaseSmall exit $?; searchd $(wc -c < "$dir/out/bin/searchd" | tr -d ' ') B, sha256 $(shasum -a 256 "$dir/out/bin/searchd" | cut -c1-16)..."
    done
    if cmp "$scratch/searchd-$commit/out/bin/searchd" "$scratch/searchd-$main/out/bin/searchd"; then
      echo "searchd ReleaseSmall: $commit and $main cmp-identical"
    else
      echo "searchd ReleaseSmall: $commit and $main DIFFER"
    fi
    ;;
  abi)
    commit="$2"; main="$3"; scratch="$4"
    for c in "$main" "$commit"; do
      dir="$scratch/abi-$c"; fresh "$c" "$dir"
      for mode in Debug ReleaseSmall; do
        zigb "$dir" test-abi -Doptimize="$mode" --summary all > "$dir/test-abi-$mode.txt" 2>&1
        echo "$c: zig build test-abi -Doptimize=$mode --summary all: exit $?"
        summary "$dir/test-abi-$mode.txt"
      done
    done
    ;;
  plants)
    # Each plant: a fresh copy of COMMIT with one file changed, its own caches. The checker is
    # run on it, and `zig build test` for the plants whose point is what Zig does with them.
    commit="$2"; scratch="$3"
    plant() {  # plant NAME REL BUILD(yes|no) PYTHON-EDIT: edit REL in a fresh copy with the python snippet
      local name="$1" rel="$2" build="$3" edit="$4" dir="$scratch/plant-$1"
      fresh "$commit" "$dir"
      python3 -I -c "$edit" "$dir/$rel" "$dir"
      echo "## plant $name ($rel)"
      git -C "$repo" show "$commit:$rel" > "$dir/before.zig" 2>/dev/null || : > "$dir/before.zig"
      diff -u "$dir/before.zig" "$dir/$rel" | sed -e "s#$dir/##" -e "s#$dir#<copy>#" | tail -n +3
      (cd "$dir" && python3 -I scripts/check_layers.py 2>&1) | sed -e "s#$dir#<copy>#g"
      echo "check_layers.py exit ${PIPESTATUS[0]}"
      if [ "$build" = yes ]; then
        zigb "$dir" test --summary all > "$dir/test.txt" 2>&1
        echo "zig build test --summary all: exit $?"
        summary "$dir/test.txt"
        grep -E "error:" "$dir/test.txt" | sed -e "s#$dir#<copy>#g" | head -3
      fi
      echo
    }
    # 1. ops/: an internal core name, inline, in a test block (compiled by the operations step).
    plant ops-internal zig/src/ops/report.zig yes '
import sys
p = sys.argv[1]
open(p, "a").write("\ntest \"S6-T16 plant: an internal core name from ops/\" {\n    _ = @import(\"core\").lifecycle.scan;\n}\n")'
    # 2. interfaces/: an internal core file through an alias, used in a test block (the interfaces step).
    plant interfaces-internal zig/src/interfaces/mcp.zig yes '
import sys
p = sys.argv[1]
open(p, "a").write("\nconst plant_publication = @import(\"core\").publication;\n\ntest \"S6-T16 plant: an internal core name from interfaces/\" {\n    _ = plant_publication.publish;\n}\n")'
    # 3. interfaces/: a name api lacks, through api (Zig refuses it too).
    plant interfaces-api-lacks zig/src/interfaces/cli.zig yes '
import sys
p = sys.argv[1]
open(p, "a").write("\ntest \"S6-T16 plant: a name api lacks\" {\n    _ = @import(\"core\").api.lifecycle.scan;\n}\n")'
    # 4. core/core.zig: an api entry under another name than its own (checker only).
    plant api-renamed zig/src/core/core.zig no '
import sys
p = sys.argv[1]
s = open(p).read()
a = "pub const publishSerialized = internal.lifecycle.publishSerialized;"
assert a in s
open(p, "w").write(s.replace(a, "pub const publish = internal.lifecycle.publishSerialized;"))'
    # 5. core/core.zig: an api entry without its doc comment (checker only).
    plant api-undocumented zig/src/core/core.zig no '
import sys
p = sys.argv[1]
s = open(p).read()
a = "        /// The fuzzy policy id: \"fuzzy-v1\".\n"
assert a in s
open(p, "w").write(s.replace(a, ""))'
    # 6. The example of docs/core-api.md as a new interface: it compiles, its test forces the body's
    #    analysis, and the checker passes once the file is assigned (FILES) and named in its root.
    plant core-api-example zig/src/interfaces/peek.zig yes '
import re, sys
from pathlib import Path
p, root = Path(sys.argv[1]), Path(sys.argv[2])
doc = (root / "docs/core-api.md").read_text()
code = re.search(r"```zig\n(const std = .*?)```", doc, re.S).group(1)
p.write_text(code + "\ntest \"S6-T16: the core-api.md example compiles\" {\n    _ = &peek;\n}\n")
r = root / "zig/src/interfaces/interfaces.zig"
s = r.read_text()
s = s.replace("pub const mcp = @import(\"mcp.zig\");", "pub const mcp = @import(\"mcp.zig\");\npub const peek = @import(\"peek.zig\");", 1)
s = s.replace("        _ = mcp;\n", "        _ = mcp;\n        _ = peek;\n", 1)
r.write_text(s)
c = root / "scripts/check_layers.py"
t = c.read_text()
a = "    \"interfaces/mcp.zig\": "
assert a in t
c.write_text(t.replace(a, "    \"interfaces/peek.zig\": (\"interfaces\", \"the docs/core-api.md example (S6-T16 plant)\"),\n" + a, 1))
import subprocess
subprocess.run([sys.executable, "-I", str(c), "--root", str(root), "--write-doc"], check=True)'
    ;;
esac
