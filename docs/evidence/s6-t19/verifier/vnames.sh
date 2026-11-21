#!/usr/bin/env bash
# vnames.sh COPYDIR : run each test binary of the copy's own local cache directly from zig/,
# writing raw output to COPYDIR/raw-<step>.txt. Never removes anything.
set -uo pipefail
dir="$1"
for step in core operations interfaces tests test; do
  bins=$(find "$dir/.zc/o" -type f -name "$step" -perm -u+x)
  n=$(printf '%s\n' "$bins" | grep -c . )
  bin=$(printf '%s\n' "$bins" | head -1)
  echo "$step: $n binaries; $bin" | sed "s|$dir|COPY|"
  (cd "$dir/zig" && "$bin" > "$dir/raw-$step.txt" 2>&1; echo "  exit $?")
done
