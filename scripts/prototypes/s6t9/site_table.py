"""S6-T9 ruling 7(a), 7(b): the refusal-site table from run_plant.sh's outputs, as Markdown rows.

    python3 -I site_table.py SITES_DIR=COMMIT [SITES_DIR=COMMIT ...]

Folders later on the command line take precedence (a plant rerun at a later commit shows that run). One row per plant of plants_sites.py, in its order: the site (the plant's description), the format it belongs to,
where a publish or a reader reaches it (WHERE below, written from the code, not from the results), the number of
tests the plant failed (or crashed), and up to three of their names, shortened. A plant that failed no test is shown
in bold as 0. Not part of any library.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from plants_sites import P  # noqa: E402

STATE = "state v3"
WHERE = {
    "s-count-bound": (STATE, "decode: pointer, carrying write"),
    "b-count-bound-loose": (STATE, "decode"),
    "b-count-bound-tight": (STATE, "decode"),
    "s-walk-headroom": (STATE, "decode"),
    "b-walk-headroom-loose": (STATE, "decode"),
    "b-walk-headroom-tight": (STATE, "decode"),
    "s-walk-length": (STATE, "decode"),
    "b-walk-length-loose": (STATE, "decode"),
    "b-walk-length-tight": (STATE, "decode"),
    "s-v3-unknown-flag": (STATE, "decode"),
    "s-v2-bit6": ("state v2", "decode"),
    "s-ref-label-count": (STATE, "decode"),
    "b-ref-label-count-tight": (STATE, "decode"),
    "b-ref-label-count-loose": (STATE, "decode"),
    "s-ref-root-index": (STATE, "decode"),
    "s-ref-chunker-index": (STATE, "decode"),
    "s-ref-zero-mtime": (STATE, "decode"),
    "s-ref-zero-chunker": (STATE, "decode"),
    "s-ref-zero-moved": (STATE, "decode"),
    "s-S1": (STATE, "decode: pointer, carrying write"),
    "s-S2": (STATE, "decode: pointer, carrying write"),
    "s-S3": (STATE, "decode: pointer, carrying write"),
    "b-S3-loose": (STATE, "decode"),
    "b-S3-tight": (STATE, "decode"),
    "s-S4": (STATE, "decode: pointer, carrying write"),
    "b-S4-loose": (STATE, "decode"),
    "b-S4-tight": (STATE, "decode"),
    "s-S5": (STATE, "decode: pointer, carrying write"),
    "b-S5-prefix-loose": (STATE, "decode (`relativeOf`)"),
    "b-S5-prefix-tight": (STATE, "decode (`relativeOf`)"),
    "s-S5-separator": (STATE, "decode (`relativeOf`)"),
    "s-encode-refs-length": (STATE, "encode (the writer's own list)"),
    "b-refers-order": (STATE, "encode (which entries are references)"),
    "s-section-v3-version": (STATE, "section header: pointer, carrying write"),
    "s-table-doc-length": (STATE, "pointer (`sourceTableOf`)"),
    "s-table-doc-checksum": (STATE, "pointer (`sourceTableOf`)"),
    "s-table-doc-version": (STATE, "pointer (`sourceTableOf`)"),
    "s-table-src-length": (STATE, "pointer (`sourceTableOf`)"),
    "s-table-src-checksum": (STATE, "pointer (`sourceTableOf`)"),
    "s-table-src-format": (STATE, "pointer (`sourceTableOf`)"),
    "s-writer-v1-source": (STATE, "carrying write (previous source v1)"),
    "s-M1": ("manifest v2.6", "manifest decode and encode"),
    "s-M2": ("manifest v2.6", "manifest decode and encode"),
    "s-M3": ("manifest v2.6", "`validateState`: carrying write, pointer"),
    "s-M4-manifest": ("manifest v2.6", "`validateFilenameSections`: eager open, writer"),
    "s-M4-load": ("manifest v2.6", "`filename_field.loadBytes`: lazy load"),
    "s-C1": ("catalog v6", "catalog decode: eager open, lazy load"),
    "s-C2": ("catalog v6", "catalog decode: eager open, lazy load"),
    "s-catalog-v5": ("catalog", "`inspectCatalog`"),
    "s-documents-v6": ("documents", "`segment.inspect`"),
    "s-carried-inspect": ("catalog v6", "writer: the built catalog checked"),
    "d-state-v3-test": ("7(d)", "`state_v3_test.zig` runs"),
    "d-compat-s6t9-test": ("7(d)", "`compat_s6t9_test.zig` runs"),
}


def short(name: str) -> str:
    name = name.split(".test.", 1)[-1]
    name = re.sub(r"^S6-T9:? ?", "", name)
    return (name[:70] + "…") if len(name) > 71 else name


dirs = [(Path(a.split("=")[0]), a.split("=")[1]) for a in sys.argv[1:]]
print("| # | Plant | Site | Format | Reached at | At | Tests failed | Which (up to three) |")
print("| --- | --- | --- | --- | --- | --- | --- | --- |")
for i, (n, (desc, _)) in enumerate(P.items(), 1):
    fmt, where = WHERE[n]
    found = [(d, c) for d, c in dirs if (d / "out" / f"{n}.txt").exists()]
    if not found:
        print(f"| {i} | `{n}` | {desc} | {fmt} | {where} | | NOT RUN | |")
        continue
    d, commit = found[-1]
    out = d / "out" / f"{n}.txt"
    t = out.read_text(errors="replace")
    fails = sorted(set(re.findall(r"error: '(.+?)' failed:", t)))
    crashed = sorted(set(re.findall(r"error: '(.+?)' terminated with signal", t)))
    runs = [l for l in t.splitlines() if re.search(r"run test \d+ pass", l)]
    crash_count = 0
    for l in runs:
        m = re.search(r"(\d+) crash", l)
        if m:
            crash_count = max(crash_count, int(m.group(1)))
    total = len(fails) + max(len(crashed), crash_count)
    names = [short(f) for f in fails] + [f"(crash) {short(f)}" for f in crashed]
    if crash_count and not crashed:
        names.append(f"({crash_count} crash)")
    count = f"**0**" if total == 0 else str(total)
    print(f"| {i} | `{n}` | {desc} | {fmt} | {where} | `{commit}` | {count} | {'; '.join(names[:3])} |")
