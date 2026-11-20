"""S6-T9 verifier: the same-answer jobs. sajobs.py V > jobs.txt; each line: KIND BUILD SET CORPUS (KIND abi|find|surf).
Pairs compared later by sacmp.py: (head, X) against (main, Y)."""
import sys
PAIRS = [("head", "head", "main", "main"), ("head", "main", "main", "main"), ("head", "h1-head", "main", "main"),
         ("head", "m1-head", "main", "m1-main"), ("head", "c1-head", "main", "c1-main"), ("head", "c2-head", "main", "c2-main"),
         ("head", "headchg", "main", "mainchg")]
for p in ("pre8", "pre7", "pre4"):
    PAIRS += [("head", p, "main", p), ("head", f"{p}-head", "main", "m1-main"), ("head", f"{p}-headc", "main", "c1-main")]
if __name__ == "__main__":
    jobs = set()
    for c in ("j2", "family", "fixtures", "timing-10k", "prose-10k", "tamil-10k"):
        for b1, s1, b2, s2 in PAIRS:
            for k in ("abi", "find", "surf"):
                jobs.add((k, b1, s1, c)); jobs.add((k, b2, s2, c))
    for j in sorted(jobs):
        print(*j)
