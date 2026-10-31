#!/usr/bin/env python3
"""Generate the `md-section-v1` golden conformance fixture (S3-T1 ruling 2).

Calls the Python reference (`search_platform.core._md_section_chunks`,
`markdown_outline`, `_chunk_id`) directly. `zig/src/chunker_md_test.zig` reads
the JSON and asserts the Zig port in `zig/src/chunker_md.zig` produces the same
chunk ids, line ranges, text, section paths, heading lines and outlines on
every listed file. Every file is chunked with md-section-v1 whatever its
extension: the golden pins the chunker, not the extension dispatch.

Run from the repository root:
    python3 scripts/gen_chunk_golden_md.py > fixtures/chunk-golden-md.json
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, "src")
from search_platform import core  # noqa: E402

# (root, glob): the edge-case folder whole, then the Markdown of other fixtures.
SOURCES = [
    ("fixtures/markdown", "*"),
    ("fixtures/family-folder/school", "**/*.md"),
    ("fixtures/family-folder/home", "**/*.md"),
    ("fixtures/family-folder/laptop", "**/*.md"),
    ("fixtures/knowledge", "**/*.md"),
    ("fixtures/chunk-stress", "**/*.md"),
    ("fixtures/app-text", "**/*.md"),
]


def main() -> None:
    files = []
    for root_name, pattern in SOURCES:
        root = Path(root_name)
        for path in sorted(p for p in root.glob(pattern) if p.is_file()):
            relative_path = path.relative_to(root).as_posix()
            text = path.read_bytes().decode("utf-8")
            chunks = [
                {
                    "id": core._chunk_id(relative_path, start, end, content),
                    "start_line": start,
                    "end_line": end,
                    "text": content,
                    "section_path": section_path,
                    "heading_line": heading_line,
                }
                for start, end, content, section_path, heading_line in core._md_section_chunks(text)
            ]
            files.append({"root": root_name, "path": relative_path, "chunks": chunks,
                          "outline": core.markdown_outline(text)})
    payload = {
        "chunker_id": core.MD_CHUNKER_ID,
        "max_chars": core.CHUNK_MAX_CHARS,
        "overlap_lines": core.CHUNK_OVERLAP_LINES,
        "files": files,
    }
    print(json.dumps(payload, ensure_ascii=False, indent=1))
    print(f"# {len(files)} files, {sum(len(f['chunks']) for f in files)} chunks", file=sys.stderr)


if __name__ == "__main__":
    main()
