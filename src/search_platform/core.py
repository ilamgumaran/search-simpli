from __future__ import annotations

import functools
import hashlib
import json
import math
import re
import unicodedata
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass, field, replace
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Iterable, Iterator

from ._marks import MARK_RANGES
from .access import ACCESS_SEMANTICS, is_authorized, required_labels_for_path
from .providers import EmbeddingProvider, ProviderMismatch


INDEX_VERSION = 1
FILENAME_INDEX_VERSION = 2
FILENAME_POLICY_ID = "filename-field-v1"
FILENAME_ANALYZER_ID = "analyzer-v2"
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


def simple_fold(token: str) -> str:
    """analyzer-v2's Unicode simple folding, the engine's (`analyzer_v2.zig`).

    Python exposes full case folding, so use it when it stays one code point;
    when it expands, accept a one-code-point lowercase mapping or preserve the
    original character. This keeps sharp-s, ligatures, and dotted capital I
    from expanding into multiple search terms.
    """
    out = []
    for character in token:
        folded = character.casefold()
        if len(folded) != 1:
            lowered = character.lower()
            folded = lowered if len(lowered) == 1 else character
        out.append(folded)
    return "".join(out)


def tokenize(text: str) -> list[str]:
    """The body analyzer, analyzer-v2. S5-T4 (the `ß` row of docs/tasks/S5-T4.md
    ruling 10): the body fold is the engine's simple fold, as the file-name and
    title fold always were; before S5-T4 it was full case folding, which only
    `ß` among J2's words told apart (`straße` was `strasse` here, `straße` in
    the engine)."""
    normalized = VARIATION_SELECTORS.sub("", unicodedata.normalize("NFC", text))
    return [simple_fold(token) for token in TOKEN_PATTERN.findall(normalized)]


