#!/usr/bin/env python3
"""S6-T8 (rulings on the Report, item 2): which functions' machine code
differs between two builds, from `objdump -d --no-show-raw-insn
--no-leading-addr` of each (unstripped builds, so every function is named).

    python3 -I compare_functions.py A.s B.s [NAME_REGEX]

Each function's instructions are normalised: an address or a branch target
becomes `ADDR`, a `<symbol+offset>` keeps the symbol only when it is a named
function (an `OUTLINED_FUNCTION_n` becomes `OUTLINED`, and a branch inside
the function becomes `SELF+offset`), and a page offset (`adrp`/`add ...
@PAGEOFF`-style immediates after an `adrp`) is masked. Prints how many
functions are identical, differ, or exist in one build only, and lists the
differing ones whose names match NAME_REGEX (default: every one), with the
instruction counts and the count of calls to outlined functions on each
side. Not part of any library.
"""
import re
import sys

FUNC = re.compile(r"^<(.+)>:$")
TARGET = re.compile(r"0x[0-9a-f]+ <([^>+]+)(\+0x[0-9a-f]+)?>")
HEX = re.compile(r"0x[0-9a-f]+")


def parse(path: str) -> dict[str, list[str]]:
    functions: dict[str, list[str]] = {}
    name = None
    for raw in open(path, encoding="utf-8", errors="replace"):
        line = raw.strip()
        m = FUNC.match(line)
        if m:
            name = m.group(1)
            functions.setdefault(name, [])
            continue
        if name is None or not line or line.startswith("Disassembly of section"):
            continue
        functions[name].append(line)
    return functions


def normalise(name: str, body: list[str]) -> tuple[list[str], int]:
    out, outlined = [], 0
    previous_adrp = False
    for line in body:
        line = line.split(";")[0].strip()

        def target(m: re.Match) -> str:
            sym, off = m.group(1), m.group(2) or ""
            if sym == name:
                return f"SELF{off}"
            if sym.startswith("_OUTLINED_FUNCTION_"):
                return "OUTLINED"
            return sym + off

        if "OUTLINED_FUNCTION_" in line:
            outlined += 1
        line = TARGET.sub(target, line)
        line = re.sub(r"___anon_\d+", "ANON", line)
        op = line.split()[0] if line else ""
        if op in ("adrp", "adr") or (previous_adrp and op in ("add", "ldr", "str")):
            line = HEX.sub("PAGE", line)
        previous_adrp = op == "adrp"
        line = re.sub(r"#0x[0-9a-f]+", lambda m: m.group(0), line)
        if op in ("b", "bl", "b.eq", "b.ne") and "SELF" not in line and "OUTLINED" not in line:
            line = HEX.sub("ADDR", line)
        out.append(line)
    return out, outlined


def main() -> int:
    a, b = parse(sys.argv[1]), parse(sys.argv[2])
    pattern = re.compile(sys.argv[3]) if len(sys.argv) > 3 else None
    same, differ = 0, []
    for name in sorted(set(a) & set(b)):
        na, oa = normalise(name, a[name])
        nb, ob = normalise(name, b[name])
        if na == nb:
            same += 1
        else:
            differ.append((name, len(na), len(nb), oa, ob))
    only_a = sorted(set(a) - set(b))
    only_b = sorted(set(b) - set(a))
    named = [n for n in set(a) | set(b) if not n.startswith("_OUTLINED_FUNCTION_")]
    print(f"functions (outlined fragments excluded from the counts below): {len(named)}")
    print(f"identical: {sum(1 for n in set(a) & set(b) if not n.startswith('_OUTLINED_FUNCTION_') and n not in {d[0] for d in differ})}")
    print(f"differ: {sum(1 for d in differ if not d[0].startswith('_OUTLINED_FUNCTION_'))}")
    print(f"only in A: {sum(1 for n in only_a if not n.startswith('_OUTLINED_FUNCTION_'))}; only in B: "
          f"{sum(1 for n in only_b if not n.startswith('_OUTLINED_FUNCTION_'))}")
    print(f"outlined fragments: A {sum(1 for n in a if n.startswith('_OUTLINED_FUNCTION_'))}, "
          f"B {sum(1 for n in b if n.startswith('_OUTLINED_FUNCTION_'))}")
    for name, la, lb, oa, ob in differ:
        if name.startswith("_OUTLINED_FUNCTION_"):
            continue
        if pattern and not pattern.search(name):
            continue
        print(f"  {name}: {la} -> {lb} instructions, outlined calls {oa} -> {ob}")
    if pattern:
        for name in only_b:
            if pattern.search(name) and not name.startswith("_OUTLINED_FUNCTION_"):
                print(f"  only in B: {name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
