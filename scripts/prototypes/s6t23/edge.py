#!/usr/bin/env python3
"""S6-T23 Part 1: the edge cases of section 2 of the note, as an invented folder, and what main's `searchd` does.

    python3 -I edge.py SEARCHD OUT_DIR > edge.txt

OUT_DIR must not exist. It writes OUT_DIR/edge (the folder below, every byte invented), runs `textsniff.py`'s
survey on it, writes the renamed copy OUT_DIR/edge-text, and runs main's `searchd` on both, printing:

- the survey (every path, today's rule, the sniff's verdict, its size);
- `searchd index` on the real folder (today's rule) and on the renamed copy (the rule, as the prototype gives it);
- the passage a row query gets from a 600-row CSV (does it carry the header line?), from a 200 KB minified one-line
  file (how many bytes come back), and from a text file with a NUL after its first 8 KiB;
- a probe of a name with a carriage return (macOS writes `Icon\\r` into folders with a custom icon): today a known
  extension with such a name makes `index` and `search` fail, so a sniff that reads names with no extension would
  meet `Icon\\r` in ordinary folders.
"""
from __future__ import annotations

import io
import json
import random
import sqlite3
import subprocess
import sys
import zipfile
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import textsniff  # noqa: E402

WORDS = ("apple bramble copper dappled ember fennel garnet hazel indigo juniper kestrel lantern meadow nettle "
         "orchard pebble quill russet sorrel thistle umber velvet willow yarrow").split()


def sentence(rng: random.Random, n: int = 9) -> str:
    return " ".join(rng.choice(WORDS) for _ in range(n)).capitalize() + "."


def build(root: Path) -> None:
    rng = random.Random(2311)
    files: dict[str, bytes] = {}
    text = lambda s: s.encode("utf-8")  # noqa: E731
    files["notes/empty.note"] = b""
    files["notes/plain.text"] = text("Plain text kept as .text: the kestrel nests by the mill.\n")
    files["notes/old-note.markdown"] = text("# Old note\n\nThe word markdownkind is only here.\n")
    files["notes/settings.ini"] = text("[garden]\nshed = blue\nwatering = 06:30\n")
    files["notes/agenda.org"] = text("* Agenda\n** TODO buy fennel seed\n")
    files["notes/film.srt"] = text("1\n00:00:01,000 --> 00:00:03,000\nThe lantern is lit.\n")
    files["notes/calendar.ics"] = text("BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:Orchard walk\nDTSTART:20261205T100000\n"
                                       "END:VEVENT\nEND:VCALENDAR\n")
    files["notes/card.vcf"] = text("BEGIN:VCARD\nFN:Wren Halloway\nTEL:01632 960123\nEND:VCARD\n")
    files["notes/letter.eml"] = text("From: wren@example.invalid\nSubject: Quill order\n\nThe quill order is in.\n")
    files["notes/README"] = text("Read me: the russet folder holds the orchard plans.\n")
    files["notes/Makefile"] = text("all:\n\techo thistle\n")
    files["notes/ansi.log"] = text("2026-11-01 \x1b[32mINFO\x1b[0m backup done\n" * 40)
    files["notes/bom.txt"] = b"\xef\xbb\xbf" + text("A note that starts with a byte order mark: sorrel.\n")
    header = "row,item,shelf,colour,lent_to,due\n"
    rows = [f"{i},{rng.choice(WORDS)}-{i},S{i % 40},{rng.choice(WORDS)},{rng.choice(WORDS)},2026-12-{1 + i % 28:02d}\n"
            for i in range(1, 601)]
    rows[299] = "300,tilecutter300,S20,umber,Wren,2026-12-09\n"
    files["data/big-table.csv"] = text(header + "".join(rows))
    files["data/utf16-export.tsv"] = "﻿name\tphone\nWren\t01632 960124\n".encode("utf-16-le")
    files["data/latin1-note.txt"] = "Café note in Latin-1: the umber teapot.\n".encode("latin-1")
    body = "".join(sentence(rng) + "\n" for _ in range(400)).encode("utf-8")
    files["data/one-bad-byte.txt"] = body[:15000] + b"\xff" + body[15000:20000]
    late = "".join(sentence(rng) + "\n" for _ in range(200)).encode("utf-8")[:10000]
    files["data/nul-late.txt"] = late[:9000] + b"\x00" + b" nullateword\n" + late[9000:]
    files["data/nul-early.dat"] = b"header\x00" + text(sentence(rng) + "\n") * 20
    files["data/controls"] = (text("ab") + b"\x01" + text("cdefghijklmnopqrstuvwxyz0123456789") + b"\x02") * 80
    files["web/app.min.js"] = text("var a=" + ";".join(f"f{i}=function(x){{return x*{i}}}" for i in range(9000))
                                   + ";var minifiedword=1;\n")
    lock = {"name": "site", "lockfileVersion": 3, "packages": {
        f"node_modules/pkg-{i}": {"version": f"1.{i}.0", "resolved": f"https://registry.example.invalid/pkg-{i}.tgz",
                                  "integrity": "sha512-" + "A" * 40} for i in range(1500)}}
    files["web/package-lock.json"] = text(json.dumps(lock, indent=2) + "\n")
    files["web/logo.svg"] = text('<svg xmlns="http://www.w3.org/2000/svg"><title>Logo</title>'
                                 '<path d="M10 10 L20 20"/></svg>\n')
    jpeg = (b"\xff\xd8\xff\xe1\x00\x2aExif\x00\x00" + text("ImageDescription: invented photo of a meadow")
            + bytes(rng.randrange(256) for _ in range(4000)) + b"\xff\xd9")
    files["media/photo.jpg"] = jpeg
    files["media/photo-copy"] = jpeg
    pdf = (text("%PDF-1.7\n") + b"%\xe2\xe3\xcf\xd3\n" + text("1 0 obj << /Title (Invented scan) >> endobj\nstream\n")
           + zlib.compress(text(sentence(rng) * 300)) + text("\nendstream\n%%EOF\n"))
    files["media/scan.pdf"] = pdf
    files["media/scan-copy"] = pdf
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("inside.txt", sentence(rng) * 50)
    files["media/archive.zip"] = buffer.getvalue()
    files["media/archive-copy"] = buffer.getvalue()
    files["bin/tool"] = b"\xcf\xfa\xed\xfe\x0c\x00\x00\x01" + bytes(4088)
    files["logs/huge.log"] = text("".join(f"2026-11-{1 + i % 28:02d} 07:00:{i % 60:02d} INFO request GET /item/{i} 200\n"
                                          for i in range(260000)))
    files[".hidden-note.txt"] = text("A dot-file: hiddenword.\n")
    files[".config/settings.txt"] = text("Inside a dot-folder: hiddenword.\n")
    files["node_modules/pkg/index.js"] = text("module.exports = 'ignoredword';\n")
    files["Icon\r"] = b""
    for rel, data in files.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    db = sqlite3.connect(root / "media" / "data.sqlite")
    db.execute("create table t (word text)")
    db.execute("insert into t values ('sqliteword')")
    db.commit()
    db.close()
    (root / "media" / "data-copy").write_bytes((root / "media" / "data.sqlite").read_bytes())


