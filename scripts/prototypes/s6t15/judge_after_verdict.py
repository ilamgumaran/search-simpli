#!/usr/bin/env python3
"""S6-T15 rework: judge the real runs after_verdict.py left, with this worktree's
checker and count comparison. For each plant: the copy's tree (SCRATCH/NAME/src, the
plant applied) and its full `zig build test --summary all` output
(SCRATCH/NAME/count-full.txt). The Zig run does not depend on either script (neither is
a build input), so the same output is compared again by the final scripts.

Usage: python3 -I judge_after_verdict.py WORKTREE SCRATCH > OUT"""
import re
import subprocess
import sys
from pathlib import Path

WT, SCRATCH = Path(sys.argv[1]), Path(sys.argv[2])
sys.path.insert(0, str(Path(__file__).resolve().parent))
from after_verdict_order import ORDER  # noqa: E402


def main():
    rows = []
    for name in ORDER:
        d = SCRATCH / name
        src, log = d / "src", d / "count-full.txt"
        if not log.is_file():
            print(f"## {name}: no run output, not judged\n")
            continue
        text = log.read_text(encoding="utf-8")
        lines = text.splitlines()
        at = max((i for i, line in enumerate(lines) if line.startswith("Build Summary:")), default=None)
        summary = "(no Build Summary)" if at is None else lines[at]
        steps = [] if at is None else [line for line in lines[at:] if line.startswith("+- run test")]
        ck = subprocess.run([sys.executable, "-I", str(WT / "scripts/check_layers.py"), "--root", str(src)],
                            capture_output=True, text=True)
        cc = subprocess.run([sys.executable, "-I", str(WT / "scripts/check_test_counts.py"), "--root", str(src),
                             "--log", str(log)], capture_output=True, text=True)
        static = [line for line in ck.stdout.splitlines()]
        counts = [line for line in cc.stdout.splitlines() if line.startswith("check_test_counts:")
                  and "note:" not in line]
        print(f"## {name}")
        print(f"real run: {summary}")
        for line in steps:
            print("  " + re.sub(r" \d+(\.\d+)?(ms|s|m) MaxRSS:\S+$", "", line))
        print(f"static checker (check_layers.py) exit {ck.returncode}:")
        for line in static[:6]:
            print("  " + line.replace(str(src), "<copy>")[:300])
        if len(static) > 6:
            print(f"  ... ({len(static) - 6} more lines)")
        print(f"count comparison (check_test_counts.py --log) exit {cc.returncode}:")
        for line in counts:
            print("  " + line.replace(str(src), "<copy>")[:300])
        print()
        rows.append((name, ck.returncode, [c for c in counts if "OK" not in c and "zig build test exited" not in c]))
    print("| Plant | static | count comparison |")
    print("|---|---|---|")
    for name, static_code, count_problems in rows:
        print(f"| {name} | {'fails' if static_code else 'passes'} | "
              f"{'fails: ' + '; '.join(p.split(': ', 1)[1] for p in count_problems) if count_problems else 'passes'} |")


if __name__ == "__main__":
    main()
