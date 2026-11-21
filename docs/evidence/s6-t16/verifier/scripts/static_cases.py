"""Verifier's static guard cases for S6-T16: each case in its own fresh copy of a
`git archive` of the head, the checker run from that copy. Prints a table.

usage: static_cases.py PRISTINE_DIR WORK_DIR
PRISTINE_DIR holds the extracted archive; each case copies it to WORK_DIR/<id>.
"""
import shutil
import subprocess
import sys
from pathlib import Path

PRISTINE, WORK = Path(sys.argv[1]), Path(sys.argv[2])

R = "zig/src/ops/report.zig"
M = "zig/src/interfaces/mcp.zig"
SV = "zig/src/ops/service.zig"
OPS = "zig/src/ops/ops.zig"
CC = "zig/src/core/core.zig"
FW = "zig/src/interfaces/field_warnings_test.zig"

# (id, description, expected guard result, edits) ; edit = (file, "append", text) or (file, "replace", old, new)
CASES = [
    ("S01", "inline `@import(\"core\").engine.Engine` in ops/", "FAIL",
     [(R, "append", '\ntest "v leak" { _ = @import("core").engine.Engine; }\n')]),
    ("S02", "`const c = @import(\"core\"); c.engine.Engine` in interfaces/", "FAIL",
     [(M, "append", '\nconst v_c = @import("core");\ntest "v leak" { _ = v_c.engine.Engine; }\n')]),
    ("S03", "alias chain: `a = core.api; e = a.engine; i = core; j = i; j.lifecycle.scan`", "FAIL",
     [(R, "append", '\nconst v_a = @import("core").api;\nconst v_e = v_a.engine;\nconst v_i = @import("core");\n'
                     'const v_j = v_i;\ntest "v leak" { _ = v_e.Engine; _ = v_j.lifecycle.scan; }\n')]),
    ("S04", "`@field(@import(\"core\"), \"engine\").Engine`", "FAIL",
     [(R, "append", '\ntest "v leak" { _ = @field(@import("core"), "engine").Engine; }\n')]),
    ("S05", "`const c = @import(\"core\"); @field(c, \"lifecycle\")`", "FAIL",
     [(R, "append", '\nconst v_c = @import("core");\ntest "v leak" { _ = @field(v_c, "lifecycle").scan; }\n')]),
    ("S06", "published type's member: `api.engine.Engine.open` (bypasses snapshot_open)", "PASS (admitted: deeper members not read)",
     [(R, "append", '\ntest "v leak" { _ = @import("core").api.engine.Engine.open; }\n')]),
    ("S07", "`usingnamespace @import(\"core\");` in a struct", "FAIL",
     [(R, "append", '\nconst v_ns = struct {\n    usingnamespace @import("core");\n};\n')]),
    ("S08", "import inside a function body, aliased there", "FAIL",
     [(R, "append", '\nfn vLeak() void {\n    const e = @import("core").lifecycle;\n    _ = e.scan;\n}\n')]),
    ("S09", "multi-line `@import(\\n \"core\" ,\\n)\\n.engine\\n.Engine`", "FAIL",
     [(R, "append", '\ntest "v leak" {\n    _ = @import(\n        "core" ,\n    )\n        .engine\n        .Engine;\n}\n')]),
    ("S10", "core names in a comment, a doc comment, a string and a multiline string", "PASS",
     [(R, "append", '\n// @import("core").engine.Engine\n/// see @import("core").lifecycle\n'
                     'const v_s = "@import(\\"core\\").engine";\nconst v_m =\n    \\\\@import("core").scope.Folder\n;\n')]),
    ("S11", "published namespace, unpublished name, through an alias: `sc = api.scope; sc.Statistics`", "FAIL",
     [(R, "append", '\nconst v_sc = @import("core").api.scope;\ntest "v leak" { _ = v_sc.Statistics; }\n')]),
    ("S12", "`@import(\"core\").internal.engine` (the root's `@This()`), inline", "FAIL (or Zig refuses)",
     [(R, "append", '\ntest "v leak" { _ = @import("core").internal.engine.Engine; }\n')]),
    ("S13", "`const c = @import(\"core\"); c.internal.lifecycle.scan` (through an alias)", "Zig must refuse (not pub)",
     [(R, "append", '\nconst v_c = @import("core");\ntest "v leak" { _ = v_c.internal.lifecycle.scan; }\n')]),
    ("S14", "relative path `@import(\"../core/lifecycle.zig\")` from ops/", "FAIL",
     [(R, "append", '\ntest "v leak" { _ = @import("../core/lifecycle.zig").scan; }\n')]),
    ("S15", "the module wrapped in a local struct: `deps = struct { const c = @import(\"core\"); }; deps.c.lifecycle.scan`", "? (predicted PASS: leak)",
     [(R, "append", '\nconst v_deps = struct {\n    const c = @import("core");\n};\ntest "v leak" { _ = v_deps.c.lifecycle.scan; }\n')]),
    ("S16", "re-export across files: service.zig `pub const v_all = @import(\"core\");`, ops.zig `service_module.v_all.lifecycle.scan`", "? (predicted PASS: leak)",
     [(SV, "append", '\npub const v_all = @import("core");\n'),
      (OPS, "append", '\ntest "v leak" { _ = service_module.v_all.lifecycle.scan; }\n')]),
    ("S17", "re-export reached from interfaces: `@import(\"operations\").service.v_all.lifecycle.scan`", "? (predicted PASS: leak)",
     [(SV, "append", '\npub const v_all = @import("core");\n'),
      (M, "append", '\ntest "v leak" { _ = @import("operations").service.v_all.lifecycle.scan; }\n')]),
    ("S18", "typed binding `const c: type = @import(\"core\"); c.engine`", "FAIL",
     [(R, "append", '\nconst v_c: type = @import("core");\ntest "v leak" { _ = v_c.engine.Engine; }\n')]),
    ("S19", "escaped import string `@import(\"\\x63ore\").lifecycle.scan`", "FAIL",
     [(R, "append", '\ntest "v leak" { _ = @import("\\x63ore").lifecycle.scan; }\n')]),
    ("S20", "a core test file through an alias: `c = @import(\"core\"); c.chunker_test`", "? (predicted PASS)",
     [(R, "append", '\nconst v_c = @import("core");\ntest "v leak" { _ = v_c.chunker_test; }\n')]),
    ("S21", "a core test file inline: `@import(\"core\").chunker_test`", "FAIL",
     [(R, "append", '\ntest "v leak" { _ = @import("core").chunker_test; }\n')]),
    ("S22", "alias bound with `var`/`comptime var`: `comptime var` is not allowed at container level; `pub const` alias then `.` use", "FAIL",
     [(R, "append", '\npub const v_c = @import("core");\ntest "v leak" { _ = v_c.lifecycle.scan; }\n')]),
    ("S23", "core module passed to a comptime function: `get(@import(\"core\"))`", "FAIL",
     [(R, "append", '\nfn vGet(comptime m: type) type { return m.lifecycle; }\ntest "v leak" { _ = vGet(@import("core")).scan; }\n')]),
    ("S24", "api passed to a comptime function, then a name api lacks: `get(@import(\"core\").api).lifecycle.scan`", "PASS (Zig refuses)",
     [(R, "append", '\nfn vGet(comptime m: type) type { return m.lifecycle; }\ntest "v leak" { _ = vGet(@import("core").api).scan; }\n')]),
    ("S25", "field_warnings_test.zig (interfaces/, a test file) `@import(\"core\").lifecycle.scan`", "FAIL",
     [(FW, "append", '\ntest "v leak" { _ = @import("core").lifecycle.scan; }\n')]),
    ("S26", "parenthesised: `const c = (@import(\"core\")); c.lifecycle`", "FAIL",
     [(R, "append", '\nconst v_c = (@import("core"));\ntest "v leak" { _ = v_c.lifecycle.scan; }\n')]),
    ("S27", "@TypeOf / @typeInfo of the root: `@typeInfo(@import(\"core\"))`", "FAIL",
     [(R, "append", '\ntest "v leak" { _ = @typeInfo(@import("core")); }\n')]),
    # api itself
    ("A01", "core.zig: an api entry that is a wrapper, not an alias", "FAIL",
     [(CC, "replace", "        pub const isLegacy = internal.scope.isLegacy;",
       "        pub fn isLegacy(root_id: []const u8) bool {\n            return internal.scope.isLegacy(root_id);\n        }")]),
    ("A02", "core.zig: an entry aliased to another file's name (`scope.Folder = internal.engine.Engine`)", "FAIL",
     [(CC, "replace", "pub const Folder = internal.scope.Folder;", "pub const Folder = internal.engine.Engine;")]),
    ("A03", "core.zig: a whole internal file as a namespace (`pub const lexical_build = internal.lexical_build;`) with doc comment", "FAIL",
     [(CC, "replace", "pub const api = struct {\n", "pub const api = struct {\n    /// v.\n    pub const lexical_build = internal.lexical_build;\n")]),
    ("A04", "core.zig: `internal` made `pub`", "? (predicted PASS)",
     [(CC, "replace", "\nconst internal = @This();", "\npub const internal = @This();")]),
    ("A05", "core.zig: an api namespace that re-exports the root: `pub const all = internal;` inside a namespace", "FAIL",
     [(CC, "replace", "        pub const legacy_root_id = internal.scope.legacy_root_id;",
       "        pub const legacy_root_id = internal.scope.legacy_root_id;\n        /// v.\n        pub const all = internal;")]),
]