def run(searchd: str, *args: str) -> tuple[int, str, str]:
    done = subprocess.run([searchd, *args], capture_output=True)
    return done.returncode, done.stdout.decode("utf-8", "replace"), done.stderr.decode("utf-8", "replace")


def passages(out: str) -> list[dict]:
    env = json.loads(out)
    return [{"path": r["path"], "start_line": r["start_line"], "end_line": r["end_line"],
             "content_bytes": len(r["content"].encode("utf-8")), "first_line": r["content"].split("\n", 1)[0][:60],
             "has_nul": "\x00" in r["content"]} for r in env["evidence"]]


def main(argv: list[str]) -> int:
    searchd, out = argv[0], Path(argv[1])
    out.mkdir(parents=True)
    edge, copy = out / "edge", out / "edge-text"
    build(edge)
    survey = textsniff.survey(edge, with_paths=True)
    print("## survey (textsniff.py), every file today's walk keeps\n")
    for row in survey["paths"]:
        print(f"{row['path']!r:40} today={'read' if row['today'] else 'not read':9} sniff={row['sniff']:14} "
              f"bytes={row['bytes']}")
    print(f"\ntotals: {survey['totals']}\n")
    report = textsniff.rename_copy(edge, copy, out / "edge-map.json")
    print(f"renamed copy: {report['renamed']} renamed, order kept {report['order_kept']}, "
          f"refused {report['refused']}, clashes {report['substring_clashes']}\n")
    print("## searchd index, today's rule (the real folder) and the rule (the renamed copy)\n")
    for label, folder in (("today", edge), ("rule", copy)):
        code, stdout, stderr = run(searchd, "index", str(folder), "--out", str(out / f"idx-{label}"))
        print(f"{label}: exit {code}: {stdout.strip().split(': ', 1)[-1]} {stderr.strip()}")
        code, stdout, _ = run(searchd, "index", str(folder), "--out", str(out / f"idx-{label}"), "--update")
        upd = json.loads(stdout)
        print(f"{label} --update: unreadable_paths {upd['unreadable_paths']} too_large_paths {upd['too_large_paths']}")
    print("\n## passages from the rule's index (renamed paths)\n")
    idx = str(out / "idx-rule")
    for query in ("tilecutter300", "minifiedword", "nullateword", "markdownkind", "hiddenword", "ignoredword"):
        code, stdout, _ = run(searchd, "evidence", idx, query, "--top-k", "3")
        print(f"{query}: {passages(stdout)}")
    print("\n## a carriage return in a name\n")
    probe = out / "probe-cr"
    probe.mkdir()
    (probe / "a\r.md").write_text("crword\n", encoding="utf-8")
    (probe / "b.md").write_text("other\n", encoding="utf-8")
    for args in (("index", str(probe), "--out", str(out / "idx-cr")),
                 ("search", str(probe), "crword", "--search-field", "content")):
        code, stdout, stderr = run(searchd, *args)
        print(f"{args[0]} with 'a\\r.md' present: exit {code}, stderr {stderr.strip()!r}")
    only_icon = out / "probe-icon"
    only_icon.mkdir()
    (only_icon / "Icon\r").write_bytes(b"")
    (only_icon / "b.md").write_text("other\n", encoding="utf-8")
    code, stdout, stderr = run(searchd, "search", str(only_icon), "other", "--search-field", "content")
    print(f"search with 'Icon\\r' (no extension, not a candidate today) present: exit {code}, "
          f"stderr {stderr.strip()!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
