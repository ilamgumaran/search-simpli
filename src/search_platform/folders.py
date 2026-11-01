"""Several roots, host-fed changes and visible-scope statistics: the Python
reference for S3-T3 (`docs/folder-knowledge-implementation.md` sections 5-7,
`zig/src/apply.zig`, `zig/src/scope.zig`).

`FolderIndex` holds roots and files in memory and applies `apply_changes`
requests with the same rules as the engine: whole-request refusals raise
`ApplyError` and change nothing; per-change outcomes (`rejected`,
`too_large`, `unreadable`) are reported; changes apply in array order per
`(root_id, path)` with `conflicts` reported; equal-content removes and adds
in one batch become moves, paired by sorted path, with `ambiguous_moves`;
`pending` replaces a file's chunks with none; `remove_root` drops the root.

Search, status and listings take a scope (roots named, default all, and the
trusted caller's `principal_labels`); a root's `required_labels` add to each
file's. BM25 statistics are computed over the visible scope, so a hidden
file is indistinguishable from an absent one in every payload.

Standard library only (INV-06).
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import os
import re
import stat
from collections import Counter
from pathlib import Path
from typing import Iterable

from .core import (
    ReadError,
    _bm25_scores,
    _chunk_id,
    chunker_for_path,
    file_chunks,
    outline_bytes,
    read_span_bytes,
    tokenize,
)

LEGACY_ROOT_ID = "r-legacy"
MAX_CHANGES = 10_000
DEFAULT_MAX_FILE_BYTES = 10 * 1024 * 1024
DEFAULT_MAX_TOTAL_BYTES = 512 * 1024 * 1024
MAX_PATH_BYTES = 4096
MAX_LABELS = 64
MAX_LABEL_BYTES = 256
OPS = ("add", "change", "remove", "move", "pending", "remove_root")
KINDS = ("local", "icloud", "host")
_ROOT_ID = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
_REQUEST_FIELDS = {"expect_generation", "roots", "changes"}
_ROOT_FIELDS = {"root_id", "label", "kind", "required_labels", "retain_source", "path"}
_OP_FIELDS = {
    "add": {"op", "root_id", "path", "size", "mtime_ms", "sha256", "content_base64", "file", "required_labels"},
    "remove": {"op", "root_id", "path"},
    "move": {"op", "root_id", "path", "moved_from", "size", "mtime_ms"},
    "pending": {"op", "root_id", "path", "size", "mtime_ms", "required_labels"},
    "remove_root": {"op", "root_id"},
}
_OP_FIELDS["change"] = _OP_FIELDS["add"]


class ApplyError(ValueError):
    """A whole request refused: `code` is invalid_argument or capacity."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def _invalid(message: str) -> ApplyError:
    return ApplyError("invalid_argument", message)


def valid_root_id(root_id: object) -> bool:
    return isinstance(root_id, str) and bool(_ROOT_ID.match(root_id)) and root_id not in (".", "..")


def valid_relative_path(path: object) -> bool:
    if not isinstance(path, str) or not path or len(path.encode("utf-8", "surrogatepass")) > MAX_PATH_BYTES:
        return False
    if any(c in path for c in ("\0", "\r", "\n")):
        return False
    try:
        path.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return all(part not in ("", ".", "..") for part in path.split("/"))


def _valid_absolute(path: object) -> bool:
    if not isinstance(path, str) or len(path) < 2 or not path.startswith("/") or len(path) > MAX_PATH_BYTES:
        return False
    if any(c in path for c in ("\0", "\r", "\n")):
        return False
    return all(part not in (".", "..") for part in path[1:].split("/"))


def _labels(value: object) -> list[str] | None:
    if not isinstance(value, list) or len(value) > MAX_LABELS:
        return None
    for item in value:
        if not isinstance(item, str) or not item or len(item.encode("utf-8")) > MAX_LABEL_BYTES:
            return None
        if any(c in item for c in ("\0", "\r", "\n")):
            return None
    if len(set(value)) != len(value):
        return None
    return list(value)


