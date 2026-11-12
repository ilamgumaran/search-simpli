"""S5-T6 orchestrator ruling 1 on the interim Report: the one fragment the Unicode
table checks normalise.

`scripts/gen_unicode_tables.py` writes the generating interpreter's version into
the header of `src/search_platform/_fold.py`, `src/search_platform/_marks.py` and
`zig/src/unicode_tables.zig` ("Produced by scripts/gen_unicode_tables.py ... using
Python 3.9.6's"). CI's Python 3.9 is a later 3.9 patch release with the same
Unicode 13.0.0, so the checks compare every byte except that version: the pattern
is anchored to the start of a line and to the header phrase, and it replaces at
most one occurrence per text. The committed headers keep the version they were
generated with. The checks still assert `unicodedata.unidata_version`.
"""

from __future__ import annotations

import re

HEADER_VERSION = re.compile(
    r"^(?P<lead>(?://! )?Produced by scripts/gen_unicode_tables\.py(?: --python-(?:fold|marks))? using Python )"
    r"\d+\.\d+\.\d+(?='s$)", re.MULTILINE)
PLACEHOLDER = "X.Y.Z"


def normalise(text: str) -> str:
    """`text` with the interpreter version of the header phrase replaced, once at most."""
    return HEADER_VERSION.sub(lambda m: m.group("lead") + PLACEHOLDER, text, count=1)


def same_table(fresh: str, committed: str) -> bool:
    return normalise(fresh) == normalise(committed)
