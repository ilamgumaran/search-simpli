#!/usr/bin/env python3
"""S6-T5 verifier, behaviour (check 1 and part of check 2).

    beh1.py build LIB DIR            build fixture F1 (and F2, hidden/absent words) into DIR with LIB
    beh1.py run LIB DIR OUT.json     run the battery on the fixtures with LIB, write every answer

One library per process.
"""
import json
import random
import sys

sys.path.insert(0, __import__("os").path.dirname(__file__))
import ssdrv  # noqa: E402

ROOTS = [{"root_id": "north", "label": "North", "kind": "host"},
         {"root_id": "south", "label": "South", "kind": "host"}]
F1 = [
    {"root": "north", "path": "lantern-festival.md", "text": "# Evening\n\nthe lantern parade crossed the bridge with drums\n"},
    {"root": "north", "path": "orchard/plum-ledger.md", "text": "# Notes\n\napples and pears ripened slowly\n"},
    {"root": "north", "path": "apple-basket.md", "text": "# Basket\n\nwoven reeds\n"},
    {"root": "north", "path": "vault/walrus-secrets.md", "text": "# Secrets\n\nnarwhal tusks shimmer\n", "labels": ["team:otter"]},
    {"root": "south", "path": "canyon-echo.md", "text": "# Echo\n\npebble streams wander\n"},
    {"root": "north", "path": "studio-log.md", "text": "# Studio\n\nshe painted while painting paints and walked walking walks\n"},
    {"root": "south", "path": "walk-map.md", "text": "# Map\n\nhiking trails\n"},
]
WORDS = ["lantern", "festival", "plum", "ledger", "canyon", "parade", "bridge", "slowly", "qorvix", "walrus",
         "narwhal", "pebble", "lantren", "bridgr", "pear", "apple", "drum", "orchard", "secrets", "tusks", "basket",
         "Lantern", "LANTERN", "echo", "reeds", "festivl", "pebbel", "paint", "walk", "painter", "walkng", "studio", "hiking"]
SCOPES = [{}, {"roots": ["north"]}, {"roots": ["south"]}, {"principal_labels": ["team:otter"]},
          {"path_prefix": "north/orchard/"}, {"roots": ["north"], "principal_labels": ["team:otter"]},
          {"path_prefix": "south/"}]
FIELDS = ["content", "both", "filename"]

# F2: hidden words. Each hidden word sits in exactly one hidden place; absent words of the same length are nowhere.
LETTERS = "bcdfghjklmnprstvz"
VOWELS = "aeiou"


def word(rng, n):
    return "".join(rng.choice(LETTERS) if i % 2 == 0 else rng.choice(VOWELS) for i in range(n))


def f2_plan():
    rng = random.Random(20261116)
    seen = set()

    def fresh(n):
        while True:
            w = word(rng, n)
            if w not in seen:
                seen.add(w)
                return w
    places = []  # (kind, hidden word, absent word, scope)
    files = [{"root": "north", "path": "meadow-notes.md", "text": "# Meadow\n\nfoxes and owls hunted the meadow\n"},
             {"root": "north", "path": "kettle-diary.md", "text": "# Kettle\n\nthe kettle whistled loudly\n"}]
    # Labelled files: 8 files, each name two hidden words, body three hidden words.
    for i in range(8):
        a, b = fresh(5 + i % 4), fresh(6 + i % 3)
        body = [fresh(5 + (i + j) % 5) for j in range(3)]
        files.append({"root": "north", "path": f"locked/{a}-{b}.md", "text": "# " + body[0] + "\n\n" + " ".join(body) + " meadow\n",
                      "labels": [f"team:t{i}"]})
        for w in [a, b] + body:
            places.append(("label", w, {}))
    # The south root, left out by roots [north]: 8 files.
    for i in range(8):
        a, b = fresh(5 + i % 4), fresh(7 - i % 3)
        body = [fresh(5 + (i + j) % 4) for j in range(3)]
        files.append({"root": "south", "path": f"{a}-{b}.md", "text": "# " + body[0] + "\n\n" + " ".join(body) + " kettle\n"})
        for w in [a, b] + body:
            places.append(("root", w, {"roots": ["north"]}))
    # Outside the path prefix north/open/: 8 files under north/shut/.
    for i in range(8):
        a, b = fresh(6 + i % 3), fresh(5 + i % 4)
        body = [fresh(5 + (i + j) % 5) for j in range(3)]
        files.append({"root": "north", "path": f"shut/{a}-{b}.md", "text": "# " + body[0] + "\n\n" + " ".join(body) + " owls\n"})
        for w in [a, b] + body:
            places.append(("prefix", w, {"path_prefix": "north/open/"}))
    files.append({"root": "north", "path": "open/lamp-shelf.md", "text": "# Shelf\n\nmeadow lamp foxes kettle\n"})
    # Near-visible hidden words: one edit from a visible word (meadow, kettle, foxes), so both the hidden and the
    # absent word may be expanded; each hidden one only in a labelled file's name and body.
    near = []
    for base_word, hid, ab in (("meadow", "meadoq", "meadox"), ("kettle", "kettlq", "kettlz"), ("whistled", "whistlez", "whistleq")):
        files.append({"root": "north", "path": f"locked/{hid}-x.md", "text": f"# {hid}\n\n{hid} words\n", "labels": ["team:near"]})
        near.append((hid, ab))
    pairs = []
    for kind, w, scope in places:
        pairs.append({"kind": kind, "hidden": w, "absent": fresh(len(w)), "scope": scope})
    for hid, ab in near:
        pairs.append({"kind": "near-label", "hidden": hid, "absent": ab, "scope": {}})
    return files, pairs


