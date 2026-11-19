"""S6-T8 verifier: the block-boundary corpus for oneByteTableEnd's 16-token steps (invented text). blocks_gen.py OUT_DIR
Token counts 0, 1, 15, 16, 17, 31, 32, 33, 47, 48, 64, 100; in a 40-token chunk an escape of the length, of the gap or of
both at token position 0, 1, 14-18, 30-34, 39; an escape in the last token of 16-, 17- and 32-token chunks."""
import sys
from pathlib import Path
out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
def w(i): return "w%02d" % (i % 100)
files = {}
for n in (0, 1, 15, 16, 17, 31, 32, 33, 47, 48, 64, 100):
    files["count-%03d.txt" % n] = (" ".join(w(i) for i in range(n)) if n else "!!! ...") + "\n"
for p in (0, 1, 14, 15, 16, 17, 18, 30, 31, 32, 33, 34, 39):
    toks = [w(i) for i in range(40)]
    toks[p] = "longtoken" + "x" * (10 + p % 3)
    files["esc-len-at-%02d.txt" % p] = " ".join(toks) + "\n"
    toks = [w(i) for i in range(40)]
    files["esc-gap-at-%02d.txt" % p] = " ".join(toks[:p]) + (" " * 12 if p else " " * 9) + " ".join(toks[p:]) + "\n"
    toks = [w(i) for i in range(40)]
    toks[p] = "both" + "y" * 20
    files["esc-both-at-%02d.txt" % p] = " ".join(toks[:p]) + (" " * 12 if p else " " * 9) + " ".join(toks[p:]) + "\n"
files["esc-last-32.txt"] = " ".join(w(i) for i in range(31)) + " " + "z" * 30 + "\n"
files["esc-last-17.txt"] = " ".join(w(i) for i in range(16)) + " " + "z" * 30 + "\n"
files["esc-last-16.txt"] = " ".join(w(i) for i in range(15)) + " " + "z" * 30 + "\n"
for k, v in files.items():
    (out / k).write_text(v, encoding="utf-8")
print(len(files), "files")
