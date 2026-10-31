"""`find` (S3-T2): words, phrase and prefix modes over a Python index.

The behavioural reference for `zig/src/find.zig` (CAP-19 FR-17, FR-25;
`docs/folder-knowledge-implementation.md` section 8). The Python index keeps
no positions, so every chunk a mode needs is re-tokenized at query time with
`tokenize_positioned`: the same tokens as `core.tokenize`, each with its
codepoint range in the chunk's text. Semantics follow the Zig core:

- `words`: every analyzed query term occurs in the chunk, BM25 order.
- `phrase`: the analyzed tokens are adjacent and in order within one chunk
  (non-overlapping occurrences, left to right); a quoted query forces it.
- `prefix`: earlier terms literal; the last token (a trailing `*` forces the
  mode) expands to the visible vocabulary, at most 1,000 terms, else CAPACITY.
- Overlapping chunks of one file whose every match lies in the lines they
  share with an earlier kept hit are dropped; then score desc, root_id, path,
  start_line; pages by the cursor `"<generation>:<offset>"`.

BM25 statistics are computed over the visible chunks (the reference's
existing `search` semantics); the Zig core uses the whole generation until
S3-T3 supplies visible-scope statistics, so the two agree when nothing is
hidden.
"""

from __future__ import annotations

import hashlib
import math
import unicodedata
from collections import Counter

from .access import is_authorized
from .core import TOKEN_PATTERN, VARIATION_SELECTORS, ReadError, tokenize

MODES = ("words", "phrase", "prefix")
DEFAULT_PAGE_SIZE = 20
MAX_PAGE_SIZE = 100
MAX_PREFIX_EXPANSIONS = 1_000
MAX_SNIPPET_CODEPOINTS = 240
POSITIONS_ABSENT = "re-index required: positions absent"
STALE_CURSOR = "stale cursor"
LEGACY_ROOT_ID = "r-legacy"
_HANGUL_FIRST, _HANGUL_COUNT = 0xAC00, 11172
# `str.strip()`'s set, the 29 codepoints `zig/src/chunker.zig` lists.
_WHITESPACE = {chr(cp) for cp in (
    0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x85, 0xA0, 0x1680, 0x2000, 0x2001,
    0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F,
    0x205F, 0x3000,
)}


def _inert(char: str) -> bool:
    cp = ord(char)
    return cp < 0x80 or _HANGUL_FIRST <= cp < _HANGUL_FIRST + _HANGUL_COUNT


def normalize_mapped(text: str) -> tuple[str, list[int], list[int]]:
    """NFC of `text` with, per output codepoint, the input range it came from.

    Regions as `zig/src/nfc.zig`: an inert codepoint (ASCII or a precomposed
    Hangul syllable) before a run of non-inert ones, up to the next inert
    codepoint. A region NFC leaves unchanged maps one to one; a changed region
    maps every output codepoint to the whole region.
    """
    out: list[str] = []
    starts: list[int] = []
    ends: list[int] = []
    i, n = 0, len(text)
    while i < n:
        if _inert(text[i]) and not (i + 1 < n and not _inert(text[i + 1])):
            out.append(text[i])
            starts.append(i)
            ends.append(i + 1)
            i += 1
            continue
        j = i + 1
        while j < n and not _inert(text[j]):
            j += 1
        region = text[i:j]
        normalized = unicodedata.normalize("NFC", region)
        same = normalized == region
        for k, char in enumerate(normalized):
            out.append(char)
            starts.append(i + k if same else i)
            ends.append(i + k + 1 if same else j)
        i = j
    return "".join(out), starts, ends


def tokenize_positioned(text: str) -> list[tuple[str, int, int]]:
    """`core.tokenize`'s tokens, each as (term, start, length) in codepoints of `text`."""
    normalized, starts, ends = normalize_mapped(text)
    kept = [k for k, char in enumerate(normalized) if not VARIATION_SELECTORS.match(char)]
    view = "".join(normalized[k] for k in kept)
    tokens = []
    for match in TOKEN_PATTERN.finditer(view):
        indexes = kept[match.start():match.end()]
        start = min(starts[k] for k in indexes)
        end = max(ends[k] for k in indexes)
        tokens.append((match.group().casefold(), start, end - start))
    return tokens


