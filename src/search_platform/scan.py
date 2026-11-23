"""`scan`, the Python reference (S6-T24, CAP-25, docs/decisions/0006-pattern-search.md).

Every line of the files in scope that holds a literal or matches a pattern, in path then line order, paged by a
cursor. The engine's `zig/src/core/pattern.zig` and `scan.zig` are the implementation; this module states the
same rules a second time so the tests can compare them:

- **The subset** (`compile`): the same grammar, refused with the same messages at the same byte offsets
  (`pattern not supported at byte <n>: <reason>`), the same program-size cap (8,192 steps, counted as the engine
  emits them).
- **Matching**: the parsed pattern is translated to a Python `re` pattern in which every class is explicit:
  `\\w` is the analyser's word code points (letters and digits by category, marks Mn and Mc, ZWNJ and ZWJ;
  not `_`), `\\d` is Nd, `\\s` is `str.isspace`, `\\b` and `whole_word` are look-arounds on that word class.
  Both engines are leftmost-first, so the spans agree.
- **Case**: `insensitive` folds the line and the pattern one code point to one (`casefold()` when it gives one
  code point, else the code point itself: the engine's `casefold_pairs`), so offsets do not move; a class
  also matches the fold of a member. `smart` is insensitive unless a code point the pattern writes changes
  under the fold.
- **Every match**: `re.finditer`'s matches; an empty match makes the line a hit and is left out of the
  offsets; only matches starting within the hit's `text` (at most 512 bytes) are listed, ends clipped.
- **Lines** are `core.line_starts`'s (`read_span`'s numbering), without their terminator.

Two sources: `scan(index, request)` over a `core.build_index` index (root `r-legacy`, the bytes read again and
checked against their recorded sha256, as `read_span` reads them) and `scan_folder(root, request)` over a
folder walked by `core`'s walk. The cursor has the engine's shape, but its request and walk parts are
SHA-256 prefixes here, not XXH3: a cursor is only ever handed back to the implementation that made it.
The budget is checked between files and every 256 lines; a single line is never interrupted here.
"""

from __future__ import annotations

import bisect
import hashlib
import json
import re
import time
import unicodedata
from pathlib import Path
from typing import Callable, Iterable

from . import core

MAX_PATTERN_BYTES = 1024
MAX_PROGRAM = 8192
MAX_REPEAT = 255
DEFAULT_PAGE_SIZE = 20
MAX_PAGE_SIZE = 100
DEFAULT_MAX_HITS_PER_FILE = 50
MAX_MAX_HITS_PER_FILE = 1000
DEFAULT_TIME_BUDGET_MS = 2000
MAX_TIME_BUDGET_MS = 30_000
MAX_CONTEXT_LINES = 20
MAX_GLOB_BYTES = 255
MAX_TEXT_BYTES = 512
LINES_PER_CHECK = 256
MAX_NAMED_ROOTS = 64
LEGACY_ROOT_ID = "r-legacy"
EMPTY_MATCH_MESSAGE = "the pattern can match the empty string, so a line can match without any match_offsets"
FIELDS = ("pattern", "mode", "case", "whole_word", "roots", "path_prefix", "name_glob", "context_lines",
          "max_hits_per_file", "page_size", "cursor", "time_budget_ms")
_LINE_BREAKS = frozenset([*range(0x0A, 0x0E), *range(0x1C, 0x1F), 0x85, 0x2028, 0x2029])
_MAX_CP = 0x110000