def build(lib_path, directory):
    lib = ssdrv.Lib(lib_path)
    lib.apply(directory + "/f1", ROOTS, F1)
    files, _ = f2_plan()
    lib.apply(directory + "/f2", ROOTS, files)
    # F2 without its hidden files (the cross-index label-wall check).
    visible = [f for f in files if not f.get("labels") and f["root"] == "north"]
    lib.apply(directory + "/f2bare", ROOTS, visible)
    print("built", directory)


def f1_queries():
    rng = random.Random(7)
    qs = list(WORDS)
    for _ in range(400):
        n = rng.randint(2, 4)
        qs.append(" ".join(rng.choice(WORDS) for _ in range(n)))
    qs += ["!!! ...", "lantern lantern", "Lantern lantern LANTERN", "qorvix apple pear", "pear apple drum",
           "festival lantren pear", "apple qorvix", "drum apple", "plum pear apple qorvix lantren"]
    return qs


def run(lib_path, directory, out_path):
    lib = ssdrv.Lib(lib_path)
    out = {"version": lib.version(), "f1": [], "f2": [], "f2bare": [], "errors": []}
    h = lib.open(directory + "/f1")
    for q in f1_queries():
        for scope in SCOPES:
            for field in FIELDS:
                ans, err = lib.query(h, q, field, scope)
                out["f1"].append({"q": q, "scope": scope, "field": field, "answer": ans.decode() if ans else None, "err": err})
    for field in FIELDS:
        for q in ("lantern", "lantren pear", "!!! ..."):
            ans, err = lib.query(h, q, field, {}, vector=[1.0, 0.0])
            out["f1"].append({"q": q, "scope": {}, "field": field, "vector": True, "answer": ans.decode() if ans else None, "err": err})
    lib.close(h)
    _, pairs = f2_plan()
    h = lib.open(directory + "/f2")
    contexts = ["{}", "meadow {}", "{} kettlx foxs", "owls {} meadow kettle", "{} {}"]
    for p in pairs:
        for ctx in contexts:
            for side in ("hidden", "absent"):
                q = ctx.format(p[side], p[side]) if ctx.count("{}") == 2 else ctx.format(p[side])
                for field in FIELDS:
                    ans, err = lib.query(h, q, field, p["scope"])
                    out["f2"].append({"pair": p, "ctx": ctx, "side": side, "q": q, "field": field,
                                      "answer": ans.decode() if ans else None, "err": err})
    lib.close(h)
    # Cross-index: f2 (hidden files present, hidden by scope) against f2bare (absent); roots [north] and no labels.
    h, hb = lib.open(directory + "/f2"), lib.open(directory + "/f2bare")
    for p in pairs:
        if p["kind"] not in ("label", "root", "near-label"):
            continue
        for ctx in contexts:
            q = ctx.format(p["hidden"], p["hidden"]) if ctx.count("{}") == 2 else ctx.format(p["hidden"])
            for field in FIELDS:
                a, _ = lib.query(h, q, field, {"roots": ["north"]})
                b, _ = lib.query(hb, q, field, {"roots": ["north"]})
                out["f2bare"].append({"q": q, "field": field, "kind": p["kind"], "with_hidden": a.decode() if a else None,
                                      "bare": b.decode() if b else None})
    lib.close(h)
    lib.close(hb)
    json.dump(out, open(out_path, "w"), ensure_ascii=False)
    print("ran", lib.version(), len(out["f1"]), len(out["f2"]), len(out["f2bare"]))


if __name__ == "__main__":
    if sys.argv[1] == "build":
        build(sys.argv[2], sys.argv[3])
    else:
        run(sys.argv[2], sys.argv[3], sys.argv[4])