def _parse_query(query: str, mode: str) -> tuple[str, str]:
    trimmed = query.strip(" \t\r\n")
    if len(trimmed) >= 2 and trimmed[0] == '"' and trimmed[-1] == '"':
        return "phrase", trimmed[1:-1]
    text = trimmed
    if text.endswith("*"):
        mode = "prefix"
        text = text[:-1]
    if "*" in text:
        raise ReadError("invalid_argument", "only the last token may end in *")
    return mode, text


def index_generation(index: dict) -> int:
    """The generation a cursor is bound to: the index's own, or a digest of its chunk ids."""
    if isinstance(index.get("generation"), int):
        return index["generation"]
    digest = hashlib.sha256("\n".join(chunk["id"] for chunk in index["chunks"]).encode("utf-8"))
    return int(digest.hexdigest()[:12], 16)


def split_root(path: str, root_ids: list[str] | tuple[str, ...]) -> tuple[str, str]:
    for root_id in root_ids:
        if path.startswith(root_id + "/") and len(path) > len(root_id) + 1:
            return root_id, path[len(root_id) + 1:]
    return (root_ids[0] if root_ids else LEGACY_ROOT_ID), path


def _strip(line: str) -> str:
    start, end = 0, len(line)
    while start < end and line[start] in _WHITESPACE:
        start += 1
    while end > start and line[end - 1] in _WHITESPACE:
        end -= 1
    return line[start:end]


def shared_lines(a: str, b: str, bound: int) -> int:
    """Leading lines of chunk `b` that are the trailing lines of chunk `a` (see find.zig)."""
    a_lines, b_lines = a.split("\n"), b.split("\n")
    for j in range(min(bound, len(a_lines), len(b_lines)), 0, -1):
        if all(_strip(x) == _strip(y) for x, y in zip(a_lines[len(a_lines) - j:], b_lines[:j])):
            return j
    return 0


def _line_of(text: str, end: int) -> int:
    """0-based line of the codepoint just before `end`."""
    return text.count("\n", 0, max(end - 1, 0))


def _snippet(text: str, spans: list[tuple[int, int]], ranges: list[list[int]], keys: list[int]) -> tuple[int, int]:
    total = len(text)
    if total <= MAX_SNIPPET_CODEPOINTS:
        return 0, total
    window_start = window_end = 0
    if ranges:
        best = (0, 0, 0, 0)  # first, last, distinct, count
        for first in range(len(ranges)):
            seen: list[int] = []
            last = first
            k = first
            while k < len(ranges) and ranges[k][1] - ranges[first][0] <= MAX_SNIPPET_CODEPOINTS:
                if keys[k] not in seen:
                    seen.append(keys[k])
                last = k
                k += 1
            count = k - first if k > first else 1
            distinct = max(len(seen), 1)
            if distinct > best[2] or (distinct == best[2] and count > best[3]):
                best = (first, last, distinct, count)
        window_start = ranges[best[0]][0]
        window_end = max(ranges[best[1]][1], ranges[best[0]][1])
        if window_end - window_start > MAX_SNIPPET_CODEPOINTS:
            window_end = window_start + MAX_SNIPPET_CODEPOINTS
    slack = MAX_SNIPPET_CODEPOINTS - (window_end - window_start)
    left = slack // 2
    right = slack - left
    if left > window_start:
        right += left - window_start
        left = window_start
    if window_end + right > total:
        spare = window_end + right - total
        right = total - window_end
        left = min(window_start, left + spare)
    start = window_start - left
    end = window_end + right
    if start > 0:
        snapped = window_start
        for span_start, _ in spans:
            if span_start >= start:
                snapped = min(span_start, window_start)
                break
        start = snapped
    if end < total:
        snapped = window_end
        for span_start, length in reversed(spans):
            if span_start + length <= end:
                snapped = max(span_start + length, window_end)
                break
        end = min(snapped, start + MAX_SNIPPET_CODEPOINTS)
    return start, end


