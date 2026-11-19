"""S6-T8 verifier (sixth check): the failing tests of the named plants, from plants6/out/NAME.txt. fails6.py NAME..."""
import re, sys
from pathlib import Path
out = Path(__file__).resolve().parent.parent / "plants6" / "out"
for n in sys.argv[1:]:
    t = (out / f"{n}.txt").read_text(errors="replace")
    print(n)
    for m in re.findall(r"^error: '(.*)' (failed|terminated)", t, re.M):
        print("   ", m[0][:170], m[1])