class ScanError(ValueError):
    """A refused request: `code` is invalid_argument or capacity, as the engine's."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def _invalid(message: str) -> ScanError:
    return ScanError("invalid_argument", message)


# ---------------------------------------------------------------- the tables ---

_TABLES: dict | None = None


def _ranges_of(predicate: Callable[[int], bool]) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    start = None
    for cp in range(_MAX_CP):
        if predicate(cp):
            if start is None:
                start = cp
        elif start is not None:
            ranges.append((start, cp - 1))
            start = None
    if start is not None:
        ranges.append((start, _MAX_CP - 1))
    return ranges


def _tables() -> dict:
    """The engine's tables from this Python's `unicodedata`, as `scripts/gen_unicode_tables.py` builds them."""
    global _TABLES
    if _TABLES is None:
        letters_digits = {"Lu", "Ll", "Lt", "Lm", "Lo", "Nd", "Nl", "No", "Mn", "Mc"}
        categories = [unicodedata.category(chr(cp)) for cp in range(_MAX_CP)]
        word = _ranges_of(lambda cp: categories[cp] in letters_digits or cp in (0x200C, 0x200D))
        digit = _ranges_of(lambda cp: categories[cp] == "Nd")
        space = _ranges_of(lambda cp: chr(cp).isspace())
        pairs = []
        for cp in range(_MAX_CP):
            folded = chr(cp).casefold()
            if len(folded) == 1 and folded != chr(cp):
                pairs.append((cp, ord(folded)))
        _TABLES = {
            "word": word,
            "digit": digit,
            "space": space,
            "pairs": pairs,
            "fold": {cp: to for cp, to in pairs},
            "translate": {cp: chr(to) for cp, to in pairs},
        }
    return _TABLES


def _in_ranges(ranges: list[tuple[int, int]], cp: int) -> bool:
    i = bisect.bisect_right(ranges, (cp, _MAX_CP)) - 1
    return i >= 0 and ranges[i][0] <= cp <= ranges[i][1]


def fold(cp: int) -> int:
    """The engine's simple fold of one code point (`pattern.fold`)."""
    return _tables()["fold"].get(cp, cp)


def is_word(cp: int) -> bool:
    return _in_ranges(_tables()["word"], cp)


def _complement(ranges: list[tuple[int, int]]) -> list[tuple[int, int]]:
    out, next_start = [], 0
    for lo, hi in ranges:
        if lo > next_start:
            out.append((next_start, lo - 1))
        next_start = hi + 1
    if next_start < _MAX_CP:
        out.append((next_start, _MAX_CP - 1))
    return out


def _merge(ranges: Iterable[tuple[int, int]]) -> list[tuple[int, int]]:
    out: list[tuple[int, int]] = []
    for lo, hi in sorted(ranges):
        if out and lo <= out[-1][1] + 1:
            out[-1] = (out[-1][0], max(out[-1][1], hi))
        else:
            out.append((lo, hi))
    return out


def _class_text(ranges: list[tuple[int, int]]) -> str:
    if not ranges:
        return "(?!)"
    parts = [f"\\U{lo:08x}" if lo == hi else f"\\U{lo:08x}-\\U{hi:08x}" for lo, hi in ranges]
    return "[" + "".join(parts) + "]"


# ------------------------------------------------------------------ decoding ---

def _sequence_length(byte: int) -> int:
    if byte < 0x80:
        return 1
    if 0xC0 <= byte <= 0xDF:
        return 2
    if 0xE0 <= byte <= 0xEF:
        return 3
    if 0xF0 <= byte <= 0xF7:
        return 4
    return 0


def decode(data: bytes) -> str:
    """UTF-8 as the engine steps it: an invalid sequence is U+FFFD for one byte."""
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        pass
    out, at = [], 0
    while at < len(data):
        length = _sequence_length(data[at])
        if length and at + length <= len(data):
            try:
                out.append(data[at:at + length].decode("utf-8"))
                at += length
                continue
            except UnicodeDecodeError:
                pass
        out.append("�")
        at += 1
    return "".join(out)


def _pattern_points(text: bytes) -> list[tuple[int, int]]:
    """(byte offset, code point) of a valid UTF-8 pattern."""
    points, at = [], 0
    for char in text.decode("utf-8"):
        points.append((at, ord(char)))
        at += len(char.encode("utf-8"))
    return points


# ------------------------------------------------------------------- parsing ---

class _Refused(Exception):
    def __init__(self, at: int, reason: str):
        super().__init__(reason)
        self.at = at
        self.reason = reason


def _escapable(cp: int) -> bool:
    return 0x20 <= cp <= 0x2F or 0x3A <= cp <= 0x40 or 0x5B <= cp <= 0x60 or 0x7B <= cp <= 0x7E


_ESCAPE_ITEMS = {"d": ("digit", True), "D": ("digit", False), "w": ("word", True), "W": ("word", False),
                 "s": ("space", True), "S": ("space", False)}


