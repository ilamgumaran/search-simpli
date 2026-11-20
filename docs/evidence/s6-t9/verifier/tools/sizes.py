"""S6-T9 verifier: index sizes, main vs head, from the bytes on disk. sizes.py MAIN_IDX_ROOT HEAD_IDX_ROOT corpus...
Total = every file of the index directory except WRITER.LOCK (one generation, MANIFEST and INDEX-STATE.json included).
Prints the state section, the file-name catalog, the total, and whether every other file is byte-identical."""
import os, sys
m, h = sys.argv[1], sys.argv[2]
def files(d):
    return {f: os.path.getsize(os.path.join(d, f)) for f in os.listdir(d) if f != "WRITER.LOCK"}
def pct(a, b):
    return f"{(b - a) / a * 100:+.1f} %"
for c in sys.argv[3:]:
    fm, fh = files(f"{m}/{c}"), files(f"{h}/{c}")
    assert set(fm) == set(fh), (c, set(fm) ^ set(fh))
    st = [f for f in fm if f.startswith("state-")][0]; ca = [f for f in fm if f.startswith("filenames-")][0]
    tm, th = sum(fm.values()), sum(fh.values())
    others = [f for f in fm if f not in (st, ca, "MANIFEST")]
    same = all(open(f"{m}/{c}/{f}", "rb").read() == open(f"{h}/{c}/{f}", "rb").read() for f in others)
    print(f"{c}: total {tm:,} -> {th:,} ({th - tm:+,}, {pct(tm, th)}); state {fm[st]:,} -> {fh[st]:,} ({fh[st] - fm[st]:+,}, {pct(fm[st], fh[st])}); "
          f"catalog {fm[ca]:,} -> {fh[ca]:,} ({fh[ca] - fm[ca]:+,}, {pct(fm[ca], fh[ca])}); MANIFEST {fm['MANIFEST']} -> {fh['MANIFEST']}; "
          f"other {len(others)} files byte-identical: {same}")