def apply(dst, edits):
    for e in edits:
        if e[0] == "@write-doc":
            r = subprocess.run([sys.executable, "-I", str(dst / "scripts/check_layers.py"), "--write-doc"], capture_output=True, text=True)
            print("   --write-doc exit", r.returncode, r.stdout.strip()[:200])
            continue
        p = dst / e[0]
        if e[1] == "create":
            p.write_text(e[2], encoding="utf-8")
            continue
        t = p.read_text(encoding="utf-8")
        if e[1] == "append":
            t = t + e[2]
        else:
            assert t.count(e[2]) == 1, (e[0], e[2])
            t = t.replace(e[2], e[3])
        p.write_text(t, encoding="utf-8")


PEEK = open(Path(__file__).resolve().parent.parent / "peek.zig").read()
REG = [("scripts/check_layers.py", "replace",
        '    "interfaces/mcp.zig": ("interfaces", "`searchd mcp`: the Model Context Protocol server over stdio"),\n',
        '    "interfaces/mcp.zig": ("interfaces", "`searchd mcp`: the Model Context Protocol server over stdio"),\n'
        '    "interfaces/peek.zig": ("interfaces", "the core-api.md example: one find request"),\n'),
       ("zig/src/interfaces/interfaces.zig", "replace", 'pub const mcp = @import("mcp.zig");\n',
        'pub const mcp = @import("mcp.zig");\npub const peek = @import("peek.zig");\n'),
       ("zig/src/interfaces/interfaces.zig", "replace", "        _ = mcp;\n", "        _ = mcp;\n        _ = peek;\n")]
