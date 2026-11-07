#!/usr/bin/env python3
"""S5-T4 prototype (planner scratch): what a candidate analyzer does to a corpus's
dictionary. Tokenizes every text file of DIR with the engine's v2 analyzer (simple
fold, as analyzer_v2.zig), keys every term with the candidate, and prints: the
counts per step, the classes of two or more v2 terms that share a key, and the
trap words. Counts only, no timing.
    python3 <this dir>/vocab_merges.py CAND DIR [--classes] [--traps]"""
from __future__ import annotations

import argparse
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import analyzer_v3 as v3  # noqa: E402
import proto_s5t4 as P  # noqa: E402
import src.search_platform.core as core  # noqa: E402

TRAPS = ["news", "species", "series", "was", "this", "bus", "glass", "has", "his", "its", "yes", "gas", "is",
         "us", "lens", "always", "christmas", "maths", "physics", "does", "goes", "shoes", "toes", "potatoes",
         "boxes", "classes", "buses", "horses", "houses", "caches", "headaches", "lunches", "ponies", "ties",
         "pies", "movies", "cookies", "strawberries", "dinosaurs", "biscuit's", "paati’s",
         "evening", "morning", "wedding", "nothing", "thing", "sing", "king", "bring", "spring", "during",
         "being", "ceiling", "skating", "skipping", "planting", "painting", "riding", "baking", "dancing",
         "swimming", "cancelling", "spelling",
         "feed", "need", "seed", "bed", "red", "shed", "hundred", "used", "speed", "agreed", "potted",
         "skipped", "planned", "painted", "planted", "cancelled", "baked", "carried", "tried",
         "café", "naïve", "frühling", "straße", "ﬁeld", "ﬂute", "ｇｏｇｇｌｅｓ", "１２", "noël", "résumé", "crêpe",
         "øre", "łódź", "æsop", "½", "x²", "Ⅻ",
         "புத்தகங்கள்", "யானைகள்", "கடைக்கு", "மரத்தில்", "நூலகத்தில்", "பாட்டியின்", "பழங்கள்", "தேர்வுக்கு",
         "பாடல்கள்", "பள்ளிக்கு", "காலை", "நாளை", "தேர்வு", "கால்", "நாள்", "தேர்", "வெயில்", "கள்", "நாட்கள்",
         "பள்ளியில்", "மரத்தின்"]


def vocab(root: Path) -> Counter:
    simple = v3.Cfg(base_fold="simple")
    c: Counter = Counter()
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix.casefold() not in core.DEFAULT_EXTENSIONS:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        c.update(set(v3.tokenize_cfg(text, simple)))
        c.update(set(v3.tokenize_cfg(path.stem, simple)))
    return c


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cand")
    ap.add_argument("dir", nargs="?")
    ap.add_argument("--classes", action="store_true")
    ap.add_argument("--traps", action="store_true")
    args = ap.parse_args()
    cfg = v3.replace(P.grid()[args.cand], side="index")
    if args.traps:
        for w in TRAPS:
            print(f"{w} -> {' '.join(v3.tokenize_cfg(w, cfg))}")
    if not args.dir:
        return
    voc = vocab(Path(args.dir))
    steps = {"F": v3.replace(v3.Cfg(base_fold="simple"), fold=True)}
    steps["A"] = v3.replace(steps["F"], accents=True)
    changed = Counter()
    classes = defaultdict(set)
    for t in voc:
        k = tuple(v3.key_terms(t, cfg))
        classes[" ".join(k)].add(t)
        if k != (t,):
            changed["any"] += 1
        f = v3.key_terms(t, steps["F"])
        a = v3.key_terms(t, steps["A"])
        if f != [t]:
            changed["F (NFKC_CF)"] += 1
        if a != f:
            changed["A (Latin accents)"] += 1
        for flag in ("plural", "ing", "ed", "tamil"):
            if getattr(cfg, flag):
                base = steps["A"] if cfg.accents else steps["F"] if cfg.fold else v3.Cfg(base_fold="simple")
                only = v3.replace(base, **{flag: True}, ed_double=cfg.ed_double)
                if v3.key_terms(t, only) != v3.key_terms(t, base):
                    changed[flag] += 1
    multi = {k: v for k, v in classes.items() if len(v) > 1}
    print(f"{args.dir}: {len(voc)} v2 terms, {len(classes)} v3 terms; changed {dict(changed)}; "
          f"classes of 2+: {len(multi)}, largest {max((len(v) for v in multi.values()), default=0)}; "
          f"v2 terms in them: {sum(len(v) for v in multi.values())}")
    if args.classes:
        for k in sorted(multi):
            print(f"  {k}: {', '.join(sorted(multi[k]))}")


if __name__ == "__main__":
    main()
