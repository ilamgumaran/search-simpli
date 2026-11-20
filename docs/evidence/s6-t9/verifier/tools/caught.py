"""S6-T9 verifier: for each finished plant, the tests that failed (from plants.noindex/out/NAME.txt)."""
import re, sys, pathlib
P = pathlib.Path(sys.argv[1])
for line in open(P / "results.txt"):
    n = line.split()[0]
    out = (P / "out" / f"{n}.txt")
    names = re.findall(r"^error: '(.*)' (?:failed|terminated with signal \w+)", out.read_text(errors="replace"), re.M) if out.exists() else []
    print(f"{n}: {len(names)} failed" + "".join(f"\n  - {x[:160]}" for x in dict.fromkeys(names)))