def _filename_tokenize(text: str) -> list[str]:
    """Tokenize filename text with Unicode simple folding (analyzer-v2)."""
    normalized = VARIATION_SELECTORS.sub("", unicodedata.normalize("NFC", text))
    return [simple_fold(token) for token in TOKEN_PATTERN.findall(normalized)]


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
    filename_index: bool = False,
) -> dict:
    root = root.expanduser().resolve()
    if not root.is_dir():
        raise ValueError(f"knowledge root is not a directory: {root}")
    if vector_mode not in {"none", "hash", "cooccurrence", "neural"}:
        raise ValueError("vector_mode must be 'none', 'hash', 'cooccurrence', or 'neural'")
    if (vector_mode == "neural") != (embedding_provider is not None):
        raise ValueError("neural vector mode requires exactly one embedding provider")
    if not isinstance(filename_index, bool):
        raise ValueError("filename_index must be a boolean")

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
        if bool(previous_index.get("filename_index")) != filename_index:
            raise ValueError("incremental index filename-index setting does not match; clean rebuild required")
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
        "version": FILENAME_INDEX_VERSION if filename_index else INDEX_VERSION,
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
    if filename_index:
        grouped: dict[str, list[dict]] = defaultdict(list)
        for chunk in index["chunks"]:
            grouped[chunk["path"]].append(chunk)
        records = []
        for path, path_chunks in sorted(grouped.items(), key=lambda item: item[0].encode("utf-8")):
            ordered = sorted(path_chunks, key=lambda c: (c["start_line"], c["end_line"], c["id"]))
            labels = sorted(set(ordered[0].get("required_labels", [])))
            if any(sorted(set(chunk.get("required_labels", []))) != labels for chunk in ordered):
                raise ValueError(f"filename index requires consistent labels across body chunks: {path}")
            anchor = ordered[0]
            basename = Path(path).name
            suffix = Path(basename).suffix
            name = basename[:-len(suffix)] if suffix else basename
            tokens = _filename_tokenize(name)
            records.append({
                "id": path, "path": path, "name": name, "basename": basename,
                "anchor_id": anchor["id"], "start_line": anchor["start_line"],
                "end_line": anchor["end_line"], "required_labels": labels,
                "terms": dict(Counter(tokens)), "length": len(tokens),
            })
        index["filename_index"] = {
            "policy_id": FILENAME_POLICY_ID,
            "analyzer_id": FILENAME_ANALYZER_ID,
            "records": records,
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
    if index.get("version") not in {INDEX_VERSION, FILENAME_INDEX_VERSION}:
        raise ValueError(f"unsupported index version: {index.get('version')!r}")
    if index.get("version") == FILENAME_INDEX_VERSION:
        filename = index.get("filename_index")
        if (not isinstance(filename, dict) or filename.get("policy_id") != FILENAME_POLICY_ID
                or filename.get("analyzer_id") != FILENAME_ANALYZER_ID
                or not isinstance(filename.get("records"), list)):
            raise ValueError("version 2 index is missing valid filename-index metadata")
        grouped: dict[str, list[dict]] = defaultdict(list)
        for chunk in index.get("chunks", []):
            grouped[chunk["path"]].append(chunk)
        seen_paths: set[str] = set()
        for record in filename["records"]:
            path = record.get("path") if isinstance(record, dict) else None
            if not isinstance(path, str) or path in seen_paths or path not in grouped:
                raise ValueError("filename index contains a duplicate or unanchored path")
            seen_paths.add(path)
            body_chunks = grouped[path]
            anchor = min(body_chunks, key=lambda c: (c["start_line"], c["end_line"], c["id"]))
            labels = sorted(set(anchor.get("required_labels", [])))
            if any(sorted(set(chunk.get("required_labels", []))) != labels for chunk in body_chunks):
                raise ValueError(f"filename index body chunks have inconsistent labels: {path}")
            basename = Path(path).name
            suffix = Path(basename).suffix
            name = basename[:-len(suffix)] if suffix else basename
            if (record.get("id") != path or record.get("basename") != basename or record.get("name") != name
                    or record.get("anchor_id") != anchor["id"]
                    or record.get("start_line") != anchor["start_line"]
                    or record.get("end_line") != anchor["end_line"]
                    or record.get("required_labels") != labels
                    or record.get("terms") != dict(Counter(_filename_tokenize(name)))
                    or record.get("length") != len(_filename_tokenize(name))):
                raise ValueError(f"filename index record does not match its body anchor: {path}")
        if seen_paths != set(grouped):
            raise ValueError("filename index catalog is missing body-backed paths")
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


def _bm25_scores(chunks: list[dict], query_terms: list[str],
                 groups: dict[str, tuple[tuple[str, float], ...]] | None = None) -> dict[str, float]:
    """BM25 over `chunks` (their own document frequencies and average length).

    `groups` (fuzzy-v1, S5-T3) maps a query term to the expansions it is searched
    as, each with its weight: in each chunk the term then contributes the best
    member's weight * BM25, every member at one shared document frequency (the
    largest of theirs). A query with no group runs the arithmetic of before S5-T3."""
    if not chunks or not query_terms:
        return {}
    document_frequency: Counter[str] = Counter()
    for chunk in chunks:
        document_frequency.update(chunk["terms"].keys())
    average_length = sum(chunk["length"] for chunk in chunks) / len(chunks)
    scores: dict[str, float] = defaultdict(float)
    k1, b = 1.2, 0.75
    active = {term: groups[term] for term in set(query_terms) if term in groups} if groups else {}
    if not active:
        for chunk in chunks:
            for term in sorted(set(query_terms)):
                frequency = chunk["terms"].get(term, 0)
                if not frequency:
                    continue
                df = document_frequency[term]
                idf = math.log(1.0 + (len(chunks) - df + 0.5) / (df + 0.5))
                denominator = frequency + k1 * (1.0 - b + b * chunk["length"] / average_length)
                scores[chunk["id"]] += idf * (frequency * (k1 + 1.0) / denominator)
        return dict(scores)
    shared = {term: max(document_frequency.get(member, 0) for member, _ in members) for term, members in active.items()}
    for chunk in chunks:
        for term in sorted(set(query_terms)):
            members = active.get(term)
            if members is None:
                frequency = chunk["terms"].get(term, 0)
                if not frequency:
                    continue
                df = document_frequency[term]
                idf = math.log(1.0 + (len(chunks) - df + 0.5) / (df + 0.5))
                denominator = frequency + k1 * (1.0 - b + b * chunk["length"] / average_length)
                scores[chunk["id"]] += idf * (frequency * (k1 + 1.0) / denominator)
                continue
            df = shared[term]
            best = None
            for member, weight in members:
                frequency = chunk["terms"].get(member, 0)
                if not frequency:
                    continue
                idf = math.log(1.0 + (len(chunks) - df + 0.5) / (df + 0.5))
                denominator = frequency + k1 * (1.0 - b + b * chunk["length"] / average_length)
                part = weight * idf * (frequency * (k1 + 1.0) / denominator)
                if best is None or part > best:
                    best = part
            if best is not None:
                scores[chunk["id"]] += best
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


# ------------------------------------------------------------ title field ---
# S5-T2 (`title-field-v1`): a file's root-relative folder names and its stem,
# tokenized with analyzer-v2 (`_filename_tokenize`), one document per file, BM25
# over the visible files times coverage (the share of the query's distinct
# analyzer-v2 terms the field holds), times TITLE_WEIGHT. The Zig engine derives
# the same field from the documents section's record paths (zig/src/title_field.zig).

TITLE_POLICY_ID = "title-field-v1"
TITLE_WEIGHT = 2.5
TITLE_LEGACY_ROOT_ID = "r-legacy"


def _title_relative_path(path: str, root_ids: tuple[str, ...]) -> str:
    """`scope.relativePath(scope.rootOfPath(path))`: the part after `root_id/` for the
    first root that prefixes the path; a legacy-root or unrooted path is taken whole."""
    for root_id in root_ids:
        if root_id == TITLE_LEGACY_ROOT_ID:
            continue
        if len(path) > len(root_id) and path.startswith(root_id) and path[len(root_id)] == "/":
            return path[len(root_id) + 1:]
    return path


@functools.lru_cache(maxsize=65536)
def _title_tokens(path: str, root_ids: tuple[str, ...]) -> tuple[str, ...]:
    """The title field's tokens: every folder name of the root-relative path (never
    the root id), then the stem (Python's `Path.stem`: the last component without
    its final `.ext`; a name whose only dot is its first character is kept whole)."""
    parts = _title_relative_path(path, root_ids).split("/")
    tokens: list[str] = []
    for folder in parts[:-1]:
        tokens.extend(_filename_tokenize(folder))
    tokens.extend(_filename_tokenize(PurePosixPath(parts[-1]).stem if parts[-1] else ""))
    return tuple(tokens)


def _title_root_ids(index: dict, title_root_ids: Iterable[str] | None) -> tuple[str, ...]:
    roots = index.get("roots")
    if isinstance(roots, dict):
        return tuple(roots)
    if isinstance(roots, list):
        return tuple(r["root_id"] if isinstance(r, dict) else r for r in roots)
    return tuple(title_root_ids or ())


def _title_fields(visible_chunks: list[dict], root_ids: tuple[str, ...]) -> dict[str, tuple[str, ...]]:
    fields: dict[str, tuple[str, ...]] = {}
    for chunk in visible_chunks:
        if chunk["path"] not in fields:
            fields[chunk["path"]] = _title_tokens(chunk["path"], root_ids)
    return fields


def _title_scores(visible_chunks: list[dict], query: str, root_ids: tuple[str, ...],
                  weight: float, groups: dict[str, tuple[tuple[str, float], ...]] | None = None) -> dict[str, float]:
    """The weighted title part per file path: weight * BM25_title * coverage, over the
    files of `visible_chunks` (the statistics: labels narrow them, a path prefix does not).
    With fuzzy-v1 `groups`, a grouped term scores as its best held member at the
    members' largest title document frequency, and counts as covered when the field
    holds any member."""
    terms = sorted(set(_filename_tokenize(query)))
    if not terms or not weight:
        return {}
    fields = _title_fields(visible_chunks, root_ids)
    docs = [{"id": path, "terms": Counter(tokens), "length": len(tokens)} for path, tokens in fields.items()]
    active = {term: groups[term] for term in terms if term in groups} if groups else {}
    out = {}
    for path, score in _bm25_scores(docs, terms, active).items():
        held = set(fields[path])
        coverage = sum(1 for term in terms if term in held
                       or any(member in held for member, _ in active.get(term, ()))) / len(terms)
        out[path] = weight * (score * coverage)
    return out


# fuzzy-v1 (S5-T3, docs/tasks/S5-T3.md ruling 2): a query term that no chunk in scope
# holds and no visible file's title field holds, all Latin script and at least
# FUZZY_MIN_CODE_POINTS long, is also searched as its nearest dictionary words. The
# candidates are the in-scope body terms (df >= 1) and the visible title terms that
# share its first code point, within an optimal-string-alignment distance of 1 (5
# code points) or 2 (6 or more), on code points; ordered by (distance, key df
# descending, UTF-8 bytes), key df the in-scope body df or 1 for a title-only term;
# the first FUZZY_MAX_EXPANSIONS kept, weighted by FUZZY_WEIGHTS. The Zig engine
# implements the same rule (zig/src/fuzzy.zig).

FUZZY_POLICY_ID = "fuzzy-v1"
FUZZY_MIN_CODE_POINTS = 5
FUZZY_DISTANCE_2_MIN_CODE_POINTS = 6
FUZZY_MAX_EXPANSIONS = 3
FUZZY_WEIGHTS = {1: 1.0, 2: 0.5}
# A digit 0-9 or a Latin letter, by code point range (not by Unicode name).
FUZZY_LATIN_RANGES = ((0x30, 0x39), (0x61, 0x7A), (0xDF, 0xF6), (0xF8, 0xFF), (0x100, 0x24F), (0x1E00, 0x1EFF))


def _fuzzy_latin(term: str) -> bool:
    return all(any(low <= ord(character) <= high for low, high in FUZZY_LATIN_RANGES) for character in term)


def _fuzzy_max_distance(term: str) -> int:
    length = len(term)
    if length >= FUZZY_DISTANCE_2_MIN_CODE_POINTS:
        return 2
    return 1 if length >= FUZZY_MIN_CODE_POINTS else 0


def _osa_within(a: str, b: str, k: int) -> int | None:
    """The optimal-string-alignment distance of two code-point strings when it is at
    most `k`, else None: a table banded to |i - j| <= k that stops when a row's
    minimum exceeds `k` (a transposition reaches row i only from a row-(i-1) cell
    no larger, so the stop is exact)."""
    la, lb = len(a), len(b)
    if abs(la - lb) > k:
        return None
    big = k + 1
    before: list[int] | None = None
    previous = [j if j <= k else big for j in range(lb + 1)]
    for i in range(1, la + 1):
        current = [big] * (lb + 1)
        if i <= k:
            current[0] = i
        row_min = current[0]
        for j in range(max(1, i - k), min(lb, i + k) + 1):
            cost = 0 if a[i - 1] == b[j - 1] else 1
            value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            if i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]:
                value = min(value, before[j - 2] + 1)
            current[j] = min(value, big)
            row_min = min(row_min, current[j])
        if row_min > k:
            return None
        before, previous = previous, current
    return previous[lb] if previous[lb] <= k else None


