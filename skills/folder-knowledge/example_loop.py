#!/usr/bin/env python3
"""The folder-knowledge loop of SKILL.md, run against `searchd serve`.

A stub "model" that does nothing the skill does not tell it to: it checks the
index status, picks `find` for quoted or exact questions and `search_knowledge`
for open ones, confirms every passage it will use with `read_span` /
`read_chunk`, writes an answer in which every claim carries a `[n]` that maps
to a returned hit, lists the sources as `root/path > section . lines`, says
"I found no matching indexed passages in the selected folders." when nothing
came back (plus the caveat when `pending_files` > 0 or `truncated`), and never
calls `apply_changes`. It stands in for a language model only in choosing
words; every fact in its answers is a substring of a tool result.

Usage:
    python3 skills/folder-knowledge/example_loop.py --searchd PATH [--index DIR]

Without `--index` the UC-007 fixture (`fixtures/family-folder`) is indexed
into a temporary folder with `searchd apply`. Standard library only.
"""

from __future__ import annotations

import argparse
import base64
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PACK = REPO / "fixtures" / "family-folder"
NEGATIVE = "I found no matching indexed passages in the selected folders."
CAVEAT = "Some files are still pending or the listing was truncated, so this may not cover everything."
# The eight read tools. apply_changes and roots are deliberately not here.
READ_TOOLS = ("search_knowledge", "read_chunk", "list_sources", "index_status",
              "find", "outline", "read_span", "list_files")
STOP = {"the", "a", "an", "is", "are", "was", "what", "when", "did", "do", "does", "say", "said", "about",
        "to", "of", "in", "my", "me", "it", "after", "next", "there", "anything", "teacher"}


def build_fixture_index(searchd: str, index: Path) -> None:
    """Index the fixture's three roots (host roots, bytes sent as base64)."""
    request = {"roots": [], "changes": []}
    for root_id in ("home", "laptop", "school"):
        request["roots"].append({"root_id": root_id, "label": root_id.title(), "kind": "host"})
        base = PACK / root_id
        for path in sorted(p for p in base.rglob("*") if p.is_file()):
            request["changes"].append({"op": "add", "root_id": root_id, "path": path.relative_to(base).as_posix(),
                                       "content_base64": base64.b64encode(path.read_bytes()).decode("ascii")})
    with tempfile.TemporaryDirectory() as scratch:
        changes = Path(scratch) / "changes.json"
        changes.write_text(json.dumps(request), encoding="utf-8")
        done = subprocess.run([searchd, "apply", str(index), "--changes", str(changes)], capture_output=True, text=True)
        if done.returncode != 0:
            raise RuntimeError(done.stderr)


