"""List the failing tests of a zig test log: the last 'N/M name...' header before each 'FAIL (' line."""
import re, sys
cur = None
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    m = re.search(r"\d+/\d+ ([a-z0-9_]+)\.test\.(.{0,60})", line)
    if m:
        cur = m.group(1) + ": " + m.group(2).split("...")[0]
    f = re.search(r"FAIL \(([A-Za-z]+)\)", line)
    if f:
        print("   FAIL", cur, "->", f.group(1))