class _Parser:
    """`pattern.zig`'s parser, step for step: nodes are tuples, offsets are bytes."""

    def __init__(self, text: bytes):
        self.points = _pattern_points(text)
        self.length = len(text)
        self.i = 0
        self.classes: list[tuple[list, bool]] = []
        self.written: list[int] = []

    @property
    def at(self) -> int:
        return self.points[self.i][0] if self.i < len(self.points) else self.length

    def peek(self) -> int | None:
        return self.points[self.i][1] if self.i < len(self.points) else None

    def peek_next(self) -> int | None:
        return self.points[self.i + 1][1] if self.i + 1 < len(self.points) else None

    def take(self) -> int | None:
        cp = self.peek()
        if cp is not None:
            self.i += 1
        return cp

    def alternation(self):
        branches = [self.concat()]
        while self.peek() == ord("|"):
            self.take()
            branches.append(self.concat())
        return branches[0] if len(branches) == 1 else ("alt", branches)

    def concat(self):
        items = []
        while (cp := self.peek()) is not None:
            if cp in (ord("|"), ord(")")):
                break
            items.append(self.repeat())
        if not items:
            return ("empty",)
        return items[0] if len(items) == 1 else ("cat", items)

    def repeat(self):
        node = self.atom()
        repeated = False
        while (cp := self.peek()) is not None:
            q_at = self.at
            if chr(cp) not in "*+?{":
                break
            if repeated or node[0] in ("assert", "empty"):
                raise _Refused(q_at, "a repeat follows nothing it can repeat")
            low, high = 0, None
            self.take()
            if cp == ord("+"):
                low = 1
            elif cp == ord("?"):
                high = 1
            elif cp == ord("{"):
                low = self.number(q_at)
                high = low
                if self.peek() == ord(","):
                    self.take()
                    high = None if self.peek() == ord("}") else self.number(q_at)
                if self.peek() != ord("}"):
                    raise _Refused(q_at, "a repeat {m,n} is not closed")
                self.take()
                if low > MAX_REPEAT or (high is not None and high > MAX_REPEAT):
                    raise _Refused(q_at, "a repeat bound is over 255")
                if high is not None and high < low:
                    raise _Refused(q_at, "a repeat {m,n} has n below m")
            if self.peek() in (ord("?"), ord("+")):
                raise _Refused(self.at, "lazy and possessive repeats are not supported")
            node = ("rep", node, low, high)
            repeated = True
        return node

    def number(self, q_at: int) -> int:
        start, value = self.i, 0
        while (cp := self.peek()) is not None and ord("0") <= cp <= ord("9"):
            value = min(value * 10 + cp - ord("0"), 100_000)
            self.take()
        if self.i == start:
            raise _Refused(q_at, "a repeat {m,n} needs a number")
        return value

    def atom(self):
        at = self.at
        cp = self.take()
        char = chr(cp)
        if char == "(":
            if self.peek() == ord("?"):
                self.take()
                if self.take() != ord(":"):
                    raise _Refused(at, "look-around and inline flags are not supported")
            inner = self.alternation()
            if self.peek() != ord(")"):
                raise _Refused(at, "a group is not closed")
            self.take()
            return inner
        if char == "[":
            return self.klass(at)
        if char == ".":
            return ("any",)
        if char == "^":
            return ("assert", "bol")
        if char == "$":
            return ("assert", "eol")
        if char == "\\":
            e = self.take()
            if e is None:
                raise _Refused(at, "the pattern ends with a backslash")
            escape = chr(e)
            if escape == "b":
                return ("assert", "boundary")
            if escape == "B":
                return ("assert", "not_boundary")
            if escape in _ESCAPE_ITEMS:
                return self.add_class([_ESCAPE_ITEMS[escape]], False)
            if escape == "t":
                return self.char(0x09)
            if "1" <= escape <= "9":
                raise _Refused(at, "back-references are not supported")
            if _escapable(e):
                return self.char(e)
            raise _Refused(at, "an escape outside the subset")
        if char in "*+?{":
            raise _Refused(at, "a repeat follows nothing it can repeat")
        return self.char(cp)

    def char(self, cp: int):
        self.written.append(cp)
        return ("char", cp)

    def add_class(self, items: list, negated: bool):
        self.classes.append((items, negated))
        return ("class", len(self.classes) - 1)

    def class_escape(self, at: int, e: int, allow_class: bool):
        escape = chr(e)
        if escape in _ESCAPE_ITEMS:
            if allow_class:
                return ("item", _ESCAPE_ITEMS[escape])
            raise _Refused(at, "an escape outside the subset")
        if escape in "bB":
            raise _Refused(at, "\\b inside a class is not supported")
        if escape == "t":
            return ("cp", 0x09)
        if "1" <= escape <= "9":
            raise _Refused(at, "back-references are not supported")
        if _escapable(e):
            return ("cp", e)
        raise _Refused(at, "an escape outside the subset")

    def klass(self, open_at: int):
        negated = False
        if self.peek() == ord("^"):
            self.take()
            negated = True
        items: list = []
        first = True
        while True:
            low_at = self.at
            cp = self.take()
            if cp is None:
                raise _Refused(open_at, "a class [...] is not closed")
            if cp == ord("]") and not first:
                break
            first = False
            low = cp
            if cp == ord("["):
                raise _Refused(low_at, "a [ inside a class must be escaped")
            if cp == ord("\\"):
                e = self.take()
                if e is None:
                    raise _Refused(low_at, "the pattern ends with a backslash")
                kind, value = self.class_escape(low_at, e, True)
                if kind == "item":
                    items.append(value)
                    continue
                low = value
            following = self.peek_next()
            if self.peek() == ord("-") and following is not None and following != ord("]"):
                self.take()
                high_at = self.at
                high = self.take()
                if high == ord("["):
                    raise _Refused(high_at, "a [ inside a class must be escaped")
                if high == ord("\\"):
                    e = self.take()
                    if e is None:
                        raise _Refused(high_at, "the pattern ends with a backslash")
                    high = self.class_escape(high_at, e, False)[1]
                if high < low:
                    raise _Refused(low_at, "a class range is reversed")
                self.written += [low, high]
                items.append(("range", (low, high)))
            else:
                self.written.append(low)
                items.append(("range", (low, low)))
        return self.add_class(items, negated)