def _fuzzy_groups(terms: Iterable[str], body_df: Counter, title_vocabulary: set[str],
                  key_df: Counter | None = None, title_candidates: set[str] | None = None,
                  ) -> dict[str, tuple[tuple[str, float], ...]]:
    """{query term: ((member, weight), ...) best first} for each distinct term that
    triggers and has a candidate. `body_df` counts the body terms of the chunks in
    scope, path prefix included (the trigger, and a body candidate must be held
    there); `key_df` is the order's key df, over the roots and labels only (a prefix
    does not narrow statistics: S5-T3 Phase 1 deviation 8; default `body_df`);
    `title_vocabulary` is the visible files' title terms (the guard) and
    `title_candidates` those of the visible files under the prefix (default the
    same)."""
    key_df = body_df if key_df is None else key_df
    title_candidates = title_vocabulary if title_candidates is None else title_candidates
    groups: dict[str, tuple[tuple[str, float], ...]] = {}
    pool: list[tuple[str, int]] | None = None
    for term in sorted(set(terms)):
        k = _fuzzy_max_distance(term)
        if not k or body_df.get(term, 0) or not _fuzzy_latin(term) or term in title_vocabulary:
            continue
        if pool is None:
            keyed = {candidate: key_df[candidate] for candidate, df in body_df.items() if df >= 1}
            for candidate in title_candidates:
                keyed.setdefault(candidate, 1)
            pool = list(keyed.items())
        found = []
        for candidate, key_df in pool:
            if candidate[:1] != term[:1] or abs(len(candidate) - len(term)) > k:
                continue
            distance = _osa_within(term, candidate, k)
            if distance:
                found.append((distance, -key_df, candidate.encode("utf-8"), candidate))
        found.sort()
        if found:
            groups[term] = tuple((candidate, FUZZY_WEIGHTS[distance])
                                 for distance, _, _, candidate in found[:FUZZY_MAX_EXPANSIONS])
    return groups


