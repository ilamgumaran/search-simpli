"""S6-T10 verifier: my ruling-1 plants, written from the head's text. Each anchor must occur once.
py_plants.py COPY NAME  (COPY is a scratch copy of the head's tests/, skills/, contracts/ ...)"""
import json
import sys
from pathlib import Path

copy, name = Path(sys.argv[1]), sys.argv[2]
SKILL = copy / "skills" / "folder-knowledge" / "SKILL.md"
LOOP = copy / "skills" / "folder-knowledge" / "example_loop.py"
REQ = copy / "contracts" / "tools" / "read_span.request.schema.json"
RES = copy / "contracts" / "tools" / "read_span.result.schema.json"


def text(path, old, new):
    s = path.read_text(encoding="utf-8")
    assert s.count(old) == 1, (name, path.name, s.count(old))
    assert old != new
    path.write_text(s.replace(old, new), encoding="utf-8")


def rename(path, old, new):
    # the property key and its entry in `required`, nothing else
    s = path.read_text(encoding="utf-8")
    assert s.count(f'"{old}"') == 2 and f'"{new}"' not in s, (name, s.count(f'"{old}"'))
    path.write_text(s.replace(f'"{old}"', f'"{new}"'), encoding="utf-8")
    d = json.loads(path.read_text(encoding="utf-8"))
    assert new in d["properties"] and new in d["required"] and old not in d["properties"]


if name == "w-mention2-root":
    # the second place the skill names read_span (step 2, a name-only match) says `root`
    text(SKILL, "`read_span`) before quoting anything from it",
         "`read_span` with the result's `root` and `path`) before quoting anything from it")
elif name == "w-step3-after-clause":
    # step 3 itself, the sentence after the call clause, names `root`
    text(SKILL, "Use `context_lines` when the answer is the line after",
         "Send `root` and `context_lines` when the answer is the line after")
elif name == "w-json-example":
    # a read_span example in the skill outside example_loop.py, sending `root`
    text(SKILL, "python3 skills/folder-knowledge/example_loop.py --searchd /path/to/searchd\n```",
         "python3 skills/folder-knowledge/example_loop.py --searchd /path/to/searchd\n```\n\n"
         "A `read_span` call as the loop sends it:\n\n```json\n"
         '{"name": "read_span", "arguments": {"root": "r1", "path": "notes/kite.md", "start_line": 4, "end_line": 6}}\n```')
elif name == "w-optional-end":
    # a required field made optional in the skill's wording
    text(SKILL, "`start_line` and `end_line` (from a", "`start_line` and optionally `end_line` (from a")
elif name == "w-row-root":
    # the tools table's read_span row says it takes `root`
    text(SKILL, "exact lines of a file, with `context_lines` (0 to 20)",
         "exact lines of a file, with `root`, `path` and `context_lines` (0 to 20)")
elif name == "w-result-rename":
    # a field renamed in the result schema (the row still says `context_before`)
    rename(RES, "context_before", "context_prior")
elif name == "w-request-rename-start":
    # a request field renamed in the request schema (the skill still says `start_line`)
    rename(REQ, "start_line", "first_line")
elif name == "w-loop-constant":
    # one example_loop.py read_span call made through a module constant, sending `root`
    text(LOOP, 'span = self.tools.call("read_span", root_id=hit["root_id"], path=hit["path"],',
         'span = self.tools.call(READ_SPAN, root=hit["root_id"], path=hit["path"],')
    text(LOOP, "def questions() -> list[dict]:", 'READ_SPAN = "read_span"\n\n\ndef questions() -> list[dict]:')
elif name == "w-context-misnamed":
    # step 3's own read_span request field after the call clause, misnamed as S5-T10's agent might
    text(SKILL, "Use `context_lines` when the answer is the line after", "Use `context` when the answer is the line after")
elif name == "y-step3-hit-chunk-id":
    # step 3's "from a find hit" list adds a real field of find and read_chunk, put to read_span
    text(SKILL, "`find` hit, its `root_id` and `path`;", "`find` hit, its `root_id`, `path` and `chunk_id`;")
elif name == "y-step2-section-path":
    # step 2's read_span mention sends search_knowledge's `section_path` (a tool the bullet names)
    text(SKILL, "`read_span`) before quoting anything from it",
         "`read_span` with the result's `root_id`, `path` and `section_path`) before quoting anything from it")
elif name == "y-row-byte-exact":
    # the tools row offers read_span's result field `byte_exact` as something it takes
    text(SKILL, "exact lines of a file, with `context_lines` (0 to 20)",
         "exact lines of a file, with `context_lines` (0 to 20) and `byte_exact`")
elif name == "y-step3-single-line":
    # step 3 offers `line` (an outline field; step 3 names outline) for a single line
    text(SKILL, "Use `context_lines` when the answer is the line after",
         "Use `line` for a single line, and `context_lines` when the answer is the line after")
else:
    raise SystemExit(f"no plant {name}")
print("planted", name)