def strict_base64(text: str) -> bytes | None:
    """RFC 4648 standard alphabet, padded, canonical (round-trips exactly)."""
    if not isinstance(text, str) or len(text) % 4:
        return None
    try:
        data = base64.b64decode(text, validate=True)
    except (binascii.Error, ValueError):
        return None
    return data if base64.b64encode(data).decode("ascii") == text else None


def record_path(root_id: str, path: str) -> str:
    """The legacy folder root keeps bare relative paths (`scope.zig`)."""
    return path if root_id == LEGACY_ROOT_ID else f"{root_id}/{path}"


def default_retain(kind: str) -> bool:
    return kind != "local"


def _check_fields(obj: dict, allowed: set[str], where: str) -> None:
    for name in obj:
        if name == "principal_labels":
            raise _invalid(f"principal_labels are not accepted in {where}: the scope comes from the trusted caller")
        if name not in allowed:
            raise _invalid(f"unknown field in {where}: {name}")


def _confine(root_path: str, file: str) -> str | int:
    """'outside', 'symlink', 'missing', or the file size (no link followed below the root)."""
    base = root_path.rstrip("/")
    if not file.startswith(base + "/") or len(file) <= len(base) + 1:
        return "outside"
    rest = file[len(base) + 1:]
    if not valid_relative_path(rest):
        return "outside"
    current = base
    parts = rest.split("/")
    for index, part in enumerate(parts):
        current = f"{current}/{part}"
        try:
            info = os.lstat(current)
        except OSError:
            return "missing"
        if stat.S_ISLNK(info.st_mode):
            return "symlink"
        if index == len(parts) - 1:
            return info.st_size if stat.S_ISREG(info.st_mode) else "missing"
        if not stat.S_ISDIR(info.st_mode):
            return "missing"
    return "missing"


def parse_request(request: dict | str, *, allow_file_reads: bool = False,
                  max_file_bytes: int = DEFAULT_MAX_FILE_BYTES,
                  max_total_bytes: int = DEFAULT_MAX_TOTAL_BYTES) -> tuple[int | None, dict | None, ApplyError | None]:
    """(expect_generation, parsed body, deferred refusal) -- the refusal is
    raised only after the caller checked `expect_generation`."""
    if isinstance(request, str):
        try:
            request = json.loads(request)
        except json.JSONDecodeError as exc:
            raise _invalid(f"request is not valid JSON: {exc}") from None
    if not isinstance(request, dict):
        raise _invalid("request must be a JSON object")
    expect = request.get("expect_generation")
    if expect is not None and (isinstance(expect, bool) or not isinstance(expect, int) or expect < 0):
        raise _invalid("expect_generation must be a non-negative integer")
    try:
        return expect, _parse_body(request, allow_file_reads, max_file_bytes, max_total_bytes), None
    except ApplyError as exc:
        return expect, None, exc


