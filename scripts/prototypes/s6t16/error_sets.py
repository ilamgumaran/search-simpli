#!/usr/bin/env python3
"""S6-T16: the error sets of the public core functions, as the compiler infers them.

    python3 -I scripts/prototypes/s6t16/error_sets.py PROBE_OUTPUT ZIG_LIB_STD

PROBE_OUTPUT is the output of a scratch `zig test` (scripts/prototypes/s6t16/error_probe.sh)
that prints, for each public function, `name -> payload: Error1 Error2 ...` from
`@typeInfo` of its return type's error set. Each error name is classed as
`OutOfMemory`, the core's own (named in an `error{...}` set or as `error.X` in a
zig/src/core/ file, and not in Zig's standard library), or `std` (the standard
library's: file-system, I/O and system errors). A name in both is the core's when
a core file declares it in an `error{...}` set. Prints one block per function.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SET = re.compile(r"error\s*\{([^}]*)\}", re.S)
NAME = re.compile(r"\b([A-Z][A-Za-z0-9_]*)\b")
USE = re.compile(r"\berror\.([A-Z][A-Za-z0-9_]*)")


def names_in(paths, uses=True):
    declared, used = set(), set()
    for path in paths:
        text = re.sub(r"//[^\n]*", "", path.read_text(encoding="utf-8", errors="replace"))
        for block in SET.findall(text):
            declared.update(NAME.findall(block))
        if uses:
            used.update(USE.findall(text))
    return declared, used


def main(argv) -> int:
    probe, std_dir = Path(argv[0]), Path(argv[1])
    core_declared, core_used = names_in([p for p in (REPO / "zig/src/core").glob("*.zig")])
    std_declared, std_used = names_in(list(std_dir.rglob("*.zig")))
    std_names = std_declared | std_used
    for line in probe.read_text(encoding="utf-8").splitlines():
        m = re.search(r"([a-z_]+\.[A-Za-z_]+) -> ([^:]+):(.*)$", line)
        if not m:
            continue
        name, payload, rest = m.group(1), m.group(2), m.group(3).split()
        if rest == ["no", "error", "union"]:
            print(f"## {name}\n\nreturns {payload}: no error union.\n")
            continue
        oom = [e for e in rest if e == "OutOfMemory"]
        own = [e for e in rest if e != "OutOfMemory" and (e in core_declared or (e in core_used and e not in std_names))]
        std = [e for e in rest if e != "OutOfMemory" and e not in own]
        print(f"## {name}\n")
        print(f"returns `{payload}`; {len(rest)} errors: OutOfMemory {len(oom)}, the core's own {len(own)}, "
              f"std {len(std)}.\n")
        print("- the core's own: " + (" ".join(own) or "none"))
        print("- std: " + (" ".join(std) or "none"))
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
