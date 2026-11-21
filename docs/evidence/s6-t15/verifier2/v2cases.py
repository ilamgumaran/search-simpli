#!/usr/bin/env python3
"""S6-T15 second verifier: cases. Each case is a fresh `git archive COMMIT` with its own
local and global Zig cache. For each: the copy's own static checker
(`check_layers.py --list-tests`), then the copy's own count comparison
(`check_test_counts.py --run`, which runs `zig build test --summary all`, Debug).
A "lost" test always fails when it runs (expectEqual(1, 2)); every other planted test
passes, so a comparison exit 0 also shows the failing test did not run.

Usage: python3 -I v2cases.py WORKTREE COMMIT SCRATCH OUT [--static-only] NAME ... | all"""
import os
import re
import subprocess
import sys
import time
from pathlib import Path

WT, COMMIT, V, OUT = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3]), Path(sys.argv[4])
ARGS = sys.argv[5:]
STATIC_ONLY = "--static-only" in ARGS
NAMES = [a for a in ARGS if a != "--static-only"]
FAIL = 'try @import("std").testing.expectEqual(@as(u32, 1), @as(u32, 2));'
PASS = 'try @import("std").testing.expect(true);'


def target(name):
    return f"// v2 plant target: fails if it runs\ntest \"{name} target fails\" {{\n    {FAIL}\n}}\n"


def add(src, rel, text):
    (src / "zig/src" / rel).write_text(text, encoding="utf-8")


def append(src, rel, text):
    p = src / "zig/src" / rel
    p.write_text(p.read_text(encoding="utf-8") + text, encoding="utf-8")


def replace(src, rel, old, new):
    p = src / rel if rel.startswith(("zig/", "scripts/")) else src / "zig/src" / rel
    t = p.read_text(encoding="utf-8")
    assert t.count(old) == 1, (rel, old)
    p.write_text(t.replace(old, new), encoding="utf-8")


def in_root(src, mod):
    """docs/layers.md's way for tests/: a pub const in tests/root.zig and a line in its test block."""
    replace(src, "tests/root.zig", 'pub const direct_search_test = @import("direct_search_test.zig");\n',
            f'pub const direct_search_test = @import("direct_search_test.zig");\npub const {mod} = @import("{mod}.zig");\n')
    replace(src, "tests/root.zig", "    _ = direct_search_test;\n", f"    _ = direct_search_test;\n    _ = {mod};\n")


def mid(src, letter, body):
    m = f"plant_{letter}_mid_test"
    add(src, f"tests/{m}.zig", body)
    add(src, f"tests/plant_{letter}_target_test.zig", target(f"plant {letter}"))
    in_root(src, m)


def in_module_root(src, root, after_const, after_line, name):
    """docs/layers.md's way for core/, ops/, interfaces/: a pub const and a `_ = name;` line."""
    replace(src, root, after_const, after_const + f'pub const {name} = @import("{name}.zig");\n')
    replace(src, root, after_line, after_line + f"        _ = {name};\n")


FASTMEM_STEP = ("    // S4-T18: fastmem.zig's own tests, compiled as the object is (-fno-builtin).\n"
                "    const fastmem_tests = b.addTest(.{ .root_module = fastmemModule(b, target, optimize) });\n"
                "    test_step.dependOn(&b.addRunArtifact(fastmem_tests).step);\n")
FASTMEM_ROW = '    "core/fastmem.zig": ("fastmem", "the `fastmem` object, and its own test step (`run test` in the Build Summary)"),\n'


def c1(s):
    replace(s, "zig/build.zig", FASTMEM_STEP, "")
    replace(s, "scripts/check_layers.py", FASTMEM_ROW, '    "core/fastmem.zig": (None, "the `fastmem` object"),\n')
    subprocess.run([sys.executable, "-I", str(s / "scripts/check_layers.py"), "--root", str(s), "--write-doc"],
                   capture_output=True, text=True)