def _fuzzy_query_groups(chunks: list[dict], visible_chunks: list[dict], terms: Iterable[str],
                        root_ids: tuple[str, ...], path_prefix: str | None = None,
                        ) -> dict[str, tuple[tuple[str, float], ...]]:
    """The query's groups, once per query, as the engine takes them: the trigger and
    body membership over the chunks in scope (`chunks`, the prefix applied), the
    order's key df over the visible chunks (a prefix narrows membership, not
    statistics), the title guard over the visible files and the title candidates over
    the visible files under the prefix."""
    terms = set(terms)
    if not any(_fuzzy_max_distance(term) for term in terms):
        return {}
    body_df: Counter[str] = Counter()
    for chunk in chunks:
        body_df.update(chunk["terms"].keys())
    key_df: Counter[str] = Counter()
    for chunk in visible_chunks:
        key_df.update(chunk["terms"].keys())
    fields = _title_fields(visible_chunks, root_ids)
    title_vocabulary = {token for tokens in fields.values() for token in tokens}
    title_candidates = {token for path, tokens in fields.items()
                        if path_prefix is None or path.startswith(path_prefix) for token in tokens}
    return _fuzzy_groups(terms, body_df, title_vocabulary, key_df, title_candidates)


def fuzzy_expansions(index: dict, query: str, *, path_prefix: str | None = None,
                     principal_labels: Iterable[str] = (), search_field: str = "content",
                     title_root_ids: Iterable[str] | None = None) -> dict[str, list[str]]:
    """The expansions `search` uses for `query` (fuzzy-v1), {typed term: [members best
    first]}: what the engine reports in its `query_term_expanded` warnings."""
    principal_labels = tuple(principal_labels)
    visible = [chunk for chunk in index["chunks"] if is_authorized(chunk.get("required_labels", []), principal_labels)]
    chunks = [chunk for chunk in visible if path_prefix is None or chunk["path"].startswith(path_prefix)]
    terms = _filename_tokenize(query) if search_field == "both" else tokenize(query) + _filename_tokenize(query)
    groups = _fuzzy_query_groups(chunks, visible, terms, _title_root_ids(index, title_root_ids), path_prefix)
    return {term: [member for member, _ in members] for term, members in groups.items()}


