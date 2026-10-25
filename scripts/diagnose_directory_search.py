#!/usr/bin/env python3
"""Capture current Python/native directory-search behavior in a disposable corpus."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]

def clean(value: str | bytes | None) -> str:
    if isinstance(value, bytes):
        value = value.decode(errors="replace")
    return (value or "").replace(str(CORPUS), "$CORPUS")

def run(label: str, argv: list[str], *, timeout: int = 30) -> dict[str, Any]:
    started = time.monotonic()
    try:
        result = subprocess.run(
            argv, cwd=ROOT, capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        OBSERVATIONS["processes"].append({
            "label": label,
            "exit_code": None,
            "timed_out": True,
            "timeout_seconds": timeout,
            "elapsed_ms": round((time.monotonic() - started) * 1000, 3),
            "stdout": clean(exc.stdout), "stderr": clean(exc.stderr),
        })
        raise RuntimeError(f"{label} timed out after {timeout}s") from exc
    item = {
        "label": label,
        "exit_code": result.returncode,
        "elapsed_ms": round((time.monotonic() - started) * 1000, 3),
        "stdout": clean(result.stdout).strip(), "stderr": clean(result.stderr).strip(),
    }
    OBSERVATIONS["processes"].append(item)
    if result.returncode != 0:
        raise RuntimeError(f"{label} exited {result.returncode}: {item['stderr']}")
    return item

def py(*args: str) -> list[str]:
    return [sys.executable, str(ROOT / "search.py"), *args]

def python_search(label: str, index: Path, query: str) -> dict[str, Any]:
    item = run(label, py("context", str(index), query, "--mode", "lexical"))
    payload = json.loads(item["stdout"])
    return {"count": len(payload["results"]), "results": payload["results"]}

def zig_search(label: str, searchd: Path, index: Path, query: str) -> dict[str, Any]:
    item = run(label, [str(searchd), "evidence", str(index), query])
    payload = json.loads(item["stdout"])
    results = [
        {
            "chunk_id": evidence["chunk_id"],
            "citation": {
                "path": evidence["path"],
                "start_line": evidence["start_line"],
                "end_line": evidence["end_line"],
            },
            "content": evidence["content"],
            "score": evidence["fused_score"],
        }
        for evidence in payload.get("evidence", [])
    ]
    return {"count": len(results), "results": results}

def validate_citations(case: dict[str, Any], docs: Path) -> None:
    for result in case["results"]:
        if not isinstance(result.get("chunk_id"), str) or not result["chunk_id"]:
            raise AssertionError("result has no stable chunk id")
        citation = result.get("citation")
        if not isinstance(citation, dict):
            raise AssertionError("result has no citation object")
        path = citation.get("path")
        start, end = citation.get("start_line"), citation.get("end_line")
        if not isinstance(path, str) or type(start) is not int or type(end) is not int:
            raise AssertionError(f"citation has invalid path or line bounds: {citation!r}")
        source = (docs / path).resolve()
        if not source.is_relative_to(docs.resolve()) or not source.is_file():
            raise AssertionError(f"citation path does not name a current corpus file: {path!r}")
        lines = source.read_text(encoding="utf-8").splitlines()
        if start < 1 or end < start or end > len(lines):
            raise AssertionError(f"citation line bounds are outside {path!r}: {start}-{end}")
        expected = "\n".join(lines[start - 1:end])
        if result.get("content") != expected:
            raise AssertionError(f"cited content differs from source span {path}:{start}-{end}")

def assert_citation(case: dict[str, Any], path: str, line: int, text: str) -> None:
    if not any(
        result.get("citation", {}).get("path") == path
        and result["citation"].get("start_line") <= line <= result["citation"].get("end_line")
        and text in result.get("content", "")
        for result in case["results"]
    ):
        raise AssertionError(f"expected cited body passage {path}:{line} containing {text!r}")

def checked_search(engine: str, label: str, searchd: Path, index: Path, query: str, docs: Path) -> dict[str, Any]:
    case = (
        python_search(f"python-{label}", index, query)
        if engine == "python"
        else zig_search(f"zig-{label}", searchd, index, query)
    )
    validate_citations(case, docs)
    return case

def write_file(root: Path, relative: str, content: str) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--searchd", required=True, type=Path, help="prepared native searchd executable")
    args = parser.parse_args()
    searchd = args.searchd.resolve()
    if not searchd.is_file():
        parser.error(f"searchd executable does not exist: {searchd}")
    global CORPUS, OBSERVATIONS
    OBSERVATIONS = {"processes": [], "assertions": [], "searches": {}, "fixtures": {}}
    OBSERVATIONS["environment"] = environment_stamp(searchd)
    with tempfile.TemporaryDirectory(prefix="search-directory-diagnostic-") as temporary:
        CORPUS = Path(temporary)
        docs = CORPUS / "docs"
        write_file(docs, "camp-notes.md", "Asterion water filter uses a ceramic membrane.\nA second line records the pressure limit.\n")
        write_file(docs, "Annual_Budget_2026.md", "The cobalt engine stores energy in a flywheel.\n")
        write_file(docs, "தமிழ்_பெயர்மட்டும்.md", "இது ஒரு பொதுவான ஆவணம்.\nநீர்வடிகட்டி சுத்தமான நீரை வழங்குகிறது.\n")
        write_file(docs, "தமிழ்_உள்ளடக்கம்.md", "மழைநீர் சேகரிப்பு நல்லது.\n")
        write_file(docs, ".hidden/secrets.md", "Xylophonic hiddenneedle should never be indexed.\n")
        for path in sorted(docs.rglob("*")):
            if path.is_file():
                relative = path.relative_to(docs).as_posix()
                OBSERVATIONS["fixtures"][relative] = {
                    "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                    "utf8": path.read_text(encoding="utf-8"),
                }
        py_index = CORPUS / "python-index.json"
        zig_index = CORPUS / "zig-index"
        run("python-index-initial", py("index", str(docs), "--vector-mode", "none", "--out", str(py_index)))
        run("zig-index-initial", [str(searchd), "index", str(docs), "--out", str(zig_index)])
        for engine in ("python", "zig"):
            index = py_index if engine == "python" else zig_index
            run_search = lambda name, query: checked_search(engine, name, searchd, index, query, docs)
            hit = run_search("content-hit", "Asterion water filter")
            assert_citation(hit, "camp-notes.md", 1, "Asterion water filter")
            absent = run_search("absent-query", "unobtainium absentneedle")
            if absent["count"] != 0:
                raise AssertionError(f"{engine} returned results for absent terms")
            hidden = run_search("ignored-hidden-file", "Xylophonic hiddenneedle")
            if hidden["count"] != 0:
                raise AssertionError(f"{engine} indexed an ignored hidden file")
            phrase = run_search("reversed-quoted-terms", '"filter water"')
            filename = run_search("filename-only-budget-name", "Annual Budget 2026")
            tamil = run_search("tamil-body-content", "நீர்வடிகட்டி")
            assert_citation(tamil, "தமிழ்_பெயர்மட்டும்.md", 2, "நீர்வடிகட்டி")
            tamil_name = run_search("tamil-filename-only", "பெயர்மட்டும்")
            OBSERVATIONS["searches"][f"{engine}_baseline"] = {
                "content_hit": hit,
                "absent_query": absent,
                "ignored_hidden": hidden,
                "reversed_quoted_terms": phrase,
                "filename_only_budget_name": filename,
                "tamil_body_content": tamil,
                "tamil_filename_only": tamil_name,
            }
        OBSERVATIONS["assertions"].extend((
            "Python and Zig return body content with relative path and line citation.",
            "Absent terms and content in ignored hidden files return no results.",
            "Tamil body content returns a cited passage in both engines.",
        ))

        # Change one file, remove one file, and rename one file before the same update.
        write_file(docs, "camp-notes.md", "Asterion water filter now uses a graphene membrane.\nA second line records the pressure limit.\n")
        (docs / "Annual_Budget_2026.md").unlink()
        (docs / "தமிழ்_பெயர்மட்டும்.md").rename(docs / "தமிழ்_renamed.md")
        py_next = CORPUS / "python-index-updated.json"
        run("python-index-incremental-update", py(
            "index", str(docs), "--vector-mode", "none", "--incremental-from", str(py_index), "--out", str(py_next),
        ))
        run("zig-index-incremental-update", [str(searchd), "index", str(docs), "--out", str(zig_index), "--update"])
        for engine in ("python", "zig"):
            index = py_next if engine == "python" else zig_index
            run_search = lambda name, query: checked_search(engine, name, searchd, index, query, docs)
            changed = run_search("updated-content", "Asterion graphene membrane")
            assert_citation(changed, "camp-notes.md", 1, "graphene membrane")
            old = run_search("removed-old-content", "ceramic")
            if old["count"]:
                raise AssertionError(f"{engine} retained superseded content")
            deleted = run_search("deleted-file-content", "cobalt engine flywheel")
            if deleted["count"]:
                raise AssertionError(f"{engine} retained deleted-file content")
            renamed = run_search("renamed-file-content", "நீர்வடிகட்டி")
            assert_citation(renamed, "தமிழ்_renamed.md", 2, "நீர்வடிகட்டி")
            if any(result["citation"]["path"] == "தமிழ்_பெயர்மட்டும்.md" for result in renamed["results"]):
                raise AssertionError(f"{engine} returned the pre-rename citation")
            OBSERVATIONS["searches"][f"{engine}_after_update"] = {
                "changed_content": changed,
                "superseded_content": old,
                "deleted_file_content": deleted,
                "renamed_file_content": renamed,
            }
        OBSERVATIONS["assertions"].append(
            "Incremental updates replace changed content, remove deleted content, and cite a renamed path."
        )
        help_text = run("zig-cli-help", [str(searchd), "--help"])["stdout"]
        OBSERVATIONS["environment"]["searchd_first_line"] = help_text.splitlines()[0]
        OBSERVATIONS["status"] = "passed"
        print(json.dumps(OBSERVATIONS, ensure_ascii=False, indent=2))
    return 0

def environment_stamp(searchd: Path) -> dict[str, Any]:
    git = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=True)
    dirty = subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, capture_output=True, text=True, check=True)
    version = subprocess.run([sys.executable, "--version"], capture_output=True, text=True, check=True)
    zig_path = shutil.which("zig")
    zig_version = None
    if zig_path:
        zig_version = subprocess.run([zig_path, "version"], capture_output=True, text=True, check=True, timeout=10).stdout.strip()
    digest = hashlib.sha256(searchd.read_bytes()).hexdigest()
    return {
        "git_sha": git.stdout.strip(),
        "git_dirty": bool(dirty.stdout.strip()),
        "python_version": version.stdout.strip(),
        "zig_version": zig_version,
        "zig_version_note": "PATH toolchain version only; the searchd binary does not report its build Zig version.",
        "searchd_path_recorded": searchd.name,
        "searchd_sha256": digest,
        "platform": platform.platform(),
        "machine": platform.machine(),
        "corpus_root": "$TEMPORARY_DIRECTORY",
    }
CORPUS = Path(".")
OBSERVATIONS: dict[str, Any] = {}

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        OBSERVATIONS["status"] = "failed"
        OBSERVATIONS["error"] = str(error).replace(str(CORPUS), "$CORPUS")
        print(json.dumps(OBSERVATIONS, ensure_ascii=False, indent=2))
        raise SystemExit(1) from error