def _parse_body(request: dict, allow_file_reads: bool, max_file_bytes: int, max_total_bytes: int) -> dict:
    _check_fields(request, _REQUEST_FIELDS, "the request")
    changes = request.get("changes")
    if not isinstance(changes, list):
        raise _invalid("changes is required and must be an array")
    if len(changes) > MAX_CHANGES:
        raise ApplyError("capacity", f"{len(changes)} changes is over the {MAX_CHANGES}-change batch cap")
    roots = []
    for index, item in enumerate(request.get("roots", []) or []):
        if not isinstance(item, dict):
            raise _invalid(f"roots[{index}] must be an object")
        _check_fields(item, _ROOT_FIELDS, "a root")
        root_id = item.get("root_id")
        if not valid_root_id(root_id):
            raise _invalid(f"invalid root_id: {root_id!r}")
        if root_id == LEGACY_ROOT_ID:
            raise _invalid(f"root_id {root_id} is reserved for index_folder")
        decl = {"root_id": root_id}
        if "label" in item:
            label = item["label"]
            if not isinstance(label, str) or not label or any(c in label for c in "\0\r\n"):
                raise _invalid(f"invalid label for root {root_id}")
            decl["label"] = label
        if "kind" in item:
            if item["kind"] not in KINDS:
                raise _invalid(f"kind of root {root_id} must be local, icloud or host")
            decl["kind"] = item["kind"]
        if "required_labels" in item:
            labels = _labels(item["required_labels"])
            if labels is None:
                raise _invalid(f"invalid required_labels for root {root_id}")
            decl["required_labels"] = labels
        if "retain_source" in item:
            if not isinstance(item["retain_source"], bool):
                raise _invalid(f"retain_source of root {root_id} must be a boolean")
            decl["retain_source"] = item["retain_source"]
        if "path" in item:
            if not _valid_absolute(item["path"]):
                raise _invalid(f"path of root {root_id} must be an absolute path without . or .. components")
            decl["path"] = item["path"]
        if any(r["root_id"] == root_id for r in roots):
            raise _invalid(f"root {root_id} is declared twice")
        roots.append(decl)

    total = 0
    parsed = []
    for index, item in enumerate(changes):
        if not isinstance(item, dict):
            raise _invalid(f"changes[{index}] must be an object")
        op = item.get("op")
        if op not in OPS:
            raise _invalid(f"changes[{index}].op is not one of {', '.join(OPS)}: {op!r}")
        _check_fields(item, _OP_FIELDS[op], "a change")
        root_id = item.get("root_id")
        if not valid_root_id(root_id):
            raise _invalid(f"invalid root_id: {root_id!r}")
        change = {"op": op, "root_id": root_id, "path": "", "size": None, "mtime_ms": None,
                  "sha256": None, "bytes": None, "file": None, "required_labels": [], "moved_from": None}
        if op != "remove_root":
            if not valid_relative_path(item.get("path")):
                raise _invalid(f"changes[{index}].path is not a safe root-relative path")
            change["path"] = item["path"]
        if "size" in item:
            size = item["size"]
            if isinstance(size, bool) or not isinstance(size, int) or size < 0:
                raise _invalid(f"changes[{index}].size must be a non-negative integer")
            change["size"] = size
        if item.get("mtime_ms") is not None:
            if isinstance(item["mtime_ms"], bool) or not isinstance(item["mtime_ms"], int):
                raise _invalid(f"changes[{index}].mtime_ms must be an integer")
            change["mtime_ms"] = item["mtime_ms"]
        if "required_labels" in item:
            labels = _labels(item["required_labels"])
            if labels is None:
                raise _invalid(f"changes[{index}].required_labels is invalid")
            change["required_labels"] = labels
        if op == "move":
            moved_from = item.get("moved_from")
            if not valid_relative_path(moved_from):
                raise _invalid(f"changes[{index}].moved_from is not a safe root-relative path")
            if moved_from == change["path"]:
                raise _invalid(f"changes[{index}] moves a path onto itself")
            change["moved_from"] = moved_from
        elif op in ("add", "change"):
            has_content, has_file = "content_base64" in item, "file" in item
            if has_content == has_file:
                raise _invalid(f"changes[{index}] needs exactly one of content_base64 or file")
            if "sha256" in item:
                digest = item["sha256"]
                if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
                    raise _invalid(f"changes[{index}].sha256 must be 64 hex digits")
                change["sha256"] = digest.lower()
            if has_content:
                text = item["content_base64"]
                data = strict_base64(text) if isinstance(text, str) else None
                if data is None:
                    raise _invalid(f"changes[{index}].content_base64 is not strict base64")
                if len(data) <= max_file_bytes:
                    total += len(data)
                    if total > max_total_bytes:
                        raise ApplyError("capacity", f"content over the {max_total_bytes}-byte batch cap")
                change["bytes"] = data
            else:
                if not allow_file_reads:
                    raise _invalid(f"changes[{index}] uses file, but file reads are not enabled")
                if not _valid_absolute(item["file"]):
                    raise _invalid(f"changes[{index}].file must be an absolute path without . or .. components")
                if change["sha256"] is None:
                    raise _invalid(f"changes[{index}].sha256 is required with file")
                change["file"] = item["file"]
        parsed.append(change)
    return {"roots": roots, "changes": parsed}