# fold-groups-v1 (S5-T4, docs/tasks/S5-T4.md ruling 10): on an analyzer-v2 index a
# query term is also searched as every in-scope body term and visible title term
# whose key K (`analyzer_v3.key`) equals its own, the term first, then key df
# descending, then UTF-8 bytes, each at weight 1.0, through fuzzy-v1's group
# scoring (one word, the members' largest df, the best member per chunk). A group
# is used when it is not empty and not the term alone; fuzzy-v1 runs as before on
# every term without one. As fuzzy-v1: membership is narrowed by a path prefix,
# the order's key df is not; a member held only by a label-hidden chunk is not
# used. `fold` names the parts of K applied ("FAST" is K; "" is off).

FOLD_POLICY_ID = "fold-groups-v1"


def _fold_groups(terms: Iterable[str], members_by_key: dict[str, set[str]], key_df: Counter,
                 parts: str) -> dict[str, tuple[tuple[str, float], ...]]:
    from . import analyzer_v3
    groups: dict[str, tuple[tuple[str, float], ...]] = {}
    for term in sorted(set(terms)):
        members = members_by_key.get(analyzer_v3.key(term, parts), set())
        if members and members != {term}:
            order = sorted(members, key=lambda m: (m != term, -key_df.get(m, 0), m.encode("utf-8")))
            groups[term] = tuple((member, 1.0) for member in order)
    return groups


def _query_groups(chunks: list[dict], visible_chunks: list[dict], terms: Iterable[str],
                  root_ids: tuple[str, ...], path_prefix: str | None = None, fold: str = "",
                  fuzzy: bool = True) -> dict[str, tuple[tuple[str, float], ...]]:
    """The query's groups, once per query: fold-groups-v1's (when `fold` names parts
    of K), then fuzzy-v1's for every term without one (when `fuzzy`)."""
    from . import analyzer_v3
    terms = set(terms)
    groups: dict[str, tuple[tuple[str, float], ...]] = {}
    if fold and terms:
        key_df: Counter[str] = Counter()
        for chunk in visible_chunks:
            key_df.update(chunk["terms"].keys())
        vocabulary: set[str] = set()
        for chunk in chunks:
            vocabulary.update(chunk["terms"].keys())
        for path, tokens in _title_fields(visible_chunks, root_ids).items():
            if path_prefix is None or path.startswith(path_prefix):
                vocabulary.update(tokens)
        members_by_key: dict[str, set[str]] = {}
        for word in vocabulary:
            members_by_key.setdefault(analyzer_v3.key(word, fold), set()).add(word)
        groups = _fold_groups(terms, members_by_key, key_df, fold)
    if fuzzy:
        rest = [term for term in terms if term not in groups]
        if rest:
            groups.update(_fuzzy_query_groups(chunks, visible_chunks, rest, root_ids, path_prefix))
    return groups


