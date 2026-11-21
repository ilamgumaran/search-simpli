"""Verifier's own measurement: core names ops/ and interfaces/ use on main, vs core.api at head.

Own tokenizer (tokdiff.toks). Reads, per file of zig/src/ops and zig/src/interfaces at BASE:
  inline   @import("core").F.N
  aliases  const A = @import("core").F;   then A.N  (A not preceded by '.')
  alias of a name  const A = @import("core").F.N;  -> (F, N)
Reports anything else (whole-module use, deeper aliases) so nothing is silently missed.
Then parses core.zig's api at HEAD by regex and checks each entry's shape and declaration kind.
"""
import re
import subprocess
import sys
from collections import Counter, defaultdict

sys.path.insert(0, sys.argv[4])
from tokdiff_lib import toks  # noqa: E402

REPO, BASE, HEAD = sys.argv[1], sys.argv[2], sys.argv[3]


def git(*a):
    return subprocess.run(["git", "-C", REPO, *a], capture_output=True, text=True, check=True).stdout


IMP = [("b", "@import"), ("p", "("), ("s", '"core"'), ("p", ")")]
files = [f for f in git("ls-tree", "-r", "--name-only", BASE).splitlines()
         if f.endswith(".zig") and (f.startswith("zig/src/ops/") or f.startswith("zig/src/interfaces/"))]
uses = Counter()
per_file = defaultdict(set)
odd = []
for f in files:
    t = toks(git("show", f"{BASE}:{f}"))
    aliases = {}
    for i in range(len(t)):
        if t[i:i + 4] != IMP:
            continue
        chain, j = [], i + 4
        while j + 1 < len(t) and t[j] == ("p", ".") and t[j + 1][0] == "w":
            chain.append(t[j + 1][1])
            j += 2
        bound = i >= 3 and t[i - 3] == ("w", "const") and t[i - 1] == ("p", "=") and t[j] == ("p", ";")
        if bound and len(chain) == 1:
            aliases[t[i - 2][1]] = chain[0]
        elif len(chain) >= 2:
            uses[(chain[0], chain[1])] += 1
            per_file[f].add((chain[0], chain[1]))
        else:
            odd.append((f, i, chain, bound))
    for a, fname in aliases.items():
        for k in range(len(t)):
            if t[k] != ("w", a) or (k > 0 and t[k - 1] == ("p", ".")):
                continue
            if k >= 1 and t[k - 1] == ("w", "const") and t[k + 1] == ("p", "="):
                continue  # the binding
            if t[k + 1] == ("p", ".") and t[k + 2][0] == "w":
                uses[(fname, t[k + 2][1])] += 1
                per_file[f].add((fname, t[k + 2][1]))
            elif t[k + 1] != ("p", ":"):
                odd.append((f, k, a, "alias used not as A.N"))
measured = set(uses)
print(f"files read: {len(files)}; distinct names: {len(measured)}; uses: {sum(uses.values())}; core files: {len({f for f, _ in measured})}")
for o in odd:
    print("ODD", o)

core = git("show", f"{HEAD}:zig/src/core/core.zig")
start = core.index("pub const api = struct {")
end = core.index("\nconst internal = @This();")
block = core[start:end]
api = set()
shape_bad = []
ns = None
for line in block.splitlines():
    s = line.strip()
    m = re.fullmatch(r"pub const (\w+) = struct \{", s)
    if m and m.group(1) != "api":
        ns = m.group(1)
        continue
    m = re.fullmatch(r"pub const (\w+) = (.+);", s)
    if m:
        name, rhs = m.groups()
        if rhs != f"internal.{ns}.{name}":
            shape_bad.append((ns, name, rhs))
        api.add((ns, name))
print(f"api entries: {len(api)} in {len({n for n, _ in api})} namespaces; shape problems: {shape_bad}")
print("measured - api:", sorted(measured - api))
print("api - measured:", sorted(api - measured))

# declaration kind of each api name in its file at HEAD
kinds = Counter()
for nsn, name in sorted(api):
    text = git("show", f"{HEAD}:zig/src/core/{nsn}.zig")
    m = re.search(rf"^pub (?:inline |noinline |export )?(const|var|fn) {re.escape(name)}\b", text, re.M)
    kinds[m.group(1) if m else "NOT FOUND top-level pub"] += 1
    if not m or m.group(1) == "var":
        print("KIND", nsn, name, m.group(1) if m else None)
print("declaration kinds:", dict(kinds))
for f in sorted(per_file):
    print(f, len(per_file[f]))
