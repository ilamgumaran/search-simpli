#!/bin/sh
# Build searchd as the README says, then run every engine scenario.
# Usage, from the repository root, with Zig 0.16.0 on PATH (and, for the
# Dart scenarios, `dart` on PATH):
#   sh docs/testing/scenarios-engine/run.sh <new-scratch-folder> [--skip-scale] [--skip-dart]
# The scratch folder must not exist or be empty; results.md and results.json
# are written there.
set -eu
scratch=$1
shift
unset SEARCH_SIMPLI_LIBRARY_PATH
repo=$(cd "$(dirname "$0")/../../.." && pwd)
(cd "$repo/zig" && zig build -Doptimize=ReleaseSmall)
python3 -I "$repo/docs/testing/scenarios-engine/run_scenarios.py" \
    --searchd "$repo/zig/zig-out/bin/searchd" --scratch "$scratch" "$@"