def fold_groups(index: dict, query: str, *, path_prefix: str | None = None,
                principal_labels: Iterable[str] = (), search_field: str = "content",
                title_root_ids: Iterable[str] | None = None, fold: str = "FAST") -> dict[str, list[str]]:
    """The fold groups `search` uses for `query` (fold-groups-v1), {term: [members in
    order]}: what the engine reports in its `query_term_grouped` warnings (with the
    term itself left out there)."""
    principal_labels = tuple(principal_labels)
    visible = [chunk for chunk in index["chunks"] if is_authorized(chunk.get("required_labels", []), principal_labels)]
    chunks = [chunk for chunk in visible if path_prefix is None or chunk["path"].startswith(path_prefix)]
    terms = _filename_tokenize(query) if search_field == "both" else tokenize(query) + _filename_tokenize(query)
    groups = _query_groups(chunks, visible, terms, _title_root_ids(index, title_root_ids), path_prefix,
                           fold=fold, fuzzy=False)
    return {term: [member for member, _ in members] for term, members in groups.items()}


def _first_chunk_key(chunk: dict) -> tuple:
    return (chunk["start_line"], chunk["end_line"], chunk["id"].encode("utf-8"))


def _add_title_to_content(chunks: list[dict], lexical_scores: dict[str, float],
                          title: dict[str, float]) -> tuple[dict[str, float], dict[str, float]]:
    """The title part goes on one chunk per file: its best body chunk (ties to the
    smaller id, bytewise), or its first chunk when no chunk of the file matches.
    Returns the lexical scores with the parts added and each receiving chunk's part."""
    if not title:
        return lexical_scores, {}
    best: dict[str, dict] = {}
    first: dict[str, dict] = {}
    for chunk in chunks:
        path = chunk["path"]
        if path not in title:
            continue
        if path not in first or _first_chunk_key(chunk) < _first_chunk_key(first[path]):
            first[path] = chunk
        score = lexical_scores.get(chunk["id"])
        if score is None:
            continue
        held = best.get(path)
        if held is None:
            best[path] = chunk
            continue
        held_score = lexical_scores[held["id"]]
        if score > held_score or (score == held_score and chunk["id"].encode("utf-8") < held["id"].encode("utf-8")):
            best[path] = chunk
    out = dict(lexical_scores)
    received: dict[str, float] = {}
    for path, part in title.items():
        if part <= 0.0 or path not in first:
            continue
        target = best.get(path, first[path])["id"]
        out[target] = out.get(target, 0.0) + part
        received[target] = part
    return out, received


