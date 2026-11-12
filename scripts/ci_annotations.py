"""GitHub workflow annotations for the CI checks of S5-T6 (ruling 6).

A job log needs a sign-in; the check-runs API of a public repository does not,
and it returns a run's annotations. So each CI step S5-T6 adds reports what
failed as `::error title=...::message` lines (or `::warning`, `::notice`), one
per failing row or skipped test, at most LIMIT per step: past the limit the
last line says how many more there were and that the log holds them all.

GitHub keeps a limited number of annotations of each level per step (10 at the
time of writing), so a step that has more to say than that still prints every
row in its log; the annotations are the part a reader without a sign-in sees.
"""

from __future__ import annotations

import sys
from typing import TextIO

LIMIT = 30
LEVELS = ("error", "warning", "notice")


def escape_data(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def escape_property(text: str) -> str:
    return escape_data(text).replace(":", "%3A").replace(",", "%2C")


def line(level: str, title: str, message: str) -> str:
    if level not in LEVELS:
        raise ValueError(f"unknown annotation level {level!r}")
    return f"::{level} title={escape_property(title)}::{escape_data(message)}"


class Annotations:
    """Collects annotations and prints at most `limit` of them."""

    def __init__(self, limit: int = LIMIT) -> None:
        if limit < 1:
            raise ValueError("limit must be at least 1")
        self.limit = limit
        self.items: list[tuple[str, str, str]] = []

    def add(self, level: str, title: str, message: str) -> None:
        line(level, title, message)  # validates the level
        self.items.append((level, title, message))

    def lines(self) -> list[str]:
        items = self.items
        if len(items) > self.limit:
            shown = items[:self.limit - 1]
            rest = items[self.limit - 1:]
            level = "error" if any(i[0] == "error" for i in rest) else rest[0][0]
            summary = (level, f"{len(rest)} more not annotated",
                       f"{len(rest)} more rows of the same step are not annotated (bound {self.limit}); the job log lists all {len(items)}")
            items = shown + [summary]
        return [line(*item) for item in items]

    def flush(self, stream: TextIO | None = None) -> None:
        out = stream or sys.stdout
        for text in self.lines():
            print(text, file=out)
        out.flush()
        self.items = []