def _size(node) -> int:
    """Instructions the engine's compiler emits for `node`."""
    kind = node[0]
    if kind == "empty":
        return 0
    if kind in ("char", "any", "class", "assert"):
        return 1
    if kind == "cat":
        return sum(_size(item) for item in node[1])
    if kind == "alt":
        return sum(_size(branch) for branch in node[1]) + 2 * (len(node[1]) - 1)
    _, sub, low, high = node
    inner = _size(sub)
    if high is None:
        return low * inner + inner + 2
    return low * inner + (high - low) * (inner + 1)


def _nullable(node) -> bool:
    kind = node[0]
    if kind in ("empty", "assert"):
        return True
    if kind in ("char", "any", "class"):
        return False
    if kind == "cat":
        return all(_nullable(item) for item in node[1])
    if kind == "alt":
        return any(_nullable(branch) for branch in node[1])
    return node[2] == 0 or _nullable(node[1])


# ----------------------------------------------------------------- compiling ---

class Compiled:
    """A checked pattern: `regex` (a compiled `re` pattern over the folded line when insensitive)."""

    def __init__(self, regex: re.Pattern, case_applied: str, matches_empty: bool):
        self.regex = regex
        self.case_applied = case_applied
        self.matches_empty = matches_empty

    def prepare(self, line: str) -> str:
        if self.case_applied == "insensitive":
            return line.translate(_tables()["translate"])
        return line


def _item_ranges(item) -> list[tuple[int, int]]:
    kind, value = item
    if kind == "range":
        return [value]
    table = _tables()[kind]
    return table if value else _complement(table)


def _class_ranges(items: list, negated: bool, insensitive: bool) -> list[tuple[int, int]]:
    members = _merge(r for item in items for r in _item_ranges(item))
    if insensitive:
        extras = [(to, to) for cp, to in _tables()["pairs"] if _in_ranges(members, cp) and not _in_ranges(members, to)]
        members = _merge(members + extras)
    return _complement(members) if negated else members


def _translate(node, classes: list[str], word: str, insensitive: bool) -> str:
    kind = node[0]
    if kind == "empty":
        return ""
    if kind == "char":
        cp = fold(node[1]) if insensitive else node[1]
        return re.escape(chr(cp))
    if kind == "any":
        return "."
    if kind == "class":
        return classes[node[1]]
    if kind == "assert":
        return {
            "bol": r"\A",
            "eol": r"\Z",
            "boundary": f"(?:(?<={word})(?!{word})|(?<!{word})(?={word}))",
            "not_boundary": f"(?:(?<={word})(?={word})|(?<!{word})(?!{word}))",
        }[node[1]]
    if kind == "cat":
        return "".join(f"(?:{_translate(item, classes, word, insensitive)})" for item in node[1])
    if kind == "alt":
        return "(?:" + "|".join(_translate(branch, classes, word, insensitive) for branch in node[1]) + ")"
    _, sub, low, high = node
    bound = f"{{{low},}}" if high is None else f"{{{low},{high}}}"
    return f"(?:{_translate(sub, classes, word, insensitive)}){bound}"


