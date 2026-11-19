"""S6-T8 F2 (ruling after the Verdict): the unified diff of named functions' normalised code between two unstripped
builds (compare_functions.normalise).  f2_fdiff.py COMPARE_FUNCTIONS_DIR A.s B.s NAME [NAME...]  Not part of any library."""
import sys, difflib
sys.path.insert(0, sys.argv[1])
import compare_functions as cf
a, b = cf.parse(sys.argv[2]), cf.parse(sys.argv[3])
for name in sys.argv[4:]:
    na, _ = cf.normalise(name, a[name]); nb, _ = cf.normalise(name, b[name])
    print("###", name, len(na), len(nb))
    for line in difflib.unified_diff(na, nb, lineterm="", n=1):
        print(line)