def _bm25(chunk: dict, terms: list[str], df: Counter, count: int, average: float) -> float:
    score = 0.0
    k1, b = 1.2, 0.75
    for term in terms:
        frequency = chunk["terms"].get(term, 0)
        if not frequency:
            continue
        idf = math.log(1.0 + (count - df[term] + 0.5) / (df[term] + 0.5))
        score += idf * (frequency * (k1 + 1.0) / (frequency + k1 * (1.0 - b + b * chunk["length"] / average)))
    return score


def find(
    index: dict,
    query: str,
    *,
    mode: str = "words",
    path_prefix: str | None = None,
    principal_labels=(),
    page_size: int = DEFAULT_PAGE_SIZE,
    cursor: str | None = None,
    root_ids: list[str] | tuple[str, ...] = (LEGACY_ROOT_ID,),
    positions: bool = True,
) -> dict:
    """Section 8's `find`. Raises `ReadError` (`invalid_argument` or `capacity`).

    `positions=False` answers as a generation without positions does
    (phrase is `CAPACITY`), for parity with a `HYBLEX01` Zig index.
    """
    if mode not in MODES:
        raise ReadError("invalid_argument", f"mode must be one of {', '.join(MODES)}")
    if not isinstance(page_size, int) or not 1 <= page_size <= MAX_PAGE_SIZE:
        raise ReadError("invalid_argument", f"page_size must be 1..{MAX_PAGE_SIZE}")
    generation = index_generation(index)
    offset = 0
    if cursor is not None:
        head, colon, tail = cursor.partition(":")
        if not colon or not head.isdigit() or not tail.isdigit():
            raise ReadError("invalid_argument", "malformed cursor")
        if int(head) != generation:
            raise ReadError("invalid_argument", STALE_CURSOR)
        offset = int(tail)
    effective, text = _parse_query(query, mode)
    tokens = tokenize(text)
    if not tokens:
        raise ReadError("invalid_argument", "empty query")
    if effective == "phrase" and not positions:
        raise ReadError("capacity", POSITIONS_ABSENT)

    principal_labels = tuple(principal_labels)
    visible = [
        chunk for chunk in index["chunks"]
        if (path_prefix is None or chunk["path"].startswith(path_prefix))
        and is_authorized(chunk.get("required_labels", []), principal_labels)
    ]
    df: Counter = Counter()
    for chunk in visible:
        df.update(chunk["terms"].keys())
    count = len(visible)
    average = sum(chunk["length"] for chunk in visible) / count if count else 0.0

    unique = list(dict.fromkeys(tokens))
    highlight: list[str]
    if effective == "prefix":
        earlier = list(dict.fromkeys(tokens[:-1]))
        prefix = tokens[-1]
        expansions = sorted(term for term in df if term.startswith(prefix))
        if len(expansions) > MAX_PREFIX_EXPANSIONS:
            raise ReadError("capacity", f'prefix "{prefix}" expands to more than {MAX_PREFIX_EXPANSIONS} terms')
        highlight = earlier + expansions
        expansion_set = set(expansions)
        candidates = [
            chunk for chunk in visible
            if expansions and all(term in chunk["terms"] for term in earlier)
            and any(term in expansion_set for term in chunk["terms"])
        ]
        scored_terms = earlier + expansions
    else:
        highlight = unique
        candidates = [chunk for chunk in visible if all(term in chunk["terms"] for term in unique)]
        scored_terms = unique

    key_of = {term: slot for slot, term in enumerate(highlight)}
    hits = []
    for chunk in candidates:
        positioned = tokenize_positioned(chunk["text"])
        if effective == "phrase":
            matches = []
            next_free = 0
            for start in range(len(positioned) - len(tokens) + 1):
                if start < next_free:
                    continue
                if all(positioned[start + i][0] == tokens[i] for i in range(len(tokens))):
                    matches.append((start, start + len(tokens) - 1, 0))
                    next_free = start + len(tokens)
            if not matches:
                continue
        else:
            matches = [(i, i, key_of[term]) for i, (term, _, _) in enumerate(positioned) if term in key_of]
        root_id, path = split_root(chunk["path"], root_ids)
        hits.append({
            "chunk": chunk, "positioned": positioned, "matches": matches,
            "score": _bm25(chunk, scored_terms, df, count, average), "root_id": root_id, "path": path,
            "kept": True,
        })

    # Overlap deduplication to the earlier chunk.
    by_file = sorted(hits, key=lambda h: (h["chunk"]["path"], h["chunk"]["start_line"]))
    for position, later in enumerate(by_file):
        earlier_hits = [h for h in by_file[:position] if h["chunk"]["path"] == later["chunk"]["path"]]
        if not earlier_hits:
            continue
        b = later["chunk"]
        all_shared = bool(later["matches"])
        for first, last, _ in later["matches"]:
            _, start, length = later["positioned"][last]
            line = _line_of(b["text"], start + length)
            shared = False
            for hit in earlier_hits:
                a = hit["chunk"]
                if not hit["kept"] or a["end_line"] < b["start_line"]:
                    continue
                if line < shared_lines(a["text"], b["text"], a["end_line"] - b["start_line"] + 1):
                    shared = True
                    break
            if not shared:
                all_shared = False
                break
        if all_shared:
            later["kept"] = False

    kept = [h for h in hits if h["kept"]]
    kept.sort(key=lambda h: (-h["score"], h["root_id"], h["path"], h["chunk"]["start_line"]))
    total = len(kept)
    page_start = min(offset, total)
    page_end = min(page_start + page_size, total)
    page = []
    for hit in kept[page_start:page_end]:
        chunk, positioned = hit["chunk"], hit["positioned"]
        ranges = [[positioned[first][1], positioned[last][1] + positioned[last][2]] for first, last, _ in hit["matches"]]
        keys = [key for _, _, key in hit["matches"]]
        start, end = _snippet(chunk["text"], [(s, n) for _, s, n in positioned], ranges, keys)
        page.append({
            "chunk_id": chunk["id"],
            "root_id": hit["root_id"],
            "path": hit["path"],
            "section_path": list(chunk.get("section_path", [])),
            "start_line": chunk["start_line"],
            "end_line": chunk["end_line"],
            "score": hit["score"],
            "snippet": chunk["text"][start:end],
            "snippet_start": start,
            "snippet_offsets": [[a - start, b - start] for a, b in ranges if a >= start and b <= end],
            "match_offsets": ranges,
            "content": chunk["text"],
        })
    files: dict[tuple[str, str], int] = {}
    for hit in kept:
        files[(hit["root_id"], hit["path"])] = files.get((hit["root_id"], hit["path"]), 0) + 1
    return {
        "request": {"query": query, "mode": effective, "path_prefix": path_prefix,
                    "page_size": page_size, "cursor": cursor},
        "generation": generation,
        "hits": page,
        "files": [{"root_id": r, "path": p, "hits": n} for (r, p), n in files.items()],
        "total_hits": total,
        "deduplicated": len(hits) - total,
        "exact_match": (total > 0) if effective == "phrase" else None,
        "empty": not page,
        "coverage": {
            "files": len({(h["root_id"], h["path"]) for h in page}),
            "sections": len({(h["root_id"], h["path"], tuple(h["section_path"])) for h in page}),
        },
        "truncated": False,
        "next_cursor": f"{generation}:{page_end}" if page_end < total else None,
        "pending_files": 0,
    }


def find_all(index: dict, query: str, **options) -> list[dict]:
    """Every hit of `find` across all pages (follows `next_cursor`)."""
    hits: list[dict] = []
    cursor = None
    while True:
        answer = find(index, query, cursor=cursor, **options)
        hits.extend(answer["hits"])
        cursor = answer["next_cursor"]
        if cursor is None:
            return hits