def c2(s):
    c1(s)
    append(s, "core/core.zig", '\npub const fastmem_kept = @import("fastmem.zig");\ncomptime {\n'
           '    if (@import("builtin").os.tag == .windows) {\n        _ = fastmem_kept;\n    }\n}\n')


CASES = {
    # (a) the baseline, run twice in the same copy (the second with a warm cache)
    "a-warm-rerun": lambda s: None,
    # (b1) a lenient miss and a strict surplus in the tests step: equal totals
    "b1-cancel-strict": lambda s: (
        mid(s, "b1", 'const enabled = false;\nconst target = @import("plant_b1_target_test.zig");\n'
                     "comptime {\n    if (enabled) {\n        _ = target;\n    }\n}\n"
                     f'test "plant b1 mid" {{\n    {PASS}\n}}\n'),
        add(s, "tests/plant_b1_extra_test.zig", f'test "plant b1 extra runs" {{\n    {PASS}\n}}\n'),
        add(s, "tests/plant_b1_helper_test.zig", 'const extra = @import("plant_b1_extra_test.zig");\n'
            "fn pull() void {\n    _ = extra;\n}\n" f'test "plant b1 helper calls pull" {{\n    pull();\n    {PASS}\n}}\n'),
        in_root(s, "plant_b1_helper_test")),
    # (b2) a lenient miss (a generic named, never instantiated) and a surplus the static rule
    # does not see (a generic instantiated twice runs its test twice), in one new file
    "b2-cancel-generic": lambda s: (add(s, "tests/plant_b2_test.zig",
        'const std = @import("std");\n'
        "fn Ring(comptime T: type) type {\n    return struct {\n        pub const Item = T;\n"
        '        test "plant b2 ring" {\n            try std.testing.expect(@sizeOf(Item) > 0);\n        }\n    };\n}\n'
        "fn Queue(comptime T: type) type {\n    return struct {\n        pub const Item = T;\n"
        f'        test "plant b2 queue fails" {{\n            {FAIL}\n        }}\n    }};\n}}\n'
        'test "plant b2 rings of two types" {\n    try std.testing.expect(Ring(u8).Item == u8);\n'
        "    try std.testing.expect(Ring(u32).Item == u32);\n}\n"
        'test "plant b2 queue" {\n    _ = Queue;\n}\n'), in_root(s, "plant_b2_test")),
    # (c1) fastmem's step removed from zig/build.zig and its BUILD_ROOTS step set to None
    "c1-roots-hide": c1,
    # (c2) c1, and fastmem.zig named in core.zig under a platform guard so the checker counts it
    "c2-roots-hide-guard": c2,
    # (d) three of the first verifier's dangerous plants, verbatim
    "A-nested-unref": lambda s: (add(s, "tests/plant_a_test.zig",
        "const std = @import(\"std\");\ntest \"plant a top\" {}\nconst Unused = struct {\n"
        f"    test \"plant a nested fails\" {{\n        {FAIL}\n    }}\n}};\n"), in_root(s, "plant_a_test")),
    "E-comptime-if-false": lambda s: mid(s, "e",
        "const target = @import(\"plant_e_target_test.zig\");\ncomptime {\n    if (false) {\n        _ = target;\n    }\n}\n"
        "test \"plant e\" {}\n"),
    "R-import-in-named-struct": lambda s: mid(s, "r",
        "const Fixture = struct {\n    const data = @import(\"plant_r_target_test.zig\");\n    pub const n: u32 = 3;\n};\n"
        "test \"plant r uses Fixture\" {\n    try @import(\"std\").testing.expectEqual(@as(u32, 3), Fixture.n);\n}\n"),
    # (d) four new ones aimed at the tightened rule, dangerous direction
    "N1-const-false-switch": lambda s: mid(s, "n1",
        'const enabled = false;\nconst target = @import("plant_n1_target_test.zig");\n'
        "comptime {\n    if (enabled) {\n        _ = target;\n    }\n}\n" f'test "plant n1" {{\n    {PASS}\n}}\n'),
    "N2-generic-uninstantiated": lambda s: (add(s, "tests/plant_n2_test.zig",
        'const std = @import("std");\nfn Pool(comptime T: type) type {\n    return struct {\n        items: []T,\n'
        f'        test "plant n2 generic fails" {{\n            {FAIL}\n        }}\n    }};\n}}\n'
        'test "plant n2 names Pool" {\n    _ = Pool;\n}\n'), in_root(s, "plant_n2_test")),
    "N3-alias-in-struct": lambda s: (add(s, "tests/plant_n3_test.zig",
        'const std = @import("std");\nconst Unused = struct {\n'
        f'    test "plant n3 nested fails" {{\n        {FAIL}\n    }}\n}};\n'
        "const Holder = struct {\n    const alias = Unused;\n    pub const n: u32 = 3;\n};\n"
        'test "plant n3 names Holder" {\n    _ = Holder;\n    try std.testing.expectEqual(@as(u32, 3), Holder.n);\n}\n'),
        in_root(s, "plant_n3_test")),
    "N4-build-loop-continue": lambda s: replace(s, "zig/build.zig", "    for (test_roots) |root| {\n",
        "    for (test_roots) |root| {\n        if (std.mem.eql(u8, root.name, \"operations\")) continue;\n"),
    # (e) three of the six build-file edits, verbatim
    "X-remove-core-row": lambda s: replace(s, "zig/build.zig",
        "        .{ .name = \"core\", .path = \"src/core/core.zig\" },\n", ""),
    "X-remove-fastmem-step": lambda s: replace(s, "zig/build.zig",
        "    test_step.dependOn(&b.addRunArtifact(fastmem_tests).step);\n", "    _ = fastmem_tests;\n"),
    "X-copy-paste-ops-row": lambda s: replace(s, "zig/build.zig",
        ".{ .name = \"operations\", .path = \"src/ops/operations.zig\" }",
        ".{ .name = \"operations\", .path = \"src/core/core.zig\" }"),
    # check 3: docs/layers.md's "A new test" followed literally; every planted test passes
    "doc-core": lambda s: (add(s, "core/doc_new_test.zig", 'const std = @import("std");\nconst scoring = @import("scoring.zig");\n'
        f'test "v2 doc-followed core test" {{\n    _ = scoring;\n    {PASS}\n}}\n'),
        in_module_root(s, "core/core.zig", 'pub const verb_forms_test = @import("verb_forms_test.zig");\n',
                       "        _ = verb_forms_test;\n", "doc_new_test")),
    "doc-ops": lambda s: (add(s, "ops/doc_new_test.zig", 'const std = @import("std");\nconst report = @import("report.zig");\n'
        f'test "v2 doc-followed ops test" {{\n    _ = report;\n    {PASS}\n}}\n'),
        in_module_root(s, "ops/operations.zig", 'pub const service = @import("service.zig");\n',
                       "        _ = service;\n", "doc_new_test")),
    "doc-interfaces": lambda s: (add(s, "interfaces/doc_new_test.zig", 'const std = @import("std");\nconst cli = @import("cli.zig");\n'
        f'test "v2 doc-followed interfaces test" {{\n    _ = cli;\n    {PASS}\n}}\n'),
        in_module_root(s, "interfaces/interfaces.zig", 'pub const rpc = @import("rpc.zig");\n',
                       "        _ = rpc;\n", "doc_new_test")),
    "doc-tests": lambda s: (add(s, "tests/doc_new_test.zig", 'const std = @import("std");\n'
        'const scoring = @import("core").scoring;\nconst report = @import("operations").report;\n'
        f'test "v2 doc-followed cross-layer test" {{\n    _ = scoring;\n    _ = report;\n    {PASS}\n}}\n'),
        in_root(s, "doc_new_test")),
    "doc-infile-core": lambda s: append(s, "core/scoring.zig",
        f'\ntest "v2 in-file scoring test" {{\n    {PASS}\n}}\n'),
}


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def count_run(src, d, env, tag):
    t0 = time.time()
    cc = sh([sys.executable, "-I", str(src / "scripts/check_test_counts.py"), "--root", str(src), "--run",
             "--", "--cache-dir", str(d / "lc"), "--global-cache-dir", str(d / "gc")], env=env)
    secs = time.time() - t0
    full = (cc.stdout + cc.stderr).replace(str(d), "<run>")
    (d / f"count-full-{tag}.txt").write_text(full, encoding="utf-8")
    lines = full.splitlines()
    at = max((i for i, line in enumerate(lines) if line.startswith("Build Summary:")), default=None)
    summary = [] if at is None else lines[at:at + 2] + [l for l in lines[at:] if l.startswith("+- run test")]
    ran_plants = [l.strip() for l in lines if re.search(r"(plant|v2 )[^\n]*(fail|FAIL|error)", l)][:6]
    errors = [l for l in lines if "error:" in l[:120]][:6]
    table = [l for l in lines if l.startswith("| ") or l.startswith("check_test_counts:")]
    return [f"## count comparison ({tag}): check_test_counts.py --run (Debug), exit {cc.returncode} ({secs:.0f} s)",
            "\n".join(summary) if summary else "(no Build Summary)",
            *(["planted-test lines in the output:", *ran_plants] if ran_plants else []),
            *(["first errors:", *errors] if errors else []),
            "", "\n".join(table)], cc.returncode


