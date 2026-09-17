#!/usr/bin/env python3
"""Generate the `line-window-v1` chunker golden conformance fixture (S1-T1).

Calls the *actual* Python reference functions in `search_platform.core`
(`_iter_text_files`, `_line_chunks`, `_chunk_id`) directly -- not a
reimplementation of them -- so the golden file is guaranteed to be exactly
what the Python reference produces. `zig/src/chunker_test.zig` reads the
generated JSON and asserts the Zig port produces identical chunk ids, line
ranges, and text on every listed file.

Run: `python3 scripts/gen_chunk_golden.py > fixtures/chunk-golden.json`
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, "src")
from search_platform import core  # noqa: E402

ROOTS = [
    "fixtures/knowledge",
    "fixtures/semantic-knowledge",
    "fixtures/mixed-knowledge",
    "fixtures/access-knowledge",
    "fixtures/relevance-smoke/corpus",
    "fixtures/app-text",
    "fixtures/tamil",
    "fixtures/chunk-stress",
]


def golden_for_root(root: Path) -> list[dict]:
    entries = []
    for path in core._iter_text_files(root):
        relative_path = path.relative_to(root).as_posix()
        text = path.read_bytes().decode("utf-8")
        chunks = []
        for start_line, end_line, chunk_text in core._line_chunks(text):
            chunk_id = core._chunk_id(relative_path, start_line, end_line, chunk_text)
            chunks.append(
                {
                    "id": chunk_id,
                    "start_line": start_line,
                    "end_line": end_line,
                    "text": chunk_text,
                }
            )
        entries.append({"path": relative_path, "chunks": chunks})
    entries.sort(key=lambda e: e["path"])
    return entries


def main() -> None:
    files = []
    for root_str in ROOTS:
        root = Path(root_str)
        if not root.is_dir():
            continue
        for entry in golden_for_root(root):
            files.append({"root": root_str, **entry})

    payload = {
        "chunker_id": core.CHUNKER_ID,
        "max_chars": core.CHUNK_MAX_CHARS,
        "overlap_lines": core.CHUNK_OVERLAP_LINES,
        "files": files,
    }
    total_chunks = sum(len(f["chunks"]) for f in files)
    print(json.dumps(payload, ensure_ascii=False, indent=1), file=sys.stdout)
    print(
        f"# {len(files)} files, {total_chunks} chunks",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
