#!/usr/bin/env python3
"""S6-T8 ruling 2: an older library against a v2.5 index (manifest bit 7,
content lexical section `HYBLEX04`).

    python3 -I old_library.py LIB SEARCHD INDEX FOLDER WORK

Each call runs on its own copy of INDEX (under WORK, which must not exist);
the copy's files are hashed (SHA-256) before and after. Through the C ABI
(ctypes on LIB): `ss_open`, `ss_index_folder` (full and update) and
`ss_apply_changes` (with and without file reads). Through SEARCHD: `query`,
`evidence`, `find`, `outline`, `read-span`, `list-files`, `roots`,
`index --update`, `apply`, `serve` (`index_status`), `mcp` (`tools/call`
`index_status`). Prints one line per call and exits 1 unless every call is
refused with `UnsupportedFlags` and every index file is byte-identical
afterwards (a writer call may create the empty `WRITER.LOCK` when the copy
has none: it takes the lock before it reads the manifest). Not part of any
library.
"""
import ctypes
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

SHED = json.dumps({"changes": [{"op": "add", "root_id": "r-legacy", "path": "shed.txt",
                                "content_base64": "VGhlIHNoZWQgbmVlZHMgYSBuZXcgbG9jay4K"}]})


def digests(d: Path) -> dict:
    return {f.name: hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(d.iterdir()) if f.is_file()}


def compare(before: dict, after: dict) -> tuple[bool, str]:
    changed = [(k, v) for k, v in after.items() if before.get(k) != v]
    lock_only = all(k == "WRITER.LOCK" and v == hashlib.sha256(b"").hexdigest() for k, v in changed)
    same = not changed and before.keys() == after.keys()
    note = f"files {len(before)} -> {len(after)}, byte-identical: {same}"
    if changed:
        note += f"\n  changed: {changed}" + (" (the empty writer lock only)" if lock_only else "")
    return same or (lock_only and before.keys() <= after.keys()), note


def main(argv) -> int:
    lib_path, searchd, index, folder, work = argv[1], argv[2], Path(argv[3]), argv[4], Path(argv[5])
    work.mkdir()
    ok = True
    n = 0

    def copy() -> Path:
        nonlocal n
        n += 1
        target = work / f"c{n}"
        shutil.copytree(index, target)
        return target

    lib = ctypes.CDLL(lib_path)
    lib.ss_version.restype = ctypes.c_char_p
    lib.ss_last_error.restype = ctypes.c_char_p
    lib.ss_open.argtypes = [ctypes.c_char_p]
    lib.ss_open.restype = ctypes.c_void_p
    for name in ("ss_index_folder", "ss_apply_changes"):
        fn = getattr(lib, name)
        fn.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]
        fn.restype = ctypes.c_void_p
    print(f"library {Path(lib_path).name} ss_version {lib.ss_version().decode()}, "
          f"sha256 {hashlib.sha256(Path(lib_path).read_bytes()).hexdigest()}")
    calls = [
        ("ss_open", lambda d: lib.ss_open(str(d).encode())),
        ("ss_index_folder (full)", lambda d: lib.ss_index_folder(str(d).encode(), folder.encode(), b'{"filename_index":true}')),
        ("ss_index_folder (update)", lambda d: lib.ss_index_folder(str(d).encode(), folder.encode(), b'{"update":true,"filename_index":true}')),
        ("ss_apply_changes", lambda d: lib.ss_apply_changes(str(d).encode(), SHED.encode(), None)),
        ("ss_apply_changes (allow_file_reads)", lambda d: lib.ss_apply_changes(str(d).encode(), SHED.encode(), b'{"allow_file_reads":true}')),
    ]
    for label, call in calls:
        d = copy()
        before = digests(d)
        result = call(d)
        error = lib.ss_last_error().decode("utf-8", "replace")
        good, note = compare(before, digests(d))
        refused = not result and "UnsupportedFlags" in error
        ok &= good and refused
        print(f"{label}: {'NULL' if not result else 'NOT NULL'}; ss_last_error: {error!r}; {note}")

    print(f"\nsearchd {searchd.rsplit('/', 1)[-1]}, sha256 {hashlib.sha256(Path(searchd).read_bytes()).hexdigest()}")
    commands = [
        (["query", "{d}", "garden"], None),
        (["evidence", "{d}", "garden"], None),
        (["find", "{d}", "garden", "--json"], None),
        (["find", "{d}", "garden pond", "--mode", "phrase", "--json"], None),
        (["find", "{d}", "gard", "--mode", "prefix", "--json"], None),
        (["outline", "{d}", "r-legacy", "garden.md", "--json"], None),
        (["read-span", "{d}", "r-legacy", "garden.md", "1", "4", "--json"], None),
        (["list-files", "{d}", "--json"], None),
        (["roots", "{d}", "--json"], None),
        (["index", folder, "--out", "{d}", "--update", "--filename-index"], None),
        (["apply", "{d}", "--changes", "{changes}", "--filename-index"], None),
        (["serve", "{d}"], json.dumps({"jsonrpc": "2.0", "id": 1, "method": "index_status", "params": {}}) + "\n"),
        (["mcp", "{d}"], "\n".join(json.dumps(m) for m in (
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "check", "version": "0"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "index_status", "arguments": {}}})) + "\n"),
    ]
    changes = work / "shed.json"
    changes.write_text(SHED)
    for argv_template, stdin in commands:
        d = copy()
        before = digests(d)
        argv_run = [a.replace("{d}", str(d)).replace("{changes}", str(changes)) for a in argv_template]
        done = subprocess.run([searchd, *argv_run], input=stdin, capture_output=True, text=True, timeout=120)
        good, note = compare(before, digests(d))
        text = (done.stdout + done.stderr).strip().replace(str(d), "idx").replace(str(changes), "shed.json")
        refused = "UnsupportedFlags" in text and (done.returncode != 0 or stdin is not None)
        ok &= good and refused
        shown = " ".join(a.replace(str(d), "idx").replace(str(changes), "shed.json") for a in argv_run)
        print(f"$ searchd {shown}\n{text[:600]}\nexit {done.returncode}; {note}")
    print(f"\nrefused with UnsupportedFlags and the index unchanged on every call: {ok}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