def run(name):
    d = V / "runs" / name
    if d.exists():
        print(f"{name}: {d} exists, skipped", flush=True)
        return
    src = d / "src"
    src.mkdir(parents=True)
    subprocess.run(f"git -C '{WT}' archive {COMMIT} | tar -x -C '{src}'", shell=True, check=True)
    pristine = d / "pristine"
    pristine.mkdir()
    subprocess.run(f"git -C '{WT}' archive {COMMIT} zig scripts docs | tar -x -C '{pristine}'", shell=True, check=True)
    CASES[name](src)
    diffs = []
    for part in ("zig", "scripts", "docs"):
        out = sh(["git", "diff", "--no-index", str(pristine / part), str(src / part)]).stdout
        diffs.append(out.replace(str(pristine), "a").replace(str(src), "b"))
    diff = "".join(diffs)
    log = [f"# {name} on {COMMIT}", "## diff against the archive", diff.rstrip() if len(diff) < 6000 else diff[:6000] + "\n(cut)"]
    env = {k: v for k, v in os.environ.items() if k != "SEARCH_SIMPLI_LIBRARY_PATH"}
    env["ZIG_GLOBAL_CACHE_DIR"] = str(d / "gc")
    ck = sh([sys.executable, "-I", str(src / "scripts/check_layers.py"), "--root", str(src), "--list-tests"], env=env)
    keep = [l for l in ck.stdout.splitlines()
            if not l.startswith("| `") or re.search(r"plant|doc_new|scoring|fastmem", l)]
    log += [f"## static checker (check_layers.py --list-tests) exit {ck.returncode}",
            "\n".join(keep).replace(str(src), "<copy>"), ck.stderr.replace(str(src), "<copy>").rstrip()]
    if not STATIC_ONLY:
        part, _ = count_run(src, d, env, "first")
        log += part
        if name == "a-warm-rerun":
            part, _ = count_run(src, d, env, "second, warm cache, same copy")
            log += part
    text = "\n".join(log) + "\n"
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f"{name}.txt").write_text(text, encoding="utf-8")
    print(text, flush=True)


if __name__ == "__main__":
    for n in (list(CASES) if NAMES == ["all"] else NAMES):
        run(n)
