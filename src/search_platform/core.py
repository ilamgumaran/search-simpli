from __future__ import annotations

import hashlib
import json
import math
import re
import unicodedata
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass, field, replace
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Iterator

from ._marks import MARK_RANGES
from .access import ACCESS_SEMANTICS, is_authorized, required_labels_for_path
from .providers import EmbeddingProvider, ProviderMismatch


INDEX_VERSION = 1
MAX_COOCCURRENCE_TERMS = 512
CHUNKER_ID = "line-window-v1"
CHUNK_MAX_CHARS = 1_600
CHUNK_OVERLAP_LINES = 3


def _build_token_pattern() -> re.Pattern[str]:
    """analyzer-v2 token: a letter or digit, then letters, digits, the marks
    attached to them (General_Category Mn, Mc) and ZWJ/ZWNJ that are followed
    by more of the run. `x-ray` is still `x`, `ray`; `கணினி` is one token."""
    marks = "".join(
        f"\\U{lo:08x}" if lo == hi else f"\\U{lo:08x}-\\U{hi:08x}" for lo, hi in MARK_RANGES
    )
    body = rf"[^\W_]|[{marks}]"
    return re.compile(rf"[^\W_](?:{body}|[\u200c\u200d](?=[^\W_]|[{marks}]))*", re.UNICODE)


TOKEN_PATTERN = _build_token_pattern()
DEFAULT_EXTENSIONS = {
    ".c",
    ".cpp",
    ".css",
    ".go",
    ".h",
    ".html",
    ".java",
    ".js",
    ".json",
    ".md",
    ".py",
    ".rs",
    ".rst",
    ".toml",
    ".ts",
    ".txt",
    ".yaml",
    ".yml",
    ".zig",
}
IGNORED_DIRECTORIES = {
    ".git",
    ".search",
    ".zig-cache",
    "__pycache__",
    "node_modules",
    "zig-out",
}


@dataclass(frozen=True)
class Chunk:
    id: str
    path: str
    start_line: int
    end_line: int
    text: str
    terms: dict[str, int]
    length: int
    vector: list[float] | None
    required_labels: list[str]
    # S3-T1: md-section-v1 records the heading path and heading line; every
    # line-window-v1 chunk has an empty path and 0.
    section_path: list[str] = field(default_factory=list)
    heading_line: int = 0
    chunker: str = CHUNKER_ID


# S1-T15: variation selectors only choose a glyph; they are removed before
# splitting (`1` + U+FE0F + U+20E3 is the token `1`). Mirrors analyzer_v2.zig.
VARIATION_SELECTORS = re.compile("[\ufe00-\ufe0f\U000e0100-\U000e01ef]")


def tokenize(text: str) -> list[str]:
    normalized = VARIATION_SELECTORS.sub("", unicodedata.normalize("NFC", text))
    return [token.casefold() for token in TOKEN_PATTERN.findall(normalized)]


def _hash_vector(tokens: Iterable[str], dimensions: int = 128) -> list[float]:
    """Create an offline test vector; this does not understand semantic meaning."""
    values = [0.0] * dimensions
    for token, count in Counter(tokens).items():
        digest = hashlib.blake2b(token.encode("utf-8"), digest_size=8).digest()
        bucket = int.from_bytes(digest[:4], "little") % dimensions
        sign = 1.0 if digest[4] & 1 else -1.0
        values[bucket] += sign * (1.0 + math.log(count))
    norm = math.sqrt(sum(value * value for value in values))
    return [value / norm for value in values] if norm else values


def _normalize_vector(values: list[float]) -> list[float]:
    norm = math.sqrt(sum(value * value for value in values))
    return [value / norm for value in values] if norm else values


