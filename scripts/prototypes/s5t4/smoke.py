import sys, json
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import j2run
from analyzer_v3 import Cfg
b = json.loads((j2run.PACK / "baseline.json").read_text())
for label, cfg, surf in (("py-today", None, "python-reference"), ("eng-today", Cfg(name="eng", side="query-none", base_fold="simple"), "searchd")):
    r = j2run.run(cfg) if cfg is None else None
    if cfg is not None:
        import analyzer_v3 as v3, src.search_platform.core as core
        # engine mirror: body simple fold, nothing else
        r = j2run.run(Cfg(name="eng", side="index", base_fold="simple"))
    for v in ("content", "both"):
        base = b["surfaces"][surf]["runs"][v]
        diff = {q: (rk, r["runs"][v]["queries"][q].get("first_grade2_rank")) for q, rk in base["first_grade2_rank"].items() if r["runs"][v]["queries"][q].get("first_grade2_rank") != rk}
        sl = {s: (round(r["runs"][v]["slices"][s]["success_at_1"], 3), round(r["runs"][v]["slices"][s]["mrr_at_10"], 3)) for s in base["slices"]}
        bsl = {s: (round(base["slices"][s]["success_at_1"], 3), round(base["slices"][s]["mrr_at_10"], 3)) for s in base["slices"]}
        print(label, v, "rank diffs vs", surf, diff)
        print("   slices differ:", {s: (bsl[s], sl[s]) for s in sl if sl[s] != bsl[s]})
