"""S6-T8 F2: the three per-posting loops of filename_field.queryDecodedTraced (30 instructions before each call to
scoring.bm25Contribution, 12 after), diffed between two unstripped builds.
    f2_loopdiff.py COMPARE_FUNCTIONS_DIR A.s B.s   Not part of any library."""
import sys, difflib
sys.path.insert(0, sys.argv[1])
import compare_functions as cf
name = "_filename_field.queryDecodedTraced"
def windows(path):
    body, _ = cf.normalise(name, cf.parse(path)[name])
    idx = [i for i, l in enumerate(body) if "_scoring.bm25Contribution" in l]
    return [body[i - 30:i + 12] for i in idx]
a, b = windows(sys.argv[2]), windows(sys.argv[3])
print("call sites", len(a), len(b))
for k, (wa, wb) in enumerate(zip(a, b)):
    d = [l for l in difflib.unified_diff(wa, wb, lineterm="", n=0) if not l.startswith(("---", "+++"))]
    print(f"site {k}: {'identical' if not d else str(len(d)) + ' diff lines'}")
    for l in d[:30]:
        print("   ", l)
