#!/usr/bin/env python3
"""S2-T1 bars (a), (b) and (c): the two publish doors, compared.

For every judged fixture and every corpus behind the chunk and BM25 goldens:

1. ``searchd index <root>`` publishes generation 1 with ``analyzer-v2``.
2. The chunks that snapshot holds are read back from its document section
   and written, unchanged, as interchange JSON with ``"analyzer_id":
   "analyzer-v2"``; ``searchd import-json`` publishes that.
3. Bar (b): the two snapshots' ``MANIFEST``, document section and lexical
   section are compared byte for byte, and the lexical sections are also
   compared decoded (term -> df and postings, document lengths, average
   length), so a difference in term order alone would show as "bytes differ,
   decoded equal". Then every query (judged, golden, and generated from each
   chunk's own words) runs through ``searchd evidence --top-k 1000`` on both
   snapshots and the full ranked lists are compared: chunk id, path, lines,
   fused score and BM25 score (|diff| <= 1e-6).
4. Bar (a): the judged queries are scored (success@1, MRR@10, recall@10) on
   the import door with ``analyzer-v2`` and with ``ascii-alnum-v1``.
5. Bar (c), with ``--baseline <searchd built from the previous main>``: the
   same chunks as ``ascii-alnum-v1`` interchange, the ABI demo interchange and
   an ``export_zig.py`` export are imported by both binaries, and the
   published files must be byte-identical.

Usage (from the repository root; ``$S`` is a scratch directory):
    python3 scripts/import_parity.py <searchd> $S/parity [--baseline <old searchd>]

Exit status 0 only when every comparison is identical and bar (a) is 1.00.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCORE_TOLERANCE = 1e-6
SECTION_FILES = ("MANIFEST", "documents-1.hybseg", "lexical-1.hyblex")

# (name, index root, judgments file or None, prefix the judgments put before
# paths relative to the index root, BM25-golden key or None)
CORPORA = [
    ("knowledge", "fixtures/knowledge", "fixtures/judgments.json", "", None),
    ("mixed-knowledge", "fixtures/mixed-knowledge", "fixtures/mixed-judgments.json", "", None),
    ("semantic-knowledge", "fixtures/semantic-knowledge", "fixtures/semantic-judgments.json", "", None),
    ("relevance-smoke", "fixtures/relevance-smoke/corpus", "fixtures/relevance-smoke/judgments.json", "", None),
    ("tamil", "fixtures/tamil/passages", "fixtures/tamil/judgments.json", "passages/", "tamil"),
    ("app-text", "fixtures/app-text", None, "", "app_text"),
    ("access-knowledge", "fixtures/access-knowledge", None, "", None),
    ("chunk-stress", "fixtures/chunk-stress", None, "", None),
]
PROBES = ["café", "cafe", "crêpes", "crepes", "தமிழ்", "ம", "dinosaurus", "dino"]


def run(command: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(command, check=True, capture_output=True, text=True, timeout=120, **kwargs)


def read_documents(section: bytes) -> list[dict]:
    assert section[:8] == b"HYBSEG01", section[:8]
    count, dimensions = struct.unpack_from("<II", section, 12)
    offset = 36
    documents = []
    for _ in range(count):
        id_len, path_len, text_len, vec_len, start, end, labels_len = struct.unpack_from("<7I", section, offset)
        offset += 28
        fields = []
        for length in (id_len, path_len, text_len, labels_len):
            fields.append(section[offset:offset + length].decode("utf-8"))
            offset += length
        vector = list(struct.unpack_from(f"<{vec_len}f", section, offset))
        offset += 4 * vec_len
        documents.append({
            "id": fields[0], "path": fields[1], "start_line": start, "end_line": end, "text": fields[2],
            "vector": vector, "required_labels": [label for label in fields[3].split("\n") if label],
        })
    assert offset == len(section)
    return documents


def read_lexical(section: bytes) -> dict:
    assert section[:8] == b"HYBLEX01", section[:8]
    documents, terms, postings = struct.unpack_from("<IIQ", section, 12)
    (average,) = struct.unpack_from("<f", section, 28)
    offset = 64
    lengths = list(struct.unpack_from(f"<{documents}I", section, offset))
    offset += 4 * documents
    dictionary = []
    for _ in range(terms):
        term_len, df, start, length = struct.unpack_from("<IIQQ", section, offset)
        offset += 24
        dictionary.append((section[offset:offset + term_len].decode("utf-8"), df, start, length))
        offset += term_len
    posting_values = [struct.unpack_from("<II", section, offset + 8 * i) for i in range(postings)]
    by_term = {term: (df, tuple(posting_values[start:start + length])) for term, df, start, length in dictionary}
    assert len(by_term) == terms
    return {"lengths": lengths, "average": average, "terms": by_term, "order": [entry[0] for entry in dictionary]}


def interchange(documents: list[dict], analyzer_id: str) -> str:
    payload = {"format_version": 1, "generation": 1, "analyzer_id": analyzer_id,
               "embedding_model_id": "none", "documents": documents}
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))


def ranked(searchd: str, snapshot: Path, query: str) -> list[dict]:
    output = run([searchd, "evidence", str(snapshot), query, "--top-k", "1000"]).stdout
    return json.loads(output)["evidence"]


def same_ranking(a: list[dict], b: list[dict]) -> bool:
    if len(a) != len(b):
        return False
    for x, y in zip(a, b):
        if (x["chunk_id"], x["path"], x["start_line"], x["end_line"]) != (y["chunk_id"], y["path"], y["start_line"], y["end_line"]):
            return False
        if abs(x["fused_score"] - y["fused_score"]) > SCORE_TOLERANCE or abs(x["lexical_score"] - y["lexical_score"]) > SCORE_TOLERANCE:
            return False
    return True


def generated_queries(documents: list[dict]) -> list[str]:
    queries = []
    for document in documents:
        words = re.findall(r"[^\W_]+", document["text"])
        if not words:
            continue
        queries += [words[0], " ".join(words[:3]), words[len(words) // 2], " ".join(words[-2:])]
    return queries


def judge(searchd: str, snapshot: Path, judgments: dict, prefix: str) -> dict:
    hits = reciprocal = recall = 0.0
    for query in judgments["queries"]:
        relevant = {item["path"][len(prefix):] if item["path"].startswith(prefix) else item["path"] for item in query["relevant"]}
        results = ranked(searchd, snapshot, query["query"])
        if query.get("path_prefix"):
            results = [r for r in results if r["path"].startswith(query["path_prefix"])]
        paths = []
        for result in results:
            if result["path"] not in paths:
                paths.append(result["path"])
        top = paths[:10]
        hits += 1.0 if top[:1] and top[0] in relevant else 0.0
        rank = next((i + 1 for i, path in enumerate(top) if path in relevant), None)
        reciprocal += 1.0 / rank if rank else 0.0
        recall += len(relevant & set(top)) / len(relevant)
    n = len(judgments["queries"])
    return {"queries": n, "success@1": hits / n, "mrr@10": reciprocal / n, "recall@10": recall / n}


def files_identical(a: Path, b: Path) -> list[str]:
    return [name for name in SECTION_FILES if (a / name).read_bytes() != (b / name).read_bytes()]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("searchd")
    parser.add_argument("scratch", type=Path)
    parser.add_argument("--baseline", help="searchd built from the previous main, for bar (c)")
    args = parser.parse_args()
    scratch = args.scratch
    if scratch.exists():
        shutil.rmtree(scratch)
    scratch.mkdir(parents=True)
    golden = json.loads((ROOT / "fixtures/bm25-golden.json").read_text(encoding="utf-8"))

    ok = True
    totals = {"corpora": 0, "chunks": 0, "byte_identical_files": 0, "files": 0, "decoded_equal": 0,
              "queries": 0, "identical_rankings": 0, "ranked_results": 0}
    ascii_inputs: list[tuple[str, Path]] = []
    for name, root, judgments_path, prefix, golden_key in CORPORA:
        folder = scratch / name / "index"
        imported = scratch / name / "import-v2"
        run([args.searchd, "index", str(ROOT / root), "--out", str(folder)])
        documents = read_documents((folder / "documents-1.hybseg").read_bytes())
        source = scratch / name / "interchange-v2.json"
        source.write_text(interchange(documents, "analyzer-v2"), encoding="utf-8")
        run([args.searchd, "import-json", str(imported), str(source)])
        ascii_source = scratch / name / "interchange-ascii.json"
        ascii_source.write_text(interchange(documents, "ascii-alnum-v1"), encoding="utf-8")
        ascii_inputs.append((name, ascii_source))

        differing = files_identical(folder, imported)
        a = read_lexical((folder / "lexical-1.hyblex").read_bytes())
        b = read_lexical((imported / "lexical-1.hyblex").read_bytes())
        decoded_equal = a["terms"] == b["terms"] and a["lengths"] == b["lengths"] and a["average"] == b["average"]

        queries = []
        if judgments_path:
            queries += [q["query"] for q in json.loads((ROOT / judgments_path).read_text(encoding="utf-8"))["queries"]]
        if golden_key:
            queries += [q["query"] for q in golden[golden_key]]
        queries += generated_queries(documents) + PROBES
        queries = list(dict.fromkeys(queries))
        identical = results = 0
        for query in queries:
            left = ranked(args.searchd, folder, query)
            right = ranked(args.searchd, imported, query)
            results += len(left)
            if same_ranking(left, right):
                identical += 1
            else:
                print(f"  DIFF {name}: {query!r}")
        manifest = run([args.searchd, "query", str(imported), "x", "--json"]).stdout
        analyzer = json.loads(manifest)["analyzer_id"]
        print(f"{name}: chunks={len(documents)} terms={len(a['terms'])} imported analyzer={analyzer} "
              f"files byte-identical {len(SECTION_FILES) - len(differing)}/{len(SECTION_FILES)}"
              f"{' (differ: ' + ', '.join(differing) + ')' if differing else ''} "
              f"lexical decoded equal={decoded_equal} queries identical {identical}/{len(queries)} (results compared {results})")
        ok &= not differing and decoded_equal and identical == len(queries) and analyzer == "analyzer-v2"
        totals["corpora"] += 1
        totals["chunks"] += len(documents)
        totals["files"] += len(SECTION_FILES)
        totals["byte_identical_files"] += len(SECTION_FILES) - len(differing)
        totals["decoded_equal"] += int(decoded_equal)
        totals["queries"] += len(queries)
        totals["identical_rankings"] += identical
        totals["ranked_results"] += results

        if judgments_path:
            judgments = json.loads((ROOT / judgments_path).read_text(encoding="utf-8"))
            ascii_snapshot = scratch / name / "import-ascii"
            run([args.searchd, "import-json", str(ascii_snapshot), str(ascii_source)])
            for label, snapshot in (("index v2", folder), ("import-json analyzer-v2", imported), ("import-json ascii-alnum-v1", ascii_snapshot)):
                metrics = judge(args.searchd, snapshot, judgments, prefix)
                print(f"  judged {label}: " + " ".join(f"{k}={v:.3f}" if isinstance(v, float) else f"{k}={v}" for k, v in metrics.items()))
                if name == "tamil" and label == "import-json analyzer-v2":
                    ok &= metrics["success@1"] == 1.0
    print("bar (b) totals: " + " ".join(f"{k}={v}" for k, v in totals.items()))

    if args.baseline:
        extra = scratch / "abi-demo.json"
        abi_test = (ROOT / "zig/tests/abi_test.c").read_text(encoding="utf-8")
        body = abi_test.split("demo_interchange_json =", 1)[1].split(";", 1)[0]
        extra.write_text("".join(re.findall(r'"((?:[^"\\]|\\.)*)"', body)).encode().decode("unicode_escape"), encoding="utf-8")
        ascii_inputs.append(("abi-demo", extra))
        python_index = scratch / "python-index.json"
        run([sys.executable, "search.py", "index", "fixtures/semantic-knowledge", "--vector-mode", "cooccurrence", "--out", str(python_index)], cwd=ROOT)
        export = scratch / "export-zig.json"
        run([sys.executable, "export_zig.py", str(python_index), "--out", str(export)], cwd=ROOT)
        ascii_inputs.append(("export_zig semantic-knowledge", export))
        same = 0
        for name, source in ascii_inputs:
            old = scratch / "bar-c" / name / "baseline"
            new = scratch / "bar-c" / name / "new"
            run([args.baseline, "import-json", str(old), str(source)])
            run([args.searchd, "import-json", str(new), str(source)])
            differing = files_identical(old, new)
            names = sorted(p.name for p in old.iterdir()) == sorted(p.name for p in new.iterdir())
            same += int(not differing and names)
            print(f"bar (c) {name}: analyzer={json.loads(source.read_text(encoding='utf-8'))['analyzer_id']} "
                  f"published files byte-identical to baseline: {'yes' if not differing and names else 'NO ' + str(differing)}")
        print(f"bar (c) totals: {same}/{len(ascii_inputs)} imports byte-identical ({len(SECTION_FILES)} files each)")
        ok &= same == len(ascii_inputs)

    print("RESULT", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