def _search_filename_fields(
    index: dict,
    query: str,
    *,
    top_k: int,
    candidate_k: int,
    path_prefix: str | None,
    principal_labels: tuple[str, ...],
    search_field: str,
    title_root_ids: tuple[str, ...] = (),
    title_weight: float = TITLE_WEIGHT,
    fuzzy: bool = True,
    fold: str = "",
) -> list[dict]:
    terms = _filename_tokenize(query)
    if not terms:
        return []
    visible = [chunk for chunk in index["chunks"] if is_authorized(chunk.get("required_labels", []), principal_labels)]
    chunks = [chunk for chunk in visible if path_prefix is None or chunk["path"].startswith(path_prefix)]
    # fuzzy-v1 and fold-groups-v1: `both` shares one set of groups between its body
    # scoring and its title part; the file-name channel is never grouped.
    groups = (_query_groups(chunks, visible, terms, title_root_ids, path_prefix, fold=fold, fuzzy=fuzzy)
              if search_field == "both" else {})
    by_path: dict[str, list[dict]] = defaultdict(list)
    for chunk in chunks:
        by_path[chunk["path"]].append(chunk)
    anchors = {
        path: min(items, key=lambda c: (c["start_line"], c["end_line"], c["id"].encode("utf-8")))
        for path, items in by_path.items()
    }
    body_scores: dict[str, float] = {}
    best_by_path: dict[str, dict] = {}
    if search_field == "both":
        raw = _bm25_scores(chunks, terms, groups)
        chunk_by_id = {chunk["id"]: chunk for chunk in chunks}
        for identifier, score in raw.items():
            candidate = chunk_by_id[identifier]
            path = candidate["path"]
            previous = body_scores.get(path)
            best = best_by_path.get(path)
            if (previous is None or score > previous
                    or (score == previous and identifier.encode("utf-8") < best["id"].encode("utf-8"))):
                body_scores[path] = score
                best_by_path[path] = candidate
    body_ranks = _file_ranks(body_scores, best_by_path)

    filename_records = [
        record for record in index["filename_index"]["records"]
        if record["path"] in anchors
        and (path_prefix is None or record["path"].startswith(path_prefix))
        and is_authorized(record.get("required_labels", []), principal_labels)
    ]
    filename_scores = _bm25_scores(filename_records, terms) if search_field in {"filename", "both"} else {}
    filename_ranks = _file_ranks(filename_scores, {r["path"]: anchors[r["path"]] for r in filename_records})
    if search_field == "filename":
        body_ranks = {}
        body_scores = {}
    elif search_field == "content":
        filename_ranks = {}
        filename_scores = {}

    records_by_path = {record["path"]: record for record in filename_records}
    results = []
    if search_field == "filename":
        filename_ranks = {path: rank for path, rank in filename_ranks.items() if rank <= candidate_k}
        final_scores = {path: filename_scores[path] for path in filename_ranks}
        ordered = sorted(final_scores.items(), key=lambda item: (-item[1], item[0].encode("utf-8")))[:top_k]
    else:
        # S5-T2: `both` is a score-level merge, one result per file: its best body
        # chunk's BM25 plus the title part. The stem channel no longer ranks (it is
        # kept for matched_in, ranking.filename and match_sections), and candidate_k
        # cuts no channel before the sum.
        title = _title_scores(visible, query, title_root_ids, title_weight, groups)
        final_scores = dict(body_scores)
        for path, part in title.items():
            if part > 0.0 and path in anchors:
                final_scores[path] = final_scores.get(path, 0.0) + part
        ordered = sorted(((path, score) for path, score in final_scores.items() if score > 0.0),
                         key=lambda item: (-item[1], item[0].encode("utf-8"),
                                           best_by_path.get(item[0], anchors[item[0]])["id"].encode("utf-8")))[:top_k]
    if search_field == "both":
        # The reported ranks are positions within each channel's first candidate_k,
        # as the engine reports them; matched_in names a channel that scored the file.
        body_ranks = {path: rank for path, rank in body_ranks.items() if rank <= candidate_k}
        filename_ranks = {path: rank for path, rank in filename_ranks.items() if rank <= candidate_k}
    for path, final_score in ordered:
        chunk = best_by_path.get(path, anchors[path])
        record = records_by_path.get(path)
        matched_in = []
        if body_scores.get(path, 0.0) > 0.0:
            matched_in.append("content")
        if filename_scores.get(path, 0.0) > 0.0:
            matched_in.append("filename")
        result = {
            "chunk_id": chunk["id"],
            "citation": {"path": path, "start_line": chunk["start_line"], "end_line": chunk["end_line"]},
            "content": chunk["text"],
            "score": final_score,
            "matched_in": matched_in,
            "basename": record["basename"] if record else Path(path).name,
            "ranking": {
                "lexical": {"rank": body_ranks.get(path), "score": body_scores.get(path)},
                "filename": {"rank": filename_ranks.get(path), "score": filename_scores.get(path)},
                "vector": {"rank": None, "score": None, "mode": index.get("vector_mode", "none")},
            },
        }
        if search_field == "both":
            part = title.get(path, 0.0)
            result["ranking"]["title"] = {"score": part if part > 0.0 else None}
        filename_query_terms = list(dict.fromkeys(_filename_tokenize(query)))
        body_query_terms = list(dict.fromkeys(tokenize(query)))
        filename_available_terms = set(record["terms"]) if record else set()
        body_available_terms = set(tokenize(chunk["text"]))
        filename_matched_terms = [term for term in filename_query_terms if term in filename_available_terms]
        body_matched_terms = [term for term in body_query_terms if term in body_available_terms]
        result["match_sections"] = {
            "filename": {
                "label": "File name",
                "matched": bool(filename_matched_terms),
                "matched_terms": filename_matched_terms,
                "text": record["basename"] if record else Path(path).name,
                "citation": {"path": path, "field": "filename"},
            },
            "content": {
                "label": "Content",
                "matched": bool(body_matched_terms),
                "matched_terms": body_matched_terms,
                "text": chunk["text"],
                "citation": {
                    "path": path,
                    "field": "content",
                    "start_line": chunk["start_line"],
                    "end_line": chunk["end_line"],
                },
            },
        }
        results.append(result)
    return results


