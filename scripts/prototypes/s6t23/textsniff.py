#!/usr/bin/env python3
"""S6-T23 Part 1 prototype: the proposed readable-set rule `text-sniff-v1`, in Python, outside the engine.

    python3 -I textsniff.py survey FOLDER [--paths]     # what today's rule and the sniff do with every file
    python3 -I textsniff.py rename SRC DST MAP.json     # the renamed copy the scorer is run on

The rule (docs/decisions/0005-which-files-are-text.md, section 2), applied to every regular file the walk keeps
(today's walk: no path component starting with `.`, none of the six ignored directories):

1. A name that cannot be a record path (a carriage return or line feed in it, or not UTF-8) is not read: `bad_name`.
2. A known non-text extension (DENY below) is not opened: its kind (`image`, `audio`, ...).
3. Otherwise the first HEAD_BYTES bytes (the whole file when it is smaller) decide:
   - empty file: `text`;
   - a UTF-16 or UTF-32 byte order mark: `utf16` (text in another encoding; not read);
   - a NUL byte: `binary`;
   - more than CONTROL_SHARE of the head in control bytes (CONTROL below): `binary`;
   - the head, after an optional UTF-8 byte order mark, not valid UTF-8 (a sequence cut by the head's end is
     allowed when the file is longer than the head): `not_utf8`;
   - else `text`.
4. A `text` file is then read whole by today's code: over `max_file_bytes` it is `too_large`, and invalid UTF-8
   anywhere is today's `unreadable`. This script reports the head verdict and, for `text`, whether the whole file
   is valid UTF-8 (`text_bad_tail` when it is not).

`rename` writes a copy of SRC in which every file the sniff calls `text` and today's 19 extensions do not read gets a
name today's engine reads: its last extension replaced by one of TODAY's non-Markdown extensions (`.txt` first), or
one appended when it has none (`.markdown` becomes `.md`), so the stem (the file-name channel's and the title field's
text) and the chunker (`line-window-v1`, `md-section-v1` for `.markdown`) stay what the rule would give. A name is taken only when it collides with no path and keeps the
bytewise order of all paths (the walk's order, so document indexes and path tie-breaks are unchanged). MAP.json maps
each new relative path back to the real one.
"""
from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

HEAD_BYTES = 8192
CONTROL_SHARE = 0.01
# Bytes that do not occur in text: C0 controls except TAB, LF, VT, FF, CR and ESC (ANSI colour in logs), and DEL.
CONTROL = frozenset(set(range(0x01, 0x09)) | set(range(0x0E, 0x1B)) | set(range(0x1C, 0x20)) | {0x7F})

# Today's rule: zig/src/core/indexer.zig `default_extensions` = src/search_platform/core.py `DEFAULT_EXTENSIONS`.
TODAY = (".c", ".cpp", ".css", ".go", ".h", ".html", ".java", ".js", ".json",
         ".md", ".py", ".rs", ".rst", ".toml", ".ts", ".txt", ".yaml", ".yml", ".zig")
IGNORED_DIRECTORIES = {".git", ".search", ".zig-cache", "__pycache__", "node_modules", "zig-out"}

DENY_KINDS = {
    "image": "png jpg jpeg gif bmp tif tiff webp heic heif ico icns psd svg avif raw cr2 nef dng",
    "audio": "mp3 m4a aac wav flac ogg opus aif aiff mid midi",
    "video": "mp4 m4v mov avi mkv webm wmv mpg mpeg",
    "archive": "zip gz tgz bz2 xz zst 7z rar tar dmg iso pkg jar",
    "document": "pdf doc docx xls xlsx ppt pptx odt ods odp pages numbers key rtf epub",
    "font": "ttf otf woff woff2",
    "program": "exe dll so dylib o a class pyc wasm bin",
    "database": "sqlite sqlite3 db",
}
DENY = {"." + ext: kind for kind, exts in DENY_KINDS.items() for ext in exts.split()}


def extension(name: str) -> str:
    """The last extension, lowercased, as the engine reads it (`hasAllowedExtension`); '' for none or a dot-file."""
    dot = name.rfind(".")
    return name[dot:].lower() if dot > 0 else ""


def read_today(name: str) -> bool:
    return extension(name) in TODAY


def valid_utf8_prefix(data: bytes, cut: bool) -> bool:
    """Valid UTF-8; when `cut`, a multi-byte sequence the head's end cut (at most 3 bytes) is allowed."""
    try:
        data.decode("utf-8")
        return True
    except UnicodeDecodeError as err:
        return cut and err.start >= len(data) - 3 and err.reason == "unexpected end of data"