def compile_pattern(pattern: str, mode: str = "literal", case: str = "smart", whole_word: bool = False) -> Compiled:
    """Check and compile a pattern, or raise `ScanError` with the engine's message."""
    data = pattern.encode("utf-8", "surrogatepass")
    if not 1 <= len(data) <= MAX_PATTERN_BYTES:
        raise _invalid(f"pattern must be 1..{MAX_PATTERN_BYTES} bytes")
    try:
        data.decode("utf-8")
    except UnicodeDecodeError:
        raise _invalid("pattern is not valid UTF-8") from None
    if any(ord(char) in _LINE_BREAKS for char in pattern):
        raise _invalid("pattern holds a line break; matching is per line")
    if mode == "literal":
        chars = [("char", ord(char)) for char in pattern]
        root = chars[0] if len(chars) == 1 else ("cat", chars)
        written = [ord(char) for char in pattern]
        class_items: list = []
    else:
        parser = _Parser(data)
        try:
            root = parser.alternation()
        except _Refused as refused:
            raise _invalid(f"pattern not supported at byte {refused.at}: {refused.reason}") from None
        if parser.at != len(data):
            raise _invalid(f"pattern not supported at byte {parser.at}: a ) has no (")
        written, class_items = parser.written, parser.classes
    if case == "smart":
        applied = "sensitive" if any(fold(cp) != cp for cp in written) else "insensitive"
    else:
        applied = case
    if _size(root) + (2 if whole_word else 0) + 1 > MAX_PROGRAM:
        raise _invalid("pattern not supported at byte 0: the pattern is too large (over 8,192 steps)")
    insensitive = applied == "insensitive"
    word = _class_text(_tables()["word"])
    classes = [_class_text(_class_ranges(items, negated, insensitive)) for items, negated in class_items]
    body = _translate(root, classes, word, insensitive)
    if whole_word:
        body = f"(?<!{word})(?:{body})(?!{word})"
    return Compiled(re.compile(body, re.DOTALL), applied, mode == "regex" and _nullable(root))


def match_line(compiled: Compiled, line: str, text_cps: int) -> tuple[bool, list[list[int]]]:
    """Whether `line` is a hit, and its non-empty matches starting within `text_cps` code points."""
    hit, offsets = False, []
    for match in compiled.regex.finditer(compiled.prepare(line)):
        hit = True
        start, end = match.span()
        if start >= text_cps:
            break
        if start == end:
            continue
        offsets.append([start, min(end, text_cps)])
    return hit, offsets


# --------------------------------------------------------------------- scope ---

def glob_matches(glob: str, name: str) -> bool:
    """`*` any run of code points, `?` one code point, every other code point itself."""
    g = n = 0
    star_g, star_n = None, 0
    while n < len(name):
        if g < len(glob) and glob[g] == "*":
            star_g, star_n = g, n
            g += 1
            continue
        if g < len(glob) and (glob[g] == "?" or glob[g] == name[n]):
            g += 1
            n += 1
            continue
        if star_g is None:
            return False
        star_n += 1
        n = star_n
        g = star_g + 1
    while g < len(glob) and glob[g] == "*":
        g += 1
    return g == len(glob)


def in_scope(request: dict, path: str) -> bool:
    prefix = request.get("path_prefix")
    if prefix is not None and not path.encode("utf-8").startswith(prefix.encode("utf-8")):
        return False
    glob = request.get("name_glob")
    if glob is not None and not glob_matches(glob, path.rsplit("/", 1)[-1]):
        return False
    return True


# ------------------------------------------------------------------- request ---