def _file_ranks(scores: dict[str, float], anchors: dict[str, dict]) -> dict[str, int]:
    ordered = sorted(
        ((path, score) for path, score in scores.items() if score > 0.0),
        key=lambda item: (-item[1], item[0].encode("utf-8"), anchors[item[0]]["id"].encode("utf-8")),
    )
    return {path: rank for rank, (path, _) in enumerate(ordered, start=1)}


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
    search_field: str = "content",
    title_root_ids: Iterable[str] | None = None,
    title_weight: float = TITLE_WEIGHT,
    fuzzy: bool = True,
    fold: str = "",
) -> list[dict]:
    """`title_root_ids` names the roots whose ids prefix the index's paths (a union of
    roots copied side by side), so the title field never takes a root id as a folder
    word; an index that carries `roots` uses its own. `title_weight` 0 is the ranking
    before S5-T2; `fuzzy` False the ranking before S5-T3 (fuzzy-v1). `fold` names
    the parts of K that fold-groups-v1 (S5-T4) applies: "FAST" is the rule, "" (the
    default in S5-T4's Phase 1) the ranking before S5-T4."""
    if top_k < 1:
        raise ValueError("top_k must be at least 1")
    if candidate_k < top_k:
        raise ValueError("candidate_k must be at least top_k")
    if not isinstance(retrieval_mode, str) or retrieval_mode not in {"lexical", "vector", "hybrid"}:
        raise ValueError("retrieval_mode must be 'lexical', 'vector', or 'hybrid'")
    if not isinstance(search_field, str) or search_field not in {"content", "filename", "both"}:
        raise ValueError("search_field must be 'content', 'filename', or 'both'")
    if search_field != "content":
        if retrieval_mode != "lexical":
            raise ValueError("filename and both search fields require retrieval_mode='lexical'")
        if not isinstance(index.get("filename_index"), dict):
            raise ValueError("FilenameIndexUnavailable: rebuild the index with --filename-index")
        return _search_filename_fields(
            index, query, top_k=top_k, candidate_k=candidate_k, path_prefix=path_prefix,
            principal_labels=tuple(principal_labels), search_field=search_field,
            title_root_ids=_title_root_ids(index, title_root_ids), title_weight=title_weight, fuzzy=fuzzy,
            fold=fold,
        )
    query_terms = tokenize(query)
    if not query_terms:
        return []
    principal_labels = tuple(principal_labels)
    visible = [chunk for chunk in index["chunks"] if is_authorized(chunk.get("required_labels", []), principal_labels)]
    chunks = [chunk for chunk in visible if path_prefix is None or chunk["path"].startswith(path_prefix)]
    root_ids = _title_root_ids(index, title_root_ids)
    # fuzzy-v1 and fold-groups-v1: the groups are computed once, for the body terms
    # and the title terms.
    groups = (_query_groups(chunks, visible, query_terms + _filename_tokenize(query), root_ids, path_prefix,
                            fold=fold, fuzzy=fuzzy)
              if retrieval_mode != "vector" else {})
    lexical_scores = _bm25_scores(chunks, query_terms, groups) if retrieval_mode != "vector" else {}
    received: dict[str, float] = {}
    if retrieval_mode != "vector":
        # S5-T2: the title part joins the lexical channel before it is ranked or cut.
        title = _title_scores(visible, query, root_ids, title_weight, groups)
        lexical_scores, received = _add_title_to_content(chunks, lexical_scores, title)
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
        if identifier in received:
            # Contract 2.3.0: only the chunk that received its file's title part.
            results[-1]["ranking"]["title"] = {"score": received[identifier]}
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
    search_field: str = "content",
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
        search_field=search_field,
    )
    retrieval = {
        "mode": retrieval_mode,
        "candidate_k": candidate_k,
        "vector_mode": index.get("vector_mode", "none"),
        "embedding": index.get("embedding"),
        "authorization": {
            "semantics": index.get("access", {}).get("semantics", ACCESS_SEMANTICS),
            "principal_label_count": len(set(principal_labels)),
        },
    }
    answer_policy = {
        "ground_in_results": True,
        "cite_path_and_lines": True,
        "say_when_evidence_is_insufficient": True,
    }
    if search_field != "content":
        retrieval["search_field"] = search_field
        retrieval["filename_policy_id"] = FILENAME_POLICY_ID
        answer_policy["filename_matches_are_navigation"] = True
    if search_field != "filename" and retrieval_mode != "vector":
        retrieval["title_policy_id"] = TITLE_POLICY_ID
        # Contract 2.4.0: the lexical channel ran under content or both.
        retrieval["fuzzy_policy_id"] = FUZZY_POLICY_ID
    return {
        "tool": "search_knowledge",
        "query": query,
        "index": {"root": index["root"], "version": index["version"]},
        "retrieval": retrieval,
        "results": results,
        "answer_policy": answer_policy,
    }