class Tools:
    """One `searchd serve` process (read-only: no --allow-write). Keeps a log
    of every call so a caller can check that each citation was returned."""

    def __init__(self, searchd: str, index: Path) -> None:
        self.process = subprocess.Popen([searchd, "serve", str(index)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.log: list[tuple[str, dict, dict]] = []
        self.next_id = 0

    def call(self, method: str, **params: object) -> dict:
        if method not in READ_TOOLS:
            raise PermissionError(f"the skill does not allow calling {method}")
        self.next_id += 1
        request = {"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params}
        self.process.stdin.write(json.dumps(request) + "\n")
        self.process.stdin.flush()
        reply = json.loads(self.process.stdout.readline())
        if "error" in reply:
            raise RuntimeError(f"{method}: {reply['error']}")
        self.log.append((method, params, reply["result"]))
        return reply["result"]

    def close(self) -> None:
        self.process.stdin.close()
        self.process.wait(timeout=30)
        self.process.stdout.close()
        self.process.stderr.close()


class Answer:
    """An answer under construction: text with [n] markers plus its sources."""

    def __init__(self) -> None:
        self.sources: list[dict] = []
        self.lines: list[str] = []

    def cite(self, kind: str, root_id: str, path: str, section: list[str], start: int, end: int, **extra: object) -> int:
        for number, source in enumerate(self.sources, 1):
            if (source["kind"], source["root_id"], source["path"], source["start_line"], source["end_line"]) == (kind, root_id, path, start, end):
                return number
        self.sources.append({"kind": kind, "root_id": root_id, "path": path, "section": section,
                             "start_line": start, "end_line": end, **extra})
        return len(self.sources)

    def render(self) -> str:
        out = list(self.lines)
        for number, s in enumerate(self.sources, 1):
            where = f"{s['root_id']}/{s['path']}"
            if s["section"]:
                where += " › " + " › ".join(s["section"])
            span = f"line {s['start_line']}" if s["start_line"] == s["end_line"] else f"lines {s['start_line']}–{s['end_line']}"
            out.append(f"[{number}] {where} · {span}")
        return "\n".join(out)


def terms(text: str) -> set[str]:
    return {w for w in re.findall(r"[\w']+", text.lower()) if w not in STOP}


def best_line(text: str, query: str) -> tuple[str, int]:
    """The line of `text` sharing most words with the query: (line, offset)."""
    wanted = terms(query)
    best, best_score, best_index = "", -1, 0
    for index, line in enumerate(text.splitlines()):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        score = len(wanted & terms(line))
        if score > best_score:
            best, best_score, best_index = line.strip(), score, index
    return best, best_index


def paragraph(lines: list[str], index: int) -> tuple[int, int]:
    """First and last index of the paragraph around lines[index]: neighbouring
    non-blank lines, not crossing a heading or the start of another list item."""
    first = index
    while first > 0 and lines[first].strip() and not lines[first].lstrip().startswith(("- ", "* ", "#")) \
            and lines[first - 1].strip() and not lines[first - 1].lstrip().startswith("#"):
        first -= 1
    last = index
    while last + 1 < len(lines) and lines[last + 1].strip() and not lines[last + 1].lstrip().startswith(("- ", "* ", "#", "1.", "2.")):
        last += 1
    return first, last


def section_for(headings: list[dict], line: int) -> list[str]:
    """The heading path covering `line`, from an `outline` result."""
    path: list[dict] = []
    for h in headings:
        if h["line"] <= line <= h["end_line"]:
            path = [p for p in path if p["level"] < h["level"]] + [h]
    return [h["text"] for h in path]


class Loop:
    def __init__(self, tools: Tools) -> None:
        self.tools = tools
        self.status = tools.call("index_status")
        self.root_ids = [r["root_id"] for r in self.status["roots"]]
        self.incomplete = self.status["pending"] > 0 or self.status["truncated"]

    # -- helpers -----------------------------------------------------------

    def split_record_path(self, path: str) -> tuple[str, str]:
        """search_knowledge cites `root_id/path`; the other tools take both parts."""
        head, _, rest = path.partition("/")
        if head in self.root_ids and rest:
            return head, rest
        raise ValueError(f"cannot split {path!r} into a root and a path")

    def section_of(self, root_id: str, path: str, line: int) -> list[str]:
        try:
            return section_for(self.tools.call("outline", root_id=root_id, path=path)["headings"], line)
        except RuntimeError:
            return []

    def negative(self, answer: Answer, pending_files: int = 0, truncated: bool = False) -> str:
        answer.lines.append(NEGATIVE)
        if self.incomplete or pending_files > 0 or truncated:
            answer.lines.append(CAVEAT)
        return answer.render()

    def matched_lines(self, hit: dict) -> tuple[int, int, str]:
        """Confirm a find hit with read_span and return the line range of its first
        match and the text of those lines. If the span does not contain the match
        where the hit says, fall back to the whole chunk range."""
        span = self.tools.call("read_span", root_id=hit["root_id"], path=hit["path"],
                               start_line=hit["start_line"], end_line=hit["end_line"])
        text = span["text"]
        a, b = hit["match_offsets"][0]
        snippet_a = a - hit["snippet_start"]
        if text[a:b].lower() == hit["snippet"][snippet_a:snippet_a + (b - a)].lower():
            lines = text.splitlines()
            first = text[:a].count("\n")
            last = text[:b].count("\n")
            return (hit["start_line"] + first, hit["start_line"] + last,
                    " ".join(l.strip() for l in lines[first:last + 1]))
        return hit["start_line"], hit["end_line"], " ".join(l.strip() for l in text.splitlines() if l.strip())[:200]

    # -- the question kinds ---------------------------------------------------

    def exact(self, scenario: dict) -> Answer:
        """find for a quoted, exact or prefix question."""
        answer = Answer()
        mode = scenario["mode"]
        query = f'"{scenario["query"]}"' if mode == "phrase" else scenario["query"]
        found = self.tools.call("find", query=query, mode=mode, page_size=5)
        if not found["hits"]:
            self.negative(answer, found["pending_files"], found["truncated"])
            return answer
        if found["exact_match"] is True:
            answer.lines.append(f"The exact phrase appears in {len(found['files'])} file(s):")
        else:  # None: the phrase predicate was not evaluated; say nothing about exactness.
            answer.lines.append(f"{len(found['files'])} file(s) match; best passages first:")
        for hit in found["hits"]:
            line_from, line_to, quote = self.matched_lines(hit)
            n = answer.cite("hit", hit["root_id"], hit["path"], hit["section_path"], line_from, line_to, chunk_id=hit["chunk_id"])
            answer.lines.append(f"- \u201c{quote}\u201d [{n}]")
        if found["next_cursor"]:
            answer.lines.append("(more hits on the next page)")
        if found["pending_files"] or found["truncated"]:
            answer.lines.append(CAVEAT)
        return answer

    def outline(self, scenario: dict) -> Answer:
        answer = Answer()
        result = self.tools.call("outline", root_id=scenario["root_id"], path=scenario["path"])
        n = answer.cite("outline", scenario["root_id"], scenario["path"], [], 1, result["lines"])
        answer.lines.append(f"{scenario['path']} has {len(result['headings'])} headings [{n}]:")
        for h in result["headings"]:
            answer.lines.append("  " * (h["level"] - 1) + f"- {h['text']} (lines {h['line']}–{h['end_line']})")
        return answer

    def span(self, scenario: dict, start: int, end: int, context: int) -> Answer:
        answer = Answer()
        got = self.tools.call("read_span", root_id=scenario["root_id"], path=scenario["path"],
                              start_line=start, end_line=end, context_lines=context)
        n = answer.cite("span", scenario["root_id"], scenario["path"], [], got["start_line"], got["end_line"])
        first = got["text"].strip().splitlines()[0] if got["text"].strip() else ""
        answer.lines.append(f"Lines {got['start_line']}–{got['end_line']} begin “{first}” [{n}] (sha256 {got['sha256'][:12]}…).")
        return answer

    def open_question(self, scenario: dict) -> Answer:
        """search_knowledge, then read_chunk and read_span to confirm what is quoted."""
        answer = Answer()
        found = self.tools.call("search_knowledge", query=scenario["query"], top_k=3)
        if not found["results"]:
            # An empty page is not proof of absence: look once more with find, then say so carefully.
            retry = self.tools.call("find", query=scenario["query"], page_size=5)
            if not retry["hits"]:
                self.negative(answer, retry["pending_files"], retry["truncated"])
                return answer
        for item in found["results"][:2]:
            root_id, path = self.split_record_path(item["citation"]["path"])
            chunk = self.tools.call("read_chunk", chunk_id=item["chunk_id"])
            assert chunk["content"] == item["content"]
            start, end = item["citation"]["start_line"], item["citation"]["end_line"]
            span = self.tools.call("read_span", root_id=root_id, path=path, start_line=start, end_line=end)
            _, offset = best_line(span["text"], scenario["query"])
            lines = span["text"].splitlines()
            first, last = paragraph(lines, offset)
            sentence = " ".join(l.strip() for l in lines[first:last + 1])
            section = self.section_of(root_id, path, start + offset)
            n = answer.cite("span", root_id, path, section, start + first, start + last, chunk_id=item["chunk_id"])
            answer.lines.append(f"- \u201c{sentence}\u201d [{n}]")
        return answer

    def after_phrase(self, scenario: dict) -> Answer:
        """find the phrase, then read the line after it."""
        answer = Answer()
        found = self.tools.call("find", query=f'"{scenario["query"]}"', mode="phrase", page_size=3)
        if not found["hits"]:
            self.negative(answer, found["pending_files"], found["truncated"])
            return answer
        hit = found["hits"][0]
        first, last, quote = self.matched_lines(hit)
        nxt = self.tools.call("read_span", root_id=hit["root_id"], path=hit["path"], start_line=last + 1, end_line=last + 1)
        a = answer.cite("hit", hit["root_id"], hit["path"], hit["section_path"], first, last, chunk_id=hit["chunk_id"])
        b = answer.cite("span", hit["root_id"], hit["path"], hit["section_path"], nxt["start_line"], nxt["end_line"])
        before = {"text": quote}
        answer.lines.append(f"The step with “{scenario['query']}” is “{before['text'].strip()}” [{a}]")
        answer.lines.append(f"The step after it is “{nxt['text'].strip()}” [{b}]")
        return answer

    def summary(self, scenario: dict) -> Answer:
        """outline, then the first span of each section."""
        answer = Answer()
        outline = self.tools.call("outline", root_id=scenario["root_id"], path=scenario["path"])
        for h in outline["headings"]:
            if h["line"] == h["end_line"]:
                continue
            got = self.tools.call("read_span", root_id=scenario["root_id"], path=scenario["path"],
                                  start_line=h["line"] + 1, end_line=min(h["line"] + 4, h["end_line"]))
            body, offset = best_line(got["text"], "")
            if not body:
                continue
            line = h["line"] + 1 + [i for i, l in enumerate(got["text"].splitlines()) if l.strip() == body][0]
            n = answer.cite("span", scenario["root_id"], scenario["path"], section_for(outline["headings"], h["line"]), line, line)
            answer.lines.append(f"- {h['text']}: {body} [{n}]")
        return answer

    # -- the loop ---------------------------------------------------------------

    def run(self, scenario: dict) -> Answer:
        kind = scenario["kind"]
        if kind in ("words", "phrase", "prefix"):
            return self.exact(scenario)
        if kind == "outline":
            return self.outline(scenario)
        if kind == "read_span":
            return self.span(scenario, 40, 60, scenario.get("context_lines", 0))
        if kind == "answer":
            return self.open_question(scenario)
        if kind == "empty":
            return self.open_question(scenario)
        if kind == "phrase_neighbour":
            return self.after_phrase(scenario)
        if kind == "summary":
            return self.summary(scenario)
        raise ValueError(f"no skill step for {kind}")


def questions() -> list[dict]:
    judgments = json.loads((PACK / "judgments.json").read_text(encoding="utf-8"))
    return [s for s in judgments["scenarios"] if s["kind"] != "lifecycle"]


def run_all(searchd: str, index: Path) -> tuple[list[dict], Tools]:
    tools = Tools(searchd, index)
    loop = Loop(tools)
    results = []
    for scenario in questions():
        answer = loop.run(scenario)
        results.append({"id": scenario["id"], "question": scenario["question"], "answer": answer.render(), "sources": answer.sources})
    return results, tools


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--searchd", required=True, help="path to the searchd binary")
    parser.add_argument("--index", help="an index folder; default: the fixture, indexed into a temporary folder")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as scratch:
        index = Path(args.index) if args.index else Path(scratch) / "index"
        if not args.index:
            build_fixture_index(args.searchd, index)
        results, tools = run_all(args.searchd, index)
        tools.close()
    for item in results:
        print(f"Q: {item['question']}\n{item['answer']}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