def _check_request(params: dict, *, labels_field: bool) -> dict:
    """`ops.parseScan`'s fields and messages, with the defaults filled in."""
    if not isinstance(params, dict):
        raise _invalid("the request must be a JSON object")
    allowed = FIELDS + (("principal_labels",) if labels_field else ())
    for name in params:
        if name not in allowed:
            raise _invalid(f'unknown field "{name}"')
    if "pattern" not in params:
        raise _invalid("pattern is required")
    pattern = params["pattern"]
    if not isinstance(pattern, str):
        raise _invalid("pattern must be a string")

    def string(name):
        value = params.get(name)
        if value is not None and not isinstance(value, str):
            raise _invalid(f"{name} must be a string")
        return value

    def integer(name, default):
        value = params.get(name)
        if value is None:
            return default
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise _invalid(f"{name} must be a non-negative integer")
        return value

    mode = string("mode") or "literal"
    if mode not in ("literal", "regex"):
        raise _invalid("mode must be literal or regex")
    case = string("case") or "smart"
    if case not in ("sensitive", "insensitive", "smart"):
        raise _invalid("case must be sensitive, insensitive or smart")
    roots = params.get("roots")
    if roots is not None:
        if not isinstance(roots, list) or not all(isinstance(item, str) for item in roots):
            raise _invalid("roots must be an array of strings")
        if len(roots) > MAX_NAMED_ROOTS:
            raise _invalid(f"roots holds more than {MAX_NAMED_ROOTS} entries")
    whole_word = params.get("whole_word")
    if whole_word is not None and not isinstance(whole_word, bool):
        raise _invalid("whole_word must be a boolean")
    request = {
        "pattern": pattern,
        "mode": mode,
        "case": case,
        "whole_word": bool(whole_word),
        "roots": roots,
        "path_prefix": string("path_prefix"),
        "name_glob": string("name_glob"),
        "context_lines": integer("context_lines", 0),
        "max_hits_per_file": integer("max_hits_per_file", DEFAULT_MAX_HITS_PER_FILE),
        "page_size": integer("page_size", DEFAULT_PAGE_SIZE),
        "cursor": string("cursor"),
        "time_budget_ms": integer("time_budget_ms", DEFAULT_TIME_BUDGET_MS),
    }
    if roots is not None and any(item == "" for item in roots):
        raise _invalid("roots must not hold an empty id")
    if not 1 <= request["page_size"] <= MAX_PAGE_SIZE:
        raise _invalid(f"page_size must be 1..{MAX_PAGE_SIZE}")
    if request["context_lines"] > MAX_CONTEXT_LINES:
        raise _invalid(f"context_lines must be 0..{MAX_CONTEXT_LINES}")
    if not 1 <= request["max_hits_per_file"] <= MAX_MAX_HITS_PER_FILE:
        raise _invalid(f"max_hits_per_file must be 1..{MAX_MAX_HITS_PER_FILE}")
    if not 1 <= request["time_budget_ms"] <= MAX_TIME_BUDGET_MS:
        raise _invalid(f"time_budget_ms must be 1..{MAX_TIME_BUDGET_MS}")
    glob = request["name_glob"]
    if glob is not None and (not 1 <= len(glob.encode("utf-8")) <= MAX_GLOB_BYTES or "/" in glob):
        raise _invalid(f"name_glob must be 1..{MAX_GLOB_BYTES} bytes with no /")
    return request