def sniff_bytes(head: bytes, size: int) -> str:
    if size == 0:
        return "text"
    if head[:4] in (b"\xff\xfe\x00\x00", b"\x00\x00\xfe\xff") or head[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return "utf16"
    if b"\x00" in head:
        return "binary"
    if sum(1 for b in head if b in CONTROL) > CONTROL_SHARE * len(head):
        return "binary"
    body = head[3:] if head.startswith(b"\xef\xbb\xbf") else head
    if not valid_utf8_prefix(body, cut=size > len(head)):
        return "not_utf8"
    return "text"


def bad_name(rel: str) -> bool:
    return "\r" in rel or "\n" in rel


def classify(path: Path, rel: str) -> str:
    """The head verdict of the rule for one file (steps 1 to 3), and `text_bad_tail` for step 4's UTF-8 failure."""
    if bad_name(rel):
        return "bad_name"
    kind = DENY.get(extension(path.name))
    if kind:
        return kind
    size = path.stat().st_size
    with path.open("rb") as handle:
        head = handle.read(HEAD_BYTES)
    verdict = sniff_bytes(head, size)
    if verdict == "text" and size > len(head):
        data = path.read_bytes()
        body = data[3:] if data.startswith(b"\xef\xbb\xbf") else data
        if not valid_utf8_prefix(body, cut=False):
            return "text_bad_tail"
    return verdict


def walk(root: Path):
    """Every regular file today's walk keeps (indexer.collectCandidatePaths before its extension test), sorted."""
    out = []
    for path in root.rglob("*"):
        rel = path.relative_to(root).as_posix()
        parts = rel.split("/")
        if any(p.startswith(".") or p in IGNORED_DIRECTORIES for p in parts):
            continue
        if path.is_file() and not path.is_symlink():
            out.append((rel, path))
    return sorted(out, key=lambda item: item[0].encode("utf-8"))


def survey(root: Path, with_paths: bool) -> dict:
    rows = {}
    files = []
    for rel, path in walk(root):
        verdict = classify(path, rel)
        today = read_today(path.name)
        ext = extension(path.name) or "(none)"
        key = (ext, "read" if today else "not read", verdict)
        rows[key] = rows.get(key, 0) + 1
        if with_paths:
            files.append({"path": rel, "today": today, "sniff": verdict, "bytes": path.stat().st_size})
    table = [{"extension": e, "today": t, "sniff": v, "files": n} for (e, t, v), n in sorted(rows.items())]
    totals = {}
    for (e, t, v), n in rows.items():
        totals[f"{t} / {v}"] = totals.get(f"{t} / {v}", 0) + n
    out = {"files": sum(rows.values()), "totals": dict(sorted(totals.items())), "by_extension": table}
    if with_paths:
        out["paths"] = files
    return out


def choose_name(rel: str, taken: set[str], order: list[str]) -> str | None:
    """A new relative path for `rel` that today's engine reads, keeping the stem, colliding with nothing and keeping
    `rel`'s place in the bytewise order of `order` (all paths); None when no candidate does."""
    folder, _, name = rel.rpartition("/")
    dot = name.rfind(".")
    stem = name[:dot] if dot > 0 else name
    index = order.index(rel)
    before = order[index - 1].encode() if index > 0 else None
    after = order[index + 1].encode() if index + 1 < len(order) else None
    # `.markdown` is chunked as Markdown (chunker.kindForPath), so it keeps that chunker as `.md`; every other kind
    # keeps `line-window-v1` under any of today's other extensions.
    choices = (".md",) if extension(name) == ".markdown" else (".txt",) + tuple(e for e in TODAY if e not in (".txt", ".md"))
    for ext in choices:
        candidate = (folder + "/" if folder else "") + stem + ext
        raw = candidate.encode()
        if candidate in taken:
            continue
        if (before is None or before < raw) and (after is None or raw < after):
            return candidate
    return None


def rename_copy(src: Path, dst: Path, map_path: Path) -> dict:
    if dst.exists():
        raise SystemExit(f"{dst} exists")
    files = walk(src)
    order = [rel for rel, _ in files]
    taken = set(order)
    mapping, refused = {}, []
    for rel, path in files:
        if read_today(path.name) or classify(path, rel) != "text":
            continue
        new = choose_name(rel, taken, order)
        if new is None:
            refused.append(rel)
            continue
        taken.add(new)
        mapping[new] = rel
    back = {v: k for k, v in mapping.items()}
    for rel, path in files:
        target = dst / back.get(rel, rel)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
    # Checks the scorer's path mapping relies on: the renamed order equals the real order, and no new path occurs
    # inside another path or inside any file's text (so a plain replacement of the new path in searchd's output is
    # exact).
    renamed = sorted((back.get(rel, rel) for rel in order), key=str.encode)
    same_order = [mapping.get(r, r) for r in renamed] == order
    texts = [p.read_bytes() for _, p in files]
    clashes = [new for new in mapping
               if any(new in other and new != other for other in list(taken))
               or any(new.encode() in t for t in texts)]
    report = {"renamed": len(mapping), "refused": refused, "order_kept": same_order, "substring_clashes": clashes,
              "map": dict(sorted(mapping.items()))}
    map_path.write_text(json.dumps(report, indent=1) + "\n", encoding="utf-8")
    return report


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[0] == "survey":
        print(json.dumps(survey(Path(argv[1]), "--paths" in argv[2:]), indent=1, ensure_ascii=False))
        return 0
    if len(argv) == 4 and argv[0] == "rename":
        report = rename_copy(Path(argv[1]), Path(argv[2]), Path(argv[3]))
        print(json.dumps({k: v for k, v in report.items() if k != "map"}))
        return 0 if report["order_kept"] and not report["refused"] and not report["substring_clashes"] else 1
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