def _cooccurrence_model_id(model: dict) -> str:
    canonical_model = {
        "model_family": model.get("model_family", "cooccurrence-ppmi-v1"),
        "type": model["type"],
        "window": model["window"],
        "dimensions": model["dimensions"],
        "vocabulary": model["vocabulary"],
        "word_vectors": model["word_vectors"],
    }
    canonical = json.dumps(
        canonical_model,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")
    return f"cooccurrence-ppmi-v1-sha256-{hashlib.sha256(canonical).hexdigest()}"


def _fit_cooccurrence_model(tokenized_chunks: list[list[str]], *, window: int = 4) -> dict:
    """Train a small distributional-semantic PPMI model from this corpus."""
    corpus_frequency = Counter(token for tokens in tokenized_chunks for token in tokens)
    selected = sorted(corpus_frequency, key=lambda term: (-corpus_frequency[term], term))[
        :MAX_COOCCURRENCE_TERMS
    ]
    vocabulary = sorted(selected)
    vocabulary_set = set(vocabulary)
    cooccurrence: dict[str, Counter[str]] = defaultdict(Counter)
    for tokens in tokenized_chunks:
        filtered = [token for token in tokens if token in vocabulary_set]
        for position, token in enumerate(filtered):
            start = max(0, position - window)
            end = min(len(filtered), position + window + 1)
            for context_position in range(start, end):
                if context_position != position:
                    cooccurrence[token][filtered[context_position]] += 1

    row_totals = {term: sum(counts.values()) for term, counts in cooccurrence.items()}
    column_totals: Counter[str] = Counter()
    for counts in cooccurrence.values():
        column_totals.update(counts)
    total = sum(row_totals.values())
    vectors: dict[str, list[float]] = {}
    for term in vocabulary:
        values = []
        for context in vocabulary:
            count = cooccurrence[term][context]
            if not count or not total or not row_totals.get(term) or not column_totals[context]:
                values.append(0.0)
                continue
            pmi = math.log((count * total) / (row_totals[term] * column_totals[context]))
            values.append(max(0.0, pmi))
        vectors[term] = _normalize_vector(values)
    model = {
        "model_family": "cooccurrence-ppmi-v1",
        "type": "cooccurrence_ppmi",
        "window": window,
        "dimensions": len(vocabulary),
        "vocabulary": vocabulary,
        "word_vectors": vectors,
    }
    # This model is trained independently for each corpus. The family name alone
    # is not sufficient compatibility evidence: equal dimensions can still have
    # different vocabulary axes and weights. Fingerprint the canonical learned
    # artifact so query and document vectors can be matched fail-closed.
    model["model_id"] = _cooccurrence_model_id(model)
    return model


def _cooccurrence_vector(tokens: Iterable[str], model: dict) -> list[float]:
    dimensions = model["dimensions"]
    values = [0.0] * dimensions
    matched = 0
    for token in tokens:
        token_vector = model["word_vectors"].get(token)
        if token_vector is None:
            continue
        matched += 1
        for index, value in enumerate(token_vector):
            values[index] += value
    if matched:
        values = [value / matched for value in values]
    return _normalize_vector(values)


def _iter_text_files(root: Path) -> Iterator[Path]:
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix.casefold() not in DEFAULT_EXTENSIONS:
            continue
        if any(part in IGNORED_DIRECTORIES or part.startswith(".") for part in path.relative_to(root).parts):
            continue
        yield path


def _line_chunks(
    text: str,
    max_chars: int = CHUNK_MAX_CHARS,
    overlap_lines: int = CHUNK_OVERLAP_LINES,
) -> Iterator[tuple[int, int, str]]:
    lines = text.splitlines()
    if not lines and text:
        lines = [text]
    start = 0
    while start < len(lines):
        size = 0
        end = start
        while end < len(lines):
            candidate_size = len(lines[end]) + 1
            if end > start and size + candidate_size > max_chars:
                break
            size += candidate_size
            end += 1
        chunk_text = "\n".join(lines[start:end]).strip()
        if chunk_text:
            yield start + 1, end, chunk_text
        if end >= len(lines):
            break
        start = max(start + 1, end - overlap_lines)


def _chunk_id(path: str, start_line: int, end_line: int, text: str) -> str:
    identity = f"{path}\0{start_line}\0{end_line}\0{text}".encode("utf-8")
    return hashlib.sha256(identity).hexdigest()[:20]


# ------------------------------------------------------------ md-section-v1 ---
# S3-T1 (CAP-19 FR-18): Markdown files (`.md`, `.markdown`, case-insensitive)
# are chunked by sections; every other file keeps `line-window-v1` above.
# `zig/src/chunker_md.zig` is the native port; `fixtures/chunk-golden-md.json`
# (scripts/gen_chunk_golden_md.py) pins both. Format:
# docs/folder-knowledge-implementation.md section 2 and docs/segment-format-v4.md.

MD_CHUNKER_ID = "md-section-v1"
MARKDOWN_EXTENSIONS = {".md", ".markdown"}
FRONT_MATTER_MAX_LINES = 100
SECTION_PATH_SEPARATOR = "\x1f"
_BOM = "\ufeff"
_SETEXT = re.compile(r"^(=+|-+)[ \t]*$")
_SETEXT_EXCLUDED_STARTS = ("-", "*", "+", "#", "`")


def chunker_for_path(path: str) -> str:
    """The chunker id `index_folder` selects for a (relative) path."""
    return MD_CHUNKER_ID if Path(path).suffix.casefold() in MARKDOWN_EXTENSIONS else CHUNKER_ID


def _markdown_lines(text: str) -> list[str]:
    """The lines md-section-v1 sees: a leading BOM is not part of line 1."""
    if text.startswith(_BOM):
        text = text[1:]
    return text.splitlines()


def _atx_heading(line: str) -> tuple[int, str] | None:
    """`^(#{1,6})[ \\t]+(.*?)[ \\t]*#*[ \\t]*$`, written out so the Zig port is literal."""
    level = 0
    while level < len(line) and line[level] == "#":
        level += 1
    if not 1 <= level <= 6 or level >= len(line) or line[level] not in " \t":
        return None
    rest = line[level:].lstrip(" \t").rstrip(" \t").rstrip("#").rstrip(" \t")
    return level, rest


def _fence_marker(line: str) -> tuple[str, int] | None:
    """A fence line: three or more backticks or tildes at the start of the line."""
    if not line or line[0] not in "`~":
        return None
    char = line[0]
    run = len(line) - len(line.lstrip(char))
    return (char, run) if run >= 3 else None


def _markdown_structure(lines: list[str]) -> dict:
    """Front matter, headings and fenced blocks of a Markdown file's lines.

    Line indexes are 0-based here; callers add 1. Rules (S3-T1 ruling 2):
    front matter is a `---` line at line 1 up to the next `---` line within the
    first 100 lines; ATX headings need a space or tab after one to six `#`;
    a Setext heading is a non-blank line (not starting with - * + # or `)
    directly above a line of only `=` or only `-`; nothing inside a fence
    (``` or ~~~, closed by a line of at least as many of the same character
    and nothing else) is a heading.
    """
    front = None
    first = 0
    if lines and lines[0] == "---":
        for i in range(1, min(len(lines), FRONT_MATTER_MAX_LINES)):
            if lines[i] == "---":
                fields: dict[str, str] = {}
                valid = True
                for item in lines[1:i]:
                    if not item.strip():
                        continue
                    key, sep, value = item.partition(":")
                    if not sep or not key.strip():
                        valid = False
                        break
                    fields[key.strip()] = value.strip()
                front = {"start": 0, "end": i, "fields": fields if valid else {},
                         "valid": valid, "raw": "\n".join(lines[1:i])}
                first = i + 1
                break
    headings: list[dict] = []
    fences: list[tuple[int, int]] = []
    fence: tuple[str, int, int] | None = None
    i = first
    while i < len(lines):
        line = lines[i]
        if fence is not None:
            char, run, opened = fence
            marker = _fence_marker(line)
            if marker and marker[0] == char and marker[1] >= run and not line[marker[1]:].strip():
                fences.append((opened, i + 1))
                fence = None
            i += 1
            continue
        marker = _fence_marker(line)
        if marker:
            fence = (marker[0], marker[1], i)
            i += 1
            continue
        atx = _atx_heading(line)
        if atx:
            headings.append({"level": atx[0], "text": atx[1], "line": i})
        elif (line.strip() and i + 1 < len(lines) and _SETEXT.match(lines[i + 1])
                and not line.startswith(_SETEXT_EXCLUDED_STARTS)):
            level = 1 if lines[i + 1].startswith("=") else 2
            headings.append({"level": level, "text": line.strip(), "line": i})
            i += 1
        i += 1
    if fence is not None:
        fences.append((fence[2], len(lines)))
    return {"front_matter": front, "body_start": first, "headings": headings, "fences": fences}


def _section_windows(
    lines: list[str],
    start: int,
    stop: int,
    fitting: dict[int, int],
    max_chars: int,
    overlap_lines: int,
) -> Iterator[tuple[int, int]]:
    """line-window-v1 over lines[start:stop], except that a fenced block that
    fits `max_chars` (keys of `fitting`: first line -> one past the last) is
    one unit: a window never ends inside it and never restarts inside it."""
    s = start
    while s < stop:
        size = 0
        e = s
        while e < stop:
            fence_end = fitting.get(e)
            if fence_end is not None:
                unit = sum(len(lines[k]) + 1 for k in range(e, fence_end))
                if e > s and size + unit > max_chars:
                    break
                size += unit
                e = fence_end
                continue
            candidate = len(lines[e]) + 1
            if e > s and size + candidate > max_chars:
                break
            size += candidate
            e += 1
        yield s, e
        if e >= stop:
            break
        following = max(s + 1, e - overlap_lines)
        for fence_start, fence_end in fitting.items():
            if fence_start < following < fence_end:
                following = fence_start if fence_start > s else fence_end
                break
        s = following


def _md_section_chunks(
    text: str,
    max_chars: int = CHUNK_MAX_CHARS,
    overlap_lines: int = CHUNK_OVERLAP_LINES,
) -> Iterator[tuple[int, int, str, list[str], int]]:
    """md-section-v1: (start_line, end_line, text, section_path, heading_line).

    Front matter is excluded from the body; each heading opens a section that
    runs to the line before the next heading of any level; a chunk never
    crosses a section; inside a section the windows are line-window-v1's with
    the same parameters (fenced blocks that fit `max_chars` kept whole, longer
    ones windowed line by line). Text is joined with LF and stripped exactly
    as line-window-v1 does. The section before the first heading has an empty
    path and heading_line 0.
    """
    lines = _markdown_lines(text)
    structure = _markdown_structure(lines)
    fitting = {
        start: end
        for start, end in structure["fences"]
        if sum(len(lines[k]) + 1 for k in range(start, end)) <= max_chars
    }
    boundaries: list[tuple[int, list[str], int]] = []
    stack: list[dict] = []
    if not structure["headings"] or structure["headings"][0]["line"] > structure["body_start"]:
        boundaries.append((structure["body_start"], [], 0))
    for head in structure["headings"]:
        stack = [h for h in stack if h["level"] < head["level"]] + [head]
        boundaries.append((head["line"], [h["text"] for h in stack], head["line"] + 1))
    for number, (start, path, heading_line) in enumerate(boundaries):
        stop = boundaries[number + 1][0] if number + 1 < len(boundaries) else len(lines)
        for s, e in _section_windows(lines, start, stop, fitting, max_chars, overlap_lines):
            chunk_text = "\n".join(lines[s:e]).strip()
            if chunk_text:
                yield s + 1, e, chunk_text, list(path), heading_line


def markdown_outline(text: str) -> dict:
    """`outline` for one Markdown file's text (S3-T1 ruling 5, implementation section 8)."""
    lines = _markdown_lines(text)
    structure = _markdown_structure(lines)
    total = len(lines)
    heads = [{"level": h["level"], "text": h["text"], "line": h["line"] + 1} for h in structure["headings"]]
    for n, head in enumerate(heads):
        end = total
        for later in heads[n + 1:]:
            if later["level"] <= head["level"]:
                end = later["line"] - 1
                break
        head["end_line"] = end
    front = structure["front_matter"]
    front_matter = None
    if front is not None:
        front_matter = {"start_line": front["start"] + 1, "end_line": front["end"] + 1,
                        "fields": front["fields"]}
        if not front["valid"]:
            front_matter["raw"] = front["raw"]
    return {"front_matter": front_matter, "headings": heads, "lines": total, "chunker": MD_CHUNKER_ID}


def file_chunks(
    relative_path: str,
    text: str,
    max_chars: int = CHUNK_MAX_CHARS,
    overlap_lines: int = CHUNK_OVERLAP_LINES,
) -> Iterator[tuple[int, int, str, list[str], int, str]]:
    """Dispatch by extension: (start, end, text, section_path, heading_line, chunker)."""
    if chunker_for_path(relative_path) == MD_CHUNKER_ID:
        for start, end, content, path, heading in _md_section_chunks(text, max_chars, overlap_lines):
            yield start, end, content, path, heading, MD_CHUNKER_ID
    else:
        for start, end, content in _line_chunks(text, max_chars, overlap_lines):
            yield start, end, content, [], 0, CHUNKER_ID


# ------------------------------------------------------- read_span / outline ---
# The Python reference keeps no copy of the bytes: it re-reads the file under
# the index root and checks the sha256 recorded at index time (the
# `retain_source: false` path of implementation section 4). Lines follow
# `str.splitlines` boundaries over the original bytes, the same lines the
# chunkers number, and a span runs from the start of `start_line` to the start
# of the line after `end_line`, so every terminator stays as written.

READ_SPAN_MAX_LINES = 400
READ_SPAN_MAX_BYTES = 256 * 1024
READ_SPAN_MAX_CONTEXT = 20
_LINE_BREAKS = "\n\x0b\x0c\r\x1c\x1d\x1e\x85\u2028\u2029"


class ReadError(ValueError):
    """A read operation refused: `code` is one of invalid_argument, not_found, capacity."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def line_starts(data: bytes) -> list[int]:
    """Byte offset of each line start, then the end offset (len(data)).

    A leading UTF-8 BOM is not part of line 1. CRLF is one terminator; every
    other `str.splitlines` boundary ends a line on its own.
    """
    offset = 3 if data.startswith(b"\xef\xbb\xbf") else 0
    text = data[offset:].decode("utf-8")
    starts: list[int] = []
    position = offset
    line_open = False
    index = 0
    while index < len(text):
        char = text[index]
        if not line_open:
            starts.append(position)
            line_open = True
        width = len(char.encode("utf-8"))
        if char in _LINE_BREAKS:
            if char == "\r" and index + 1 < len(text) and text[index + 1] == "\n":
                width += 1
                index += 1
            line_open = False
        position += width
        index += 1
    starts.append(len(data))
    return starts


def _source_bytes(index: dict, path: str) -> bytes:
    recorded = {item["path"]: item.get("sha256") for item in index.get("source_files", [])}
    if path not in recorded:
        raise ReadError("not_found", f"not indexed: {path}")
    try:
        data = (Path(index["root"]) / path).read_bytes()
    except OSError:
        raise ReadError("capacity", "source not retained") from None
    if hashlib.sha256(data).hexdigest() != recorded[path]:
        raise ReadError("not_found", "stale: file changed since indexing")
    return data


def read_span_bytes(data: bytes, start_line: int, end_line: int, context_lines: int = 0) -> dict:
    """`read_span` over one file's original bytes (implementation section 8)."""
    if not isinstance(context_lines, int) or not 0 <= context_lines <= READ_SPAN_MAX_CONTEXT:
        raise ReadError("invalid_argument", f"context_lines must be 0..{READ_SPAN_MAX_CONTEXT}")
    starts = line_starts(data)
    total = len(starts) - 1
    if start_line < 1 or end_line < start_line:
        raise ReadError("invalid_argument", "need 1 <= start_line <= end_line")
    if start_line > total:
        raise ReadError("invalid_argument", f"start_line {start_line} is past the last line {total}")
    end_line = min(end_line, total)
    first = max(1, start_line - context_lines)
    last = min(total, end_line + context_lines)
    lines = last - first + 1
    size = starts[last] - starts[first - 1]
    if lines > READ_SPAN_MAX_LINES or size > READ_SPAN_MAX_BYTES:
        raise ReadError(
            "capacity",
            f"span of {lines} lines and {size} bytes is over the {READ_SPAN_MAX_LINES}-line "
            f"or {READ_SPAN_MAX_BYTES}-byte limit",
        )
    body = data[starts[start_line - 1]:starts[end_line]]
    return {
        "start_line": start_line,
        "end_line": end_line,
        "text": body.decode("utf-8"),
        "context_before": data[starts[first - 1]:starts[start_line - 1]].decode("utf-8"),
        "context_after": data[starts[end_line]:starts[last]].decode("utf-8"),
        "byte_exact": True,
        "sha256": hashlib.sha256(body).hexdigest(),
    }


def read_span(index: dict, path: str, start_line: int, end_line: int, context_lines: int = 0) -> dict:
    return read_span_bytes(_source_bytes(index, path), start_line, end_line, context_lines)


def outline_bytes(path: str, data: bytes) -> dict:
    text = data.decode("utf-8")
    if chunker_for_path(path) == MD_CHUNKER_ID:
        return markdown_outline(text)
    return {"front_matter": None, "headings": [], "lines": len(line_starts(data)) - 1,
            "chunker": CHUNKER_ID}


def outline(index: dict, path: str) -> dict:
    return outline_bytes(path, _source_bytes(index, path))


def _provider_vectors(
    provider: EmbeddingProvider,
    texts: list[str],
    *,
    purpose: str,
    expected_dimensions: int,
) -> list[list[float]]:
    raw = provider.embed_documents(texts) if purpose == "documents" else provider.embed_queries(texts)
    if len(raw) != len(texts):
        raise ProviderMismatch(
            f"embedding provider returned {len(raw)} vectors for {len(texts)} {purpose}"
        )
    vectors = []
    for vector in raw:
        if len(vector) != expected_dimensions:
            raise ProviderMismatch(
                f"embedding provider returned {len(vector)} dimensions; expected {expected_dimensions}"
            )
        values = [float(value) for value in vector]
        if any(not math.isfinite(value) for value in values):
            raise ProviderMismatch("embedding provider returned a non-finite value")
        vectors.append(_normalize_vector(values))
    return vectors


def build_index(
    root: Path,
    *,
    vector_mode: str = "none",
    embedding_provider: EmbeddingProvider | None = None,
    access_rules: list[dict] | None = None,
    previous_index: dict | None = None,
) -> dict:
    root = root.expanduser().resolve()
    if not root.is_dir():
        raise ValueError(f"knowledge root is not a directory: {root}")
    if vector_mode not in {"none", "hash", "cooccurrence", "neural"}:
        raise ValueError("vector_mode must be 'none', 'hash', 'cooccurrence', or 'neural'")
    if (vector_mode == "neural") != (embedding_provider is not None):
        raise ValueError("neural vector mode requires exactly one embedding provider")

    chunking = {
        "id": CHUNKER_ID,
        "max_chars": CHUNK_MAX_CHARS,
        "overlap_lines": CHUNK_OVERLAP_LINES,
        # S3-T1: Markdown files use md-section-v1 with the same parameters.
        "markdown": {"id": MD_CHUNKER_ID, "front_matter": "yaml-v1"},
    }
    if previous_index is not None:
        if previous_index.get("root") != str(root):
            raise ValueError("incremental index root does not match the current root")
        if previous_index.get("vector_mode", "none") != vector_mode:
            raise ValueError("incremental index vector mode does not match")
        if previous_index.get("chunking") != chunking:
            raise ValueError("incremental index chunker contract does not match")
        if not isinstance(previous_index.get("source_files"), list):
            raise ValueError("incremental index has no source-file hash metadata")
        if vector_mode == "neural":
            assert embedding_provider is not None
            previous_embedding = previous_index.get("embedding") or {}
            provider_metadata = embedding_provider.metadata
            if (
                previous_embedding.get("model_id") != provider_metadata.get("model_id")
                or previous_embedding.get("dimensions") != provider_metadata.get("dimensions")
            ):
                raise ProviderMismatch("incremental embedding provider does not match previous index")

    chunks: list[Chunk] = []
    skipped: list[dict[str, str]] = []
    source_files: list[dict[str, str]] = []
    previous_files = {
        item["path"]: item
        for item in (previous_index or {}).get("source_files", [])
        if isinstance(item, dict) and isinstance(item.get("path"), str)
    }
    previous_chunks: dict[str, list[dict]] = defaultdict(list)
    for chunk in (previous_index or {}).get("chunks", []):
        previous_chunks[chunk["path"]].append(chunk)
    seen_paths: set[str] = set()
    reused_files = 0
    reused_chunks = 0
    relabeled_chunks = 0
    added_files = 0
    changed_files = 0
    stale_files = 0
    for path in _iter_text_files(root):
        relative_path = path.relative_to(root).as_posix()
        seen_paths.add(relative_path)
        try:
            content_bytes = path.read_bytes()
            text = content_bytes.decode("utf-8")
        except (UnicodeDecodeError, OSError) as exc:
            skipped.append({"path": relative_path, "reason": str(exc)})
            if relative_path in previous_files:
                stale_files += 1
                source_files.append(dict(previous_files[relative_path]))
                labels = required_labels_for_path(relative_path, access_rules)
                for saved in previous_chunks[relative_path]:
                    if saved.get("required_labels", []) != labels:
                        relabeled_chunks += 1
                    chunks.append(
                        Chunk(
                            id=saved["id"],
                            path=saved["path"],
                            start_line=saved["start_line"],
                            end_line=saved["end_line"],
                            text=saved["text"],
                            terms=dict(saved["terms"]),
                            length=saved["length"],
                            vector=saved.get("vector"),
                            required_labels=labels,
                            section_path=list(saved.get("section_path", [])),
                            heading_line=saved.get("heading_line", 0),
                            chunker=saved.get("chunker", CHUNKER_ID),
                        )
                    )
                    reused_chunks += 1
            continue
        content_hash = hashlib.sha256(content_bytes).hexdigest()
        source_files.append({"path": relative_path, "sha256": content_hash})
        previous_file = previous_files.get(relative_path)
        labels = required_labels_for_path(relative_path, access_rules)
        if previous_file is not None and previous_file.get("sha256") == content_hash:
            reused_files += 1
            for saved in previous_chunks[relative_path]:
                if saved.get("required_labels", []) != labels:
                    relabeled_chunks += 1
                chunks.append(
                    Chunk(
                        id=saved["id"],
                        path=saved["path"],
                        start_line=saved["start_line"],
                        end_line=saved["end_line"],
                        text=saved["text"],
                        terms=dict(saved["terms"]),
                        length=saved["length"],
                        vector=saved.get("vector"),
                        required_labels=labels,
                        section_path=list(saved.get("section_path", [])),
                        heading_line=saved.get("heading_line", 0),
                        chunker=saved.get("chunker", CHUNKER_ID),
                    )
                )
                reused_chunks += 1
            continue
        if previous_file is None:
            added_files += 1
        else:
            changed_files += 1
        for start_line, end_line, content, section_path, heading_line, chunker in file_chunks(
            relative_path, text
        ):
            tokens = tokenize(content)
            if not tokens:
                continue
            terms = dict(Counter(tokens))
            vector = _hash_vector(tokens) if vector_mode == "hash" else None
            chunks.append(
                Chunk(
                    id=_chunk_id(relative_path, start_line, end_line, content),
                    path=relative_path,
                    start_line=start_line,
                    end_line=end_line,
                    text=content,
                    terms=terms,
                    length=len(tokens),
                    vector=vector,
                    required_labels=labels,
                    section_path=section_path,
                    heading_line=heading_line,
                    chunker=chunker,
                )
            )

    source_files.sort(key=lambda item: item["path"])
    deleted_paths = sorted(set(previous_files) - seen_paths)
    corpus_changed = previous_index is None or bool(added_files or changed_files or deleted_paths)

    vector_model = None
    if vector_mode == "cooccurrence":
        if previous_index is not None and not corpus_changed:
            vector_model = previous_index["vector_model"]
        else:
            tokenized_chunks = [tokenize(chunk.text) for chunk in chunks]
            vector_model = _fit_cooccurrence_model(tokenized_chunks)
            chunks = [
                replace(chunk, vector=_cooccurrence_vector(tokens, vector_model))
                for chunk, tokens in zip(chunks, tokenized_chunks)
            ]
    elif vector_mode == "neural":
        assert embedding_provider is not None
        provider_metadata = embedding_provider.metadata
        dimensions = provider_metadata.get("dimensions")
        if isinstance(dimensions, bool) or not isinstance(dimensions, int) or dimensions < 1:
            raise ProviderMismatch("embedding provider metadata has invalid dimensions")
        pending_indexes = [index for index, chunk in enumerate(chunks) if chunk.vector is None]
        if pending_indexes:
            vectors = _provider_vectors(
                embedding_provider,
                [chunks[index].text for index in pending_indexes],
                purpose="documents",
                expected_dimensions=dimensions,
            )
            for chunk_index, vector in zip(pending_indexes, vectors):
                chunks[chunk_index] = replace(chunks[chunk_index], vector=vector)
    else:
        pending_indexes = []

    embedding_metadata = None
    if vector_mode == "hash":
        embedding_metadata = {
            "model_id": "hash-projection-v1",
            "type": "mechanical_test",
            "dimensions": 128,
            "semantic": False,
        }
    elif vector_model is not None:
        embedding_metadata = {
            "model_id": vector_model["model_id"],
            "model_family": vector_model["model_family"],
            "type": "distributional",
            "dimensions": vector_model["dimensions"],
            "semantic": True,
            "window": vector_model["window"],
            "max_terms": MAX_COOCCURRENCE_TERMS,
        }
    elif vector_mode == "neural":
        assert embedding_provider is not None
        embedding_metadata = embedding_provider.metadata

    index = {
        "version": INDEX_VERSION,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "root": str(root),
        "vector_mode": vector_mode,
        "embedding": embedding_metadata,
        "access": {"semantics": ACCESS_SEMANTICS},
        "chunking": chunking,
        "source_files": source_files,
        "stats": {
            "files": len(source_files),
            "chunks": len(chunks),
            "skipped": skipped,
            "incremental": {
                "enabled": previous_index is not None,
                "corpus_changed": corpus_changed,
                "reused_files": reused_files,
                "reused_chunks": reused_chunks,
                "relabeled_chunks": relabeled_chunks,
                "added_files": added_files,
                "changed_files": changed_files,
                "deleted_files": len(deleted_paths),
                "stale_files": stale_files,
                "embedded_chunks": (
                    len(chunks)
                    if vector_mode == "cooccurrence" and corpus_changed
                    else len(pending_indexes)
                    if vector_mode == "neural"
                    else 0
                ),
            },
        },
        "chunks": [asdict(chunk) for chunk in chunks],
    }
    if vector_model is not None:
        index["vector_model"] = vector_model
    return index


def save_index(index: dict, output: Path) -> None:
    output = output.expanduser()
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    temporary.write_text(json.dumps(index, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    temporary.replace(output)


def load_index(path: Path) -> dict:
    index = json.loads(path.expanduser().read_text(encoding="utf-8"))
    if index.get("version") != INDEX_VERSION:
        raise ValueError(f"unsupported index version: {index.get('version')!r}")
    if index.get("vector_mode") == "cooccurrence":
        model = index.get("vector_model")
        embedding = index.get("embedding")
        if not isinstance(model, dict) or not isinstance(embedding, dict):
            raise ValueError("cooccurrence index is missing model metadata")
        model["model_family"] = model.get("model_family", "cooccurrence-ppmi-v1")
        model["model_id"] = _cooccurrence_model_id(model)
        embedding["model_family"] = model["model_family"]
        embedding["model_id"] = model["model_id"]
    for chunk in index.get("chunks", []):
        chunk["required_labels"] = sorted(set(chunk.get("required_labels", [])))
    index.setdefault("access", {"semantics": ACCESS_SEMANTICS})
    return index


def _bm25_scores(chunks: list[dict], query_terms: list[str]) -> dict[str, float]:
    if not chunks or not query_terms:
        return {}
    document_frequency: Counter[str] = Counter()
    for chunk in chunks:
        document_frequency.update(chunk["terms"].keys())
    average_length = sum(chunk["length"] for chunk in chunks) / len(chunks)
    scores: dict[str, float] = defaultdict(float)
    k1, b = 1.2, 0.75
    for chunk in chunks:
        for term in set(query_terms):
            frequency = chunk["terms"].get(term, 0)
            if not frequency:
                continue
            df = document_frequency[term]
            idf = math.log(1.0 + (len(chunks) - df + 0.5) / (df + 0.5))
            denominator = frequency + k1 * (1.0 - b + b * chunk["length"] / average_length)
            scores[chunk["id"]] += idf * (frequency * (k1 + 1.0) / denominator)
    return dict(scores)


def embed_query(
    index: dict,
    query: str,
    embedding_provider: EmbeddingProvider | None = None,
) -> list[float]:
    query_terms = tokenize(query)
    if not query_terms:
        return []
    vector_mode = index.get("vector_mode", "none")
    if vector_mode == "hash":
        return _hash_vector(query_terms)
    elif vector_mode == "cooccurrence":
        return _cooccurrence_vector(query_terms, index["vector_model"])
    elif vector_mode == "neural":
        if embedding_provider is None:
            raise ProviderMismatch("neural query requires the index's embedding provider")
        embedding = index.get("embedding") or {}
        provider_metadata = embedding_provider.metadata
        if (
            provider_metadata.get("model_id") != embedding.get("model_id")
            or provider_metadata.get("dimensions") != embedding.get("dimensions")
        ):
            raise ProviderMismatch("query embedding provider does not match the index")
        return _provider_vectors(
            embedding_provider,
            [query],
            purpose="queries",
            expected_dimensions=embedding["dimensions"],
        )[0]
    return []


def _cosine_scores(
    index: dict,
    chunks: list[dict],
    query: str,
    embedding_provider: EmbeddingProvider | None,
) -> dict[str, float]:
    if not tokenize(query):
        return {}
    query_vector = embed_query(index, query, embedding_provider)
    if not any(query_vector):
        return {}
    return {
        chunk["id"]: sum(left * right for left, right in zip(query_vector, chunk["vector"]))
        for chunk in chunks
        if chunk.get("vector") is not None
    }


def _ranks(scores: dict[str, float], *, positive_only: bool = False) -> dict[str, int]:
    ordered = sorted(
        ((identifier, score) for identifier, score in scores.items() if not positive_only or score > 0.0),
        key=lambda item: (-item[1], item[0]),
    )
    return {identifier: rank for rank, (identifier, _) in enumerate(ordered, start=1)}


def search(
    index: dict,
    query: str,
    *,
    top_k: int = 5,
    candidate_k: int = 100,
    path_prefix: str | None = None,
    retrieval_mode: str = "hybrid",
    embedding_provider: EmbeddingProvider | None = None,
    principal_labels: Iterable[str] = (),
) -> list[dict]:
    if top_k < 1:
        raise ValueError("top_k must be at least 1")
    if candidate_k < top_k:
        raise ValueError("candidate_k must be at least top_k")
    if not isinstance(retrieval_mode, str) or retrieval_mode not in {"lexical", "vector", "hybrid"}:
        raise ValueError("retrieval_mode must be 'lexical', 'vector', or 'hybrid'")
    query_terms = tokenize(query)
    if not query_terms:
        return []
    principal_labels = tuple(principal_labels)
    chunks = [
        chunk
        for chunk in index["chunks"]
        if (path_prefix is None or chunk["path"].startswith(path_prefix))
        and is_authorized(chunk.get("required_labels", []), principal_labels)
    ]
    lexical_scores = _bm25_scores(chunks, query_terms) if retrieval_mode != "vector" else {}
    vector_scores = (
        _cosine_scores(index, chunks, query, embedding_provider)
        if retrieval_mode != "lexical"
        else {}
    )
    lexical_ranks = _ranks(lexical_scores, positive_only=True)
    vector_ranks = _ranks(vector_scores, positive_only=True)
    lexical_ranks = {identifier: rank for identifier, rank in lexical_ranks.items() if rank <= candidate_k}
    vector_ranks = {identifier: rank for identifier, rank in vector_ranks.items() if rank <= candidate_k}

    # Reciprocal-rank fusion is stable even when component score scales differ.
    fused: dict[str, float] = defaultdict(float)
    for identifier, rank in lexical_ranks.items():
        fused[identifier] += 1.0 / (60.0 + rank)
    for identifier, rank in vector_ranks.items():
        fused[identifier] += 1.0 / (60.0 + rank)

    by_id = {chunk["id"]: chunk for chunk in chunks}
    results = []
    for identifier, fused_score in sorted(fused.items(), key=lambda item: (-item[1], item[0]))[:top_k]:
        chunk = by_id[identifier]
        results.append(
            {
                "chunk_id": identifier,
                "citation": {
                    "path": chunk["path"],
                    "start_line": chunk["start_line"],
                    "end_line": chunk["end_line"],
                },
                "content": chunk["text"],
                "score": fused_score,
                "ranking": {
                    "lexical": {
                        "rank": lexical_ranks.get(identifier),
                        "score": lexical_scores.get(identifier),
                    },
                    "vector": {
                        "rank": vector_ranks.get(identifier),
                        "score": vector_scores.get(identifier),
                        "mode": index.get("vector_mode", "none"),
                    },
                },
            }
        )
    return results


def context_envelope(
    index: dict,
    query: str,
    *,
    top_k: int = 5,
    candidate_k: int = 100,
    path_prefix: str | None = None,
    retrieval_mode: str = "hybrid",
    embedding_provider: EmbeddingProvider | None = None,
    principal_labels: Iterable[str] = (),
) -> dict:
    principal_labels = tuple(principal_labels)
    results = search(
        index,
        query,
        top_k=top_k,
        candidate_k=candidate_k,
        path_prefix=path_prefix,
        retrieval_mode=retrieval_mode,
        embedding_provider=embedding_provider,
        principal_labels=principal_labels,
    )
    return {
        "tool": "search_knowledge",
        "query": query,
        "index": {"root": index["root"], "version": index["version"]},
        "retrieval": {
            "mode": retrieval_mode,
            "candidate_k": candidate_k,
            "vector_mode": index.get("vector_mode", "none"),
            "embedding": index.get("embedding"),
            "authorization": {
                "semantics": index.get("access", {}).get("semantics", ACCESS_SEMANTICS),
                "principal_label_count": len(set(principal_labels)),
            },
        },
        "results": results,
        "answer_policy": {
            "ground_in_results": True,
            "cite_path_and_lines": True,
            "say_when_evidence_is_insufficient": True,
        },
    }