class FolderIndex:
    """An in-memory index of several roots fed by `apply_changes`."""

    def __init__(self, *, max_chars: int | None = None, overlap_lines: int | None = None):
        self.generation = 0
        self.roots: dict[str, dict] = {}
        self.files: dict[str, dict] = {}  # record path -> file
        # Files given but not indexed in full (too large, unreadable), until
        # a later change of the path: `truncated` (`meta.skipped` in the engine).
        self.skipped: dict[str, dict] = {}
        self._chunking = {k: v for k, v in (("max_chars", max_chars), ("overlap_lines", overlap_lines)) if v is not None}

    # ------------------------------------------------------------ writing ---

    def apply_changes(self, request: dict | str, *, allow_file_reads: bool = False,
                      max_file_bytes: int = DEFAULT_MAX_FILE_BYTES,
                      max_total_bytes: int = DEFAULT_MAX_TOTAL_BYTES,
                      detect_renames: bool = True) -> dict:
        expect, body, deferred = parse_request(request, allow_file_reads=allow_file_reads,
                                               max_file_bytes=max_file_bytes,
                                               max_total_bytes=max_total_bytes)
        if expect is not None and expect != self.generation:
            raise _invalid(f"stale: generation is {self.generation}")
        if deferred is not None:
            raise deferred
        roots = {k: dict(v) for k, v in self.roots.items()}
        skipped = {k: dict(v) for k, v in self.skipped.items()}
        files = {k: dict(v) for k, v in self.files.items()}
        initial = {k: (v["status"], v["sha256"], v["root_id"], v["path"]) for k, v in files.items()}
        local_paths: dict[str, str] = {}
        declared = {d["root_id"]: d for d in body["roots"]}

        def new_root(decl: dict) -> dict:
            kind = decl.get("kind", "host")
            return {"root_id": decl["root_id"], "label": decl.get("label", decl["root_id"]), "kind": kind,
                    "required_labels": list(decl.get("required_labels", [])),
                    "retain_source": decl.get("retain_source", default_retain(kind)), "origin": "host"}

        for decl in body["roots"]:
            root_id = decl["root_id"]
            if root_id in roots:
                root = roots[root_id]
                for key in ("label", "kind", "required_labels", "retain_source"):
                    if key in decl:
                        root[key] = list(decl[key]) if key == "required_labels" else decl[key]
            else:
                if "kind" not in decl:
                    raise _invalid(f"new root {root_id} needs a kind")
                if LEGACY_ROOT_ID in roots and any(
                    f["root_id"] == LEGACY_ROOT_ID and f["path"].startswith(root_id + "/") for f in files.values()
                ):
                    raise _invalid(f"root_id {root_id} collides with a folder path of root {LEGACY_ROOT_ID}")
                roots[root_id] = new_root(decl)
            if "path" in decl:
                if roots[root_id]["kind"] != "local":
                    raise _invalid(f"root {root_id} has a path but is not kind local")
                local_paths[root_id] = decl["path"]

        sizes: dict[int, int | None] = {}
        planned = 0
        for index, change in enumerate(body["changes"]):
            if change["op"] != "remove_root" and change["root_id"] not in roots and change["root_id"] not in declared:
                raise _invalid(f"changes[{index}] names an undeclared root: {change['root_id']}")
            if change["file"] is not None:
                root = roots[change["root_id"]]
                if root["kind"] != "local" or change["root_id"] not in local_paths:
                    raise _invalid(f"changes[{index}].file needs root {change['root_id']} declared in this request with kind local and a path")
                outcome = _confine(local_paths[change["root_id"]], change["file"])
                if outcome == "outside":
                    raise _invalid(f"changes[{index}].file is outside root {change['root_id']}")
                if outcome == "symlink":
                    raise _invalid(f"changes[{index}].file passes through a symlink (refused)")
                sizes[index] = outcome if isinstance(outcome, int) else None
                if isinstance(outcome, int) and outcome <= max_file_bytes:
                    planned += outcome
            elif change["bytes"] is not None and len(change["bytes"]) <= max_file_bytes:
                planned += len(change["bytes"])
        if planned > max_total_bytes:
            raise ApplyError("capacity", f"{planned} bytes of content is over the {max_total_bytes}-byte batch cap")

        report = {"generation": 0, "added": 0, "changed": 0, "removed": 0, "moved": 0, "pending": 0,
                  "unchanged": 0, "too_large": 0, "too_large_paths": [], "unreadable": 0,
                  "unreadable_paths": [], "rejected": [], "conflicts": [], "ambiguous_moves": [],
                  "roots_removed": 0, "budget_exhausted": 0, "bytes_read": 0}
        gone: dict[str, str] = {}
        touched: dict[str, str] = {}
        carried_after_failure: set[str] = set()

        def skip(change: dict, record: str, reason: str) -> None:
            skipped[record] = {"root_id": change["root_id"], "path": change["path"],
                               "labels": change["required_labels"], "reason": reason}

        def touch(root_id: str, path: str, record: str, op: str) -> None:
            skipped.pop(record, None)
            if record in touched:
                report["conflicts"].append({"root_id": root_id, "path": path, "replaced": touched[record], "by": op})
            touched[record] = op

        def reject(change: dict, reason: str) -> None:
            report["rejected"].append({"root_id": change["root_id"], "path": change["path"], "reason": reason})

        for index, change in enumerate(body["changes"]):
            op, root_id, path = change["op"], change["root_id"], change["path"]
            if op == "remove_root":
                if root_id in roots:
                    for record in [r for r, f in skipped.items() if f["root_id"] == root_id]:
                        del skipped[record]
                    for record in [r for r, f in files.items() if f["root_id"] == root_id]:
                        del files[record]
                        gone[record] = "root"
                    del roots[root_id]
                    report["roots_removed"] += 1
                continue
            if root_id not in roots:
                if root_id not in declared:
                    reject(change, "root_removed")
                    continue
                roots[root_id] = new_root(declared[root_id])
            record = record_path(root_id, path)
            touch(root_id, path, record, op)
            if op == "remove":
                if files.pop(record, None) is not None:
                    gone[record] = "removed"
            elif op == "pending":
                files[record] = {"root_id": root_id, "path": path, "status": "pending", "sha256": None,
                                 "size": change["size"], "mtime_ms": change["mtime_ms"],
                                 "labels": change["required_labels"], "data": None, "chunks": [],
                                 "moved_from": None, "pending_set": True}
                gone.pop(record, None)
            elif op == "move":
                source = record_path(root_id, change["moved_from"])
                touch(root_id, change["moved_from"], source, op)
                moving = files.pop(source, None)
                if moving is None:
                    reject(change, "move_source_unknown")
                    continue
                gone[source] = "moved"
                moving = dict(moving, path=path, moved_from=change["moved_from"],
                              chunks=self._rekey(moving["chunks"], record))
                if change["mtime_ms"] is not None:
                    moving["mtime_ms"] = change["mtime_ms"]
                files[record] = moving
                gone.pop(record, None)
            else:  # add / change
                data = change["bytes"]
                if data is None:
                    size = sizes.get(index)
                    if size is None:
                        report["unreadable_paths"].append({"root_id": root_id, "path": path})
                        carried_after_failure.add(record)
                        skip(change, record, "unreadable")
                        continue
                    if size > max_file_bytes:
                        report["too_large_paths"].append({"root_id": root_id, "path": path})
                        skip(change, record, "too_large")
                        if files.pop(record, None) is not None:
                            gone[record] = "too_large"
                        continue
                    try:
                        with open(change["file"], "rb", opener=lambda p, f: os.open(p, f | os.O_NOFOLLOW)) as handle:
                            data = handle.read()
                        data.decode("utf-8")
                    except (OSError, UnicodeDecodeError):
                        report["unreadable_paths"].append({"root_id": root_id, "path": path})
                        carried_after_failure.add(record)
                        skip(change, record, "unreadable")
                        continue
                elif len(data) > max_file_bytes:
                    report["too_large_paths"].append({"root_id": root_id, "path": path})
                    skip(change, record, "too_large")
                    if files.pop(record, None) is not None:
                        gone[record] = "too_large"
                    continue
                report["bytes_read"] += len(data)
                try:
                    data.decode("utf-8")
                except UnicodeDecodeError:
                    reject(change, "invalid_utf8")
                    continue
                digest = hashlib.sha256(data).hexdigest()
                if change["sha256"] is not None and change["sha256"] != digest:
                    reject(change, "hash_mismatch")
                    continue
                if change["size"] is not None and change["size"] != len(data):
                    reject(change, "size_mismatch")
                    continue
                old = files.get(record)
                entry = {"root_id": root_id, "path": path, "status": "indexed", "sha256": digest,
                         "size": len(data), "mtime_ms": change["mtime_ms"], "labels": change["required_labels"],
                         "data": data, "chunks": None, "moved_from": None, "from_content": True}
                if (old is not None and old["status"] == "indexed" and not old.get("fresh")
                        and old["sha256"] == digest and old.get("chunker") == chunker_for_path(path)):
                    entry.update(chunks=old["chunks"], moved_from=old.get("moved_from"), from_content=False,
                                 chunker=old.get("chunker"))
                else:
                    entry["fresh"] = True
                files[record] = entry
                gone.pop(record, None)

        if detect_renames:
            self._detect_renames(files, initial, gone, report)

        # Build: chunk the fresh files, relabel every chunk (root ∪ file labels).
        for record, entry in files.items():
            if entry["status"] != "indexed":
                continue
            if entry.get("fresh"):
                entry["chunks"] = self._chunk(record, entry["path"], entry["data"])
                entry["chunker"] = chunker_for_path(entry["path"])
            labels = sorted(set(roots[entry["root_id"]]["required_labels"]) | set(entry["labels"]))
            entry["chunks"] = [dict(c, required_labels=labels) for c in entry["chunks"]]

        for record, entry in files.items():
            first = initial.get(record)
            if entry.get("moved_from") is not None:
                report["moved"] += 1
            elif entry["status"] == "pending":
                if entry.get("pending_set"):
                    report["pending"] += 1
            elif first is None or first[0] != "indexed":
                report["added"] += 1
            elif entry.get("fresh"):
                report["changed"] += 1
            elif record not in carried_after_failure:
                report["unchanged"] += 1
        report["removed"] = sum(1 for r, cause in gone.items() if cause == "removed" and r not in files and r in initial)
        report["too_large"] = len(report["too_large_paths"])
        report["unreadable"] = len(report["unreadable_paths"])

        for entry in files.values():  # batch-only marks
            entry.pop("fresh", None)
            entry.pop("from_content", None)
            entry.pop("pending_set", None)
        for entry in files.values():
            entry["recorded_moved_from"] = entry.pop("moved_from", None) or entry.get("recorded_moved_from")
            entry["moved_from"] = None
        self.roots, self.files, self.skipped = roots, files, skipped
        self.generation += 1
        report["generation"] = self.generation
        return report

    def _chunk(self, record: str, path: str, data: bytes) -> list[dict]:
        chunks = []
        for start, end, content, section_path, heading_line, chunker in file_chunks(path, data.decode("utf-8"), **self._chunking):
            tokens = tokenize(content)
            if not tokens:
                continue
            chunks.append({"id": _chunk_id(record, start, end, content), "path": record, "start_line": start,
                           "end_line": end, "text": content, "terms": dict(Counter(tokens)),
                           "length": len(tokens), "section_path": section_path,
                           "heading_line": heading_line, "chunker": chunker, "required_labels": []})
        return chunks

    @staticmethod
    def _rekey(chunks: list[dict], record: str) -> list[dict]:
        return [dict(c, path=record, id=_chunk_id(record, c["start_line"], c["end_line"], c["text"])) for c in chunks]

    def _detect_renames(self, files: dict, initial: dict, gone: dict, report: dict) -> None:
        removed: dict[tuple[str, str], list[str]] = {}
        added: dict[tuple[str, str], list[str]] = {}
        for record, cause in gone.items():
            if cause != "removed" or record in files or record not in initial:
                continue
            status, digest, root_id, _ = initial[record]
            if status == "indexed" and digest:
                removed.setdefault((root_id, digest), []).append(record)
        for record, entry in files.items():
            if not entry.get("from_content") or entry.get("moved_from") is not None or entry["status"] != "indexed":
                continue
            if record in initial and initial[record][0] == "indexed":
                continue
            added.setdefault((entry["root_id"], entry["sha256"]), []).append(record)
        for key in sorted(removed):
            if key not in added:
                continue
            sources, targets = sorted(removed[key]), sorted(added[key])
            pairs = []
            for source, target in zip(sources, targets):
                entry = files[target]
                old = self.files[source]
                entry["moved_from"] = initial[source][3]
                entry["from_content"] = False
                if chunker_for_path(old["path"]) == chunker_for_path(entry["path"]):
                    entry["chunks"] = self._rekey(old["chunks"], target)
                    entry["chunker"] = old.get("chunker")
                    entry.pop("fresh", None)
                gone[source] = "moved"
                pairs.append({"from": initial[source][3], "to": entry["path"]})
            if len(sources) > 1 or len(targets) > 1:
                report["ambiguous_moves"].append({
                    "root_id": key[0], "sha256": key[1],
                    "from": [initial[s][3] for s in sources], "to": [files[t]["path"] for t in targets],
                    "pairs": pairs,
                })

    # ------------------------------------------------------------ reading ---

    def _allowed(self, roots: Iterable[str] | None, principal_labels: Iterable[str]) -> set[str]:
        held = set(principal_labels)
        named = None if roots is None else set(roots)
        return {rid for rid, root in self.roots.items()
                if (named is None or rid in named) and set(root["required_labels"]) <= held}

    def visible_chunks(self, *, roots: Iterable[str] | None = None, principal_labels: Iterable[str] = ()) -> list[dict]:
        held = set(principal_labels)
        allowed = self._allowed(roots, held)
        return [chunk for record in sorted(self.files) for chunk in self.files[record]["chunks"]
                if self.files[record]["root_id"] in allowed and set(chunk["required_labels"]) <= held]

    def _file_visible(self, entry: dict, allowed: set[str], held: set[str]) -> bool:
        if entry["root_id"] not in allowed:
            return False
        labels = set(self.roots[entry["root_id"]]["required_labels"]) | set(entry["labels"])
        return labels <= held

    def search(self, query: str, *, roots: Iterable[str] | None = None, principal_labels: Iterable[str] = (),
               top_k: int = 5, conjunctive: bool = False) -> list[dict]:
        """BM25 over the visible scope (statistics included). `conjunctive`
        keeps only chunks holding every query term (the lifecycle runner's
        `words` filter; S3-T2 owns the real `find` modes)."""
        terms = tokenize(query)
        if not terms:
            return []
        chunks = self.visible_chunks(roots=roots, principal_labels=principal_labels)
        scores = _bm25_scores(chunks, terms)
        by_id = {c["id"]: c for c in chunks}
        if conjunctive:
            scores = {i: s for i, s in scores.items() if all(t in by_id[i]["terms"] for t in set(terms))}
        ordered = sorted(((i, s) for i, s in scores.items() if s > 0), key=lambda item: (-item[1], item[0]))[:top_k]
        results = []
        for identifier, score in ordered:
            chunk = by_id[identifier]
            entry = self.files[chunk["path"]]
            results.append({"chunk_id": identifier, "root_id": entry["root_id"], "path": entry["path"],
                            "start_line": chunk["start_line"], "end_line": chunk["end_line"],
                            "section_path": chunk["section_path"], "score": score, "content": chunk["text"]})
        return results

    def read_chunk(self, chunk_id: str, *, roots: Iterable[str] | None = None, principal_labels: Iterable[str] = ()) -> dict | None:
        for chunk in self.visible_chunks(roots=roots, principal_labels=principal_labels):
            if chunk["id"] == chunk_id:
                return {"chunk_id": chunk_id, "path": chunk["path"], "start_line": chunk["start_line"],
                        "end_line": chunk["end_line"], "content": chunk["text"]}
        return None

    def list_sources(self, *, roots: Iterable[str] | None = None, principal_labels: Iterable[str] = ()) -> list[dict]:
        counts = Counter(c["path"] for c in self.visible_chunks(roots=roots, principal_labels=principal_labels))
        return [{"path": p, "chunks": counts[p]} for p in sorted(counts)]

    def list_files(self, *, roots: Iterable[str] | None = None, principal_labels: Iterable[str] = ()) -> list[dict]:
        held = set(principal_labels)
        allowed = self._allowed(roots, held)
        out = []
        for entry in self.files.values():
            if not self._file_visible(entry, allowed, held):
                continue
            out.append({"root_id": entry["root_id"], "path": entry["path"], "status": entry["status"],
                        "chunks": len(entry["chunks"]),
                        "chunker": entry.get("chunker") if entry["chunks"] else None})
        return sorted(out, key=lambda f: (f["root_id"], f["path"]))

    def index_status(self, *, roots: Iterable[str] | None = None, principal_labels: Iterable[str] = ()) -> dict:
        held = set(principal_labels)
        allowed = self._allowed(roots, held)
        chunks = self.visible_chunks(roots=roots, principal_labels=held)
        visible = [f for f in self.files.values() if self._file_visible(f, allowed, held)]
        pending = sorted(({"root_id": f["root_id"], "path": f["path"]} for f in visible if f["status"] == "pending"),
                         key=lambda r: (r["root_id"], r["path"]))
        terms = Counter()
        for chunk in chunks:
            terms.update(chunk["terms"].keys())
        return {
            "generation": self.generation,
            "documents": len(chunks),
            "terms": len(terms),
            "postings": sum(terms.values()),
            "files": sum(1 for f in visible if f["status"] == "indexed"),
            "pending": len(pending),
            "pending_paths": pending,
            "truncated": any(self._file_visible(f, allowed, held) for f in self.skipped.values()),
            "roots": [{"root_id": rid, "label": self.roots[rid]["label"], "kind": self.roots[rid]["kind"]}
                      for rid in self.roots if rid in allowed],
            "chunkers": sorted({c["chunker"] for c in chunks}, key=lambda c: (c != "line-window-v1", c)),
        }

    def _visible_data(self, root_id: str, path: str, roots, principal_labels) -> bytes:
        held = set(principal_labels)
        entry = self.files.get(record_path(root_id, path)) if root_id in self.roots else None
        if (entry is None or entry["status"] != "indexed" or entry.get("data") is None
                or not self._file_visible(entry, self._allowed(roots, held), held)):
            raise ReadError("not_found", f"not indexed or not retained: {record_path(root_id, path)}")
        return entry["data"]

    def read_span(self, root_id: str, path: str, start_line: int, end_line: int, context_lines: int = 0, *,
                  roots: Iterable[str] | None = None, principal_labels: Iterable[str] = ()) -> dict:
        return read_span_bytes(self._visible_data(root_id, path, roots, principal_labels), start_line, end_line, context_lines)

    def outline(self, root_id: str, path: str, *, roots: Iterable[str] | None = None,
                principal_labels: Iterable[str] = ()) -> dict:
        return outline_bytes(path, self._visible_data(root_id, path, roots, principal_labels))


def add_change(root_id: str, path: str, data: bytes | str, **extra) -> dict:
    """An `add` change carrying `content_base64` (a convenience for callers and tests)."""
    if isinstance(data, str):
        data = data.encode("utf-8")
    return {"op": "add", "root_id": root_id, "path": path,
            "content_base64": base64.b64encode(data).decode("ascii"), **extra}


def folder_changes(root_id: str, folder: Path) -> list[dict]:
    """`add` changes for every candidate file of `folder` (the walk's file set)."""
    from .core import _iter_text_files

    folder = folder.expanduser().resolve()
    return [add_change(root_id, p.relative_to(folder).as_posix(), p.read_bytes()) for p in _iter_text_files(folder)]