STATS_DOC = ("zig/src/core/core.zig", "replace", "        pub const legacy_root_id = internal.scope.legacy_root_id;\n",
             "        pub const legacy_root_id = internal.scope.legacy_root_id;\n"
             "        /// A request's visible-scope statistics (verifier's added name).\n"
             "        pub const Statistics = internal.scope.Statistics;\n")
STATS_NODOC = ("zig/src/core/core.zig", "replace", "        pub const legacy_root_id = internal.scope.legacy_root_id;\n",
               "        pub const legacy_root_id = internal.scope.legacy_root_id;\n"
               "        pub const Statistics = internal.scope.Statistics;\n")
USE_STATS = (R, "append", '\nconst v_sc = @import("core").api.scope;\ntest "v use" { _ = v_sc.Statistics; }\n')
NEW_NS = ("zig/src/core/core.zig", "replace", "    /// Misspelling tolerance at query time (`fuzzy.zig`).\n",
          "    /// The writer lock and the generations of a directory (verifier).\n"
          "    pub const lexical_build = struct {\n        /// v.\n        pub const NOPE_PLACEHOLDER = internal.lexical_build.NOPE_PLACEHOLDER;\n    };\n\n"
          "    /// Misspelling tolerance at query time (`fuzzy.zig`).\n")
CASES = [
    ("P01", "core-api.md's example, verbatim, as interfaces/peek.zig, registered as layers.md says, --write-doc", "PASS",
     [("zig/src/interfaces/peek.zig", "create", PEEK)] + REG + [("@write-doc",)]),
    ("P02", "the example without the --write-doc step", "FAIL (doc table stale)",
     [("zig/src/interfaces/peek.zig", "create", PEEK)] + REG),
    ("N01", "add-a-name rule followed literally: scope.Statistics with doc comment, used from ops/", "PASS",
     [STATS_DOC, USE_STATS]),
    ("N02", "same, doc comment forgotten", "FAIL",
     [STATS_NODOC, USE_STATS]),
    ("N03", "a new namespace without its doc comment, a name its file does not declare", "FAIL",
     [("zig/src/core/core.zig", "replace", "    /// Misspelling tolerance at query time (`fuzzy.zig`).\n",
       "    pub const lexical_build = struct {\n        /// v.\n        pub const NOPE = internal.lexical_build.NOPE;\n    };\n\n"
       "    /// Misspelling tolerance at query time (`fuzzy.zig`).\n")]),
] if len(sys.argv) > 3 else CASES

rows = []
for cid, desc, expect, edits in CASES:
    dst = WORK / cid
    assert not dst.exists(), dst
    shutil.copytree(PRISTINE, dst, symlinks=True)
    apply(dst, edits)
    r = subprocess.run([sys.executable, "-I", str(dst / "scripts/check_layers.py")], capture_output=True, text=True)
    lines = [l for l in (r.stdout + r.stderr).splitlines() if "check_layers: OK" not in l]
    verdict = "OK (passes)" if r.returncode == 0 else f"FAILS (exit {r.returncode})"
    rows.append((cid, desc, expect, verdict, lines))
    print(f"== {cid} | {desc} | expected {expect} | checker {verdict}")
    for l in lines[:6]:
        print("     ", l.replace(str(dst), "<case>")[:300])