def _request_hash(request: dict, scope_roots: list[str] | None, labels: list[str]) -> str:
    bound = {key: request[key] for key in FIELDS if key not in ("cursor", "page_size", "time_budget_ms", "roots")}
    bound["scope_roots"] = scope_roots
    bound["labels"] = list(labels)
    canonical = json.dumps(bound, sort_keys=True, ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()[:16]


def _walk_hash(paths: list[str]) -> str:
    return hashlib.sha256(b"".join(path.encode("utf-8") + b"\0" for path in paths)).hexdigest()[:16]


def _parse_cursor(cursor: str, kind: str, stamp: str, request_hash: str) -> tuple[int, int, int]:
    parts = cursor.split(":")
    if len(parts) != 5:
        raise _invalid("malformed cursor")
    head, hashed, file_text, line_text, listed_text = parts
    if not re.fullmatch(r"[0-9a-f]{16}", hashed) or not all(re.fullmatch(r"[0-9]+", t) for t in (file_text, line_text, listed_text)):
        raise _invalid("malformed cursor")
    if int(line_text) == 0:
        raise _invalid("malformed cursor")
    if head.startswith("f"):
        if not re.fullmatch(r"f[0-9a-f]{16}", head):
            raise _invalid("malformed cursor")
        if kind != "folder" or head[1:] != stamp:
            raise _invalid("stale cursor")
    else:
        if not re.fullmatch(r"[0-9]+", head):
            raise _invalid("malformed cursor")
        if kind != "index" or head != stamp:
            raise _invalid("stale cursor")
    if hashed != request_hash:
        raise _invalid("cursor does not belong to this request")
    return int(file_text), int(line_text), int(listed_text)


# ---------------------------------------------------------------------- lines ---

def strip_break(line: bytes) -> bytes:
    """A line's bytes without its terminator (CRLF, or one `str.splitlines` terminator)."""
    if line.endswith(b"\r\n"):
        return line[:-2]
    for terminator in (b"\xe2\x80\xa8", b"\xe2\x80\xa9", b"\xc2\x85"):
        if line.endswith(terminator):
            return line[: -len(terminator)]
    if line and line[-1] in (0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E):
        return line[:-1]
    return line


def text_cut(line: bytes) -> int:
    if len(line) <= MAX_TEXT_BYTES:
        return len(line)
    cut = MAX_TEXT_BYTES
    while cut > 0 and line[cut] & 0xC0 == 0x80:
        cut -= 1
    return cut


def _context(data: bytes, starts: list[int], first: int, last: int) -> list[dict]:
    out = []
    for index in range(first, last + 1):
        content = strip_break(data[starts[index]:starts[index + 1]])
        cut = text_cut(content)
        out.append({"line": index + 1, "text": decode(content[:cut]), "text_truncated": cut < len(content)})
    return out


# ----------------------------------------------------------------------- run ---

def _run(request: dict, *, kind: str, stamp: str, generation: int | None, files: list[tuple[str, str]],
         read: Callable[[str, str], tuple[str, bytes | None]], scope_roots: list[str], labels: list[str],
         pending_files: int, not_scanned: dict, not_read: dict | None, clock: Callable[[], float]) -> dict:
    compiled = compile_pattern(request["pattern"], request["mode"], request["case"], request["whole_word"])
    request_hash = _request_hash(request, scope_roots, labels)
    file_at, line_at, listed_at = 0, 1, 0
    if request["cursor"] is not None:
        file_at, line_at, listed_at = _parse_cursor(request["cursor"], kind, stamp, request_hash)
    kept = [(root_id, path) for root_id, path in files if in_scope(request, path)]
    if file_at > len(kept) or listed_at > request["max_hits_per_file"]:
        raise _invalid("malformed cursor")
    deadline = clock() + request["time_budget_ms"] / 1000
    not_scanned = dict(not_scanned)
    not_read = dict(not_read) if not_read is not None else None
    hits: list[dict] = []
    counts = {"files_matched": 0, "files_scanned": 0, "files_capped": 0, "bytes_scanned": 0}
    stopped, resume = "none", None
    progress = False
    context = request["context_lines"]
    max_hits = request["max_hits_per_file"]
    position = (file_at, line_at, listed_at)
    while position[0] < len(kept):
        if progress and clock() >= deadline:
            stopped, resume = "time", position
            break
        root_id, path = kept[position[0]]
        outcome, data = read(root_id, path)
        if data is None:
            if outcome == "binary" and not_read is not None:
                not_read["binary"] = not_read.get("binary", 0) + 1
            elif outcome in not_scanned:
                not_scanned[outcome] += 1
            position = (position[0] + 1, 1, 0)
            progress = True
            continue
        starts = core.line_starts(data)
        line_count = len(starts) - 1
        line, listed = position[1], position[2]
        capped = False
        visited = 0
        page_full = False
        out_of_time = False
        while line <= line_count:
            visited += 1
            if visited % LINES_PER_CHECK == 0 and progress and clock() >= deadline:
                out_of_time = True
                break
            content = strip_break(data[starts[line - 1]:starts[line]])
            cut = text_cut(content)
            hit, offsets = match_line(compiled, decode(content), len(decode(content[:cut])))
            progress = True
            if hit:
                if listed == max_hits:
                    capped = True
                    break
                index = line - 1
                hits.append({
                    "root_id": root_id,
                    "path": path,
                    "line": line,
                    "text": decode(content[:cut]),
                    "text_truncated": cut < len(content),
                    "match_offsets": offsets,
                    "before": _context(data, starts, max(0, index - context), index - 1) if context and index else [],
                    "after": _context(data, starts, index + 1, min(index + context, line_count - 1)),
                })
                listed += 1
                if len(hits) == request["page_size"]:
                    page_full = True
                    break
            line += 1
        if out_of_time:
            stopped, resume = "time", (position[0], line, listed)
            break
        if page_full:
            resume = (position[0], line + 1, listed)
            break
        counts["files_scanned"] += 1
        counts["bytes_scanned"] += len(data)
        counts["files_matched"] += 1 if listed > 0 else 0
        counts["files_capped"] += 1 if capped else 0
        position = (position[0] + 1, 1, 0)
        progress = True
    next_cursor = None
    if resume is not None:
        head = f"f{stamp}" if kind == "folder" else stamp
        next_cursor = f"{head}:{request_hash}:{resume[0]}:{resume[1]}:{resume[2]}"
    warnings = []
    if compiled.matches_empty:
        warnings.append({"code": "pattern_matches_empty", "message": EMPTY_MATCH_MESSAGE})
    return {
        "request": {key: request[key] for key in FIELDS},
        "source": kind,
        "generation": generation,
        "scope": {"roots": scope_roots, "labels_applied": True},
        "warnings": warnings,
        "case_applied": compiled.case_applied,
        "hits": hits,
        **counts,
        "pending_files": pending_files,
        "not_scanned": not_scanned,
        "not_read": not_read,
        "truncated": pending_files > 0 or any(not_scanned.values()),
        "stopped": stopped,
        "next_cursor": next_cursor,
    }


def _byte_order(path: str) -> bytes:
    return path.encode("utf-8")


def scan(index: dict, params: dict, *, principal_labels: Iterable[str] = (),
         clock: Callable[[], float] = time.monotonic) -> dict:
    """`scan` over a `core.build_index` index (root `r-legacy`): its recorded files, read again under the
    index root and checked against their sha256; a changed or missing file counts as unreadable."""
    request = _check_request(params, labels_field=True)
    labels = sorted(set(principal_labels))
    roots = request["roots"]
    visible = roots is None or LEGACY_ROOT_ID in roots
    scope_roots = [LEGACY_ROOT_ID] if visible else []
    required: dict[str, list[str]] = {}
    for chunk in index.get("chunks", []):
        required.setdefault(chunk["path"], chunk.get("required_labels", []))

    def allowed(path: str) -> bool:
        return visible and set(required.get(path, [])) <= set(labels)

    paths = sorted((item["path"] for item in index.get("source_files", []) if allowed(item["path"])), key=_byte_order)
    not_scanned = {"too_large": 0, "unreadable": 0, "budget_exhausted": 0, "not_retained": 0}
    for item in index.get("skipped", []):
        path = item.get("path", "")
        if allowed(path) and in_scope(request, path):
            reason = item.get("reason")
            not_scanned[reason if reason in ("too_large", "budget_exhausted") else "unreadable"] += 1

    def read(root_id: str, path: str) -> tuple[str, bytes | None]:
        try:
            return "ok", core._source_bytes(index, path)
        except core.ReadError:
            return "unreadable", None

    return _run(request, kind="index", stamp=str(index.get("generation", 0)), generation=index.get("generation", 0),
                files=[(LEGACY_ROOT_ID, path) for path in paths], read=read, scope_roots=scope_roots,
                labels=labels, pending_files=0, not_scanned=not_scanned, not_read=None, clock=clock)


def scan_folder(root: Path, params: dict, *, max_file_bytes: int = core.MAX_FILE_BYTES,
                clock: Callable[[], float] = time.monotonic) -> dict:
    """`scan` over a folder with nothing prepared (`searchd scan --folder`): the walk and read rules of an
    index build, root `r-legacy`, nothing written."""
    request = _check_request(params, labels_field=False)
    root = Path(root)
    walked = list(core._walk(root))
    not_read: dict[str, int] = {}
    paths = []
    for path, kind in walked:
        if kind is None:
            paths.append(path.relative_to(root).as_posix())
        else:
            not_read[kind] = not_read.get(kind, 0) + 1
    paths.sort(key=_byte_order)
    roots = request["roots"]
    visible = roots is None or LEGACY_ROOT_ID in roots

    def read(root_id: str, path: str) -> tuple[str, bytes | None]:
        target = root / path
        try:
            if target.stat().st_size > max_file_bytes:
                return "too_large", None
            data = target.read_bytes()
            data.decode("utf-8")
        except (OSError, UnicodeDecodeError):
            return "unreadable", None
        return "ok", data

    not_scanned = {"too_large": 0, "unreadable": 0, "budget_exhausted": 0, "not_retained": 0}
    return _run(request, kind="folder", stamp=_walk_hash(paths), generation=None,
                files=[(LEGACY_ROOT_ID, path) for path in paths] if visible else [], read=read,
                scope_roots=[LEGACY_ROOT_ID] if visible else [], labels=[], pending_files=0,
                not_scanned=not_scanned, not_read=dict(sorted(not_read.items())), clock=clock)
