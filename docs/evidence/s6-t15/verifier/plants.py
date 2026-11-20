#!/usr/bin/env python3
"""S6-T15 verifier: plants. Each plant is a fresh `git archive` of the head with its own
local and global Zig cache; the copy's own checker runs, then `zig build test --summary all`
(Debug). Run: python3 -I plants.py WORKTREE COMMIT VSCRATCH NAME [NAME ...]  (or `all`)."""
import os, re, subprocess, sys, time
from pathlib import Path

WT, COMMIT, V = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
NAMES = sys.argv[4:]
FAIL = "try @import(\"std\").testing.expectEqual(@as(u32, 1), @as(u32, 2));"


def target(name):
    return f"// verifier plant target\ntest \"{name} target fails\" {{\n    {FAIL}\n}}\n"


def add(src, rel, text):
    p = src / "zig/src" / rel
    p.write_text(text, encoding="utf-8")


def append(src, rel, text):
    p = src / "zig/src" / rel
    p.write_text(p.read_text(encoding="utf-8") + text, encoding="utf-8")


def replace(src, rel, old, new):
    p = src / "zig/src" / rel if not rel.startswith("zig/") else src / rel
    t = p.read_text(encoding="utf-8")
    assert t.count(old) == 1, (rel, old)
    p.write_text(t.replace(old, new), encoding="utf-8")


def in_root(src, mod):
    append(src, "tests/root.zig", f"\npub const {mod} = @import(\"{mod}.zig\");\ntest {{\n    _ = {mod};\n}}\n")


def mid(src, letter, body):
    """tests/plant_<l>_mid_test.zig holding body, named by tests/root.zig; the target fails."""
    m = f"plant_{letter}_mid_test"
    add(src, f"tests/{m}.zig", body)
    add(src, f"tests/plant_{letter}_target_test.zig", target(f"plant {letter}"))
    in_root(src, m)


PLANTS = {
    "baseline": lambda s: None,
    # A: a test inside a nested struct nothing references
    "A-nested-unref": lambda s: (add(s, "tests/plant_a_test.zig",
        "const std = @import(\"std\");\ntest \"plant a top\" {}\nconst Unused = struct {\n"
        f"    test \"plant a nested fails\" {{\n        {FAIL}\n    }}\n}};\n"), in_root(s, "plant_a_test")),
    # B: a test inside a generic type, instantiated by a test
    "B-generic": lambda s: (add(s, "tests/plant_b_test.zig",
        "const std = @import(\"std\");\nfn Gen(comptime T: type) type {\n    return struct {\n"
        "        pub const t = T;\n"
        f"        test \"plant b generic fails\" {{\n            {FAIL}\n        }}\n    }};\n}}\n"
        "test \"plant b instantiates\" {\n    _ = Gen(u8);\n    try std.testing.expect(Gen(u8).t == u8);\n}\n"),
        in_root(s, "plant_b_test")),
    # C: an import used only in a function a test names but never calls
    "C-fn-named-not-called": lambda s: mid(s, "c",
        "const target = @import(\"plant_c_target_test.zig\");\nfn helper() void {\n    _ = target;\n}\n"
        "test \"plant c names helper\" {\n    _ = helper;\n}\n"),
    # D: an import used only in a method of a struct a test uses; the method is never called
    "D-method-uncalled": lambda s: mid(s, "d",
        "const std = @import(\"std\");\nconst target = @import(\"plant_d_target_test.zig\");\n"
        "const Helper = struct {\n    x: u32 = 0,\n    fn touch() void {\n        _ = target;\n    }\n};\n"
        "test \"plant d uses Helper\" {\n    const h = Helper{};\n    try std.testing.expectEqual(@as(u32, 0), h.x);\n}\n"),
    # E: a comptime block guarded by if (false)
    "E-comptime-if-false": lambda s: mid(s, "e",
        "const target = @import(\"plant_e_target_test.zig\");\ncomptime {\n    if (false) {\n        _ = target;\n    }\n}\n"
        "test \"plant e\" {}\n"),
    # F: a comptime block guarded by !builtin.is_test (the roots' guard, inverted)
    "F-comptime-not-is-test": lambda s: mid(s, "f",
        "const target = @import(\"plant_f_target_test.zig\");\ncomptime {\n    if (!@import(\"builtin\").is_test) {\n"
        "        _ = target;\n    }\n}\ntest \"plant f\" {}\n"),
    # G: an import in a pub const that only a pub non-test function uses
    "G-pub-const-nontest-fn": lambda s: mid(s, "g",
        "pub const target = @import(\"plant_g_target_test.zig\");\npub fn helper() void {\n    _ = target;\n}\n"
        "test \"plant g\" {}\n"),
    # H: `_ = @import(path)` inside a test of another module's file (interfaces/), not named in its root
    "H-path-in-other-module-test": lambda s: (add(s, "interfaces/plant_h_test.zig", target("plant h")),
        append(s, "interfaces/field_warnings_test.zig", "\ntest \"plant h reach\" {\n    _ = @import(\"plant_h_test.zig\");\n}\n")),
    # I: refAllDecls in a file named by the root; a nested file reached only through it
    "I-refAllDecls": lambda s: (add(s, "tests/plant_i_mid_test.zig",
        "const std = @import(\"std\");\npub const inner = @import(\"plant_i_inner_test.zig\");\n"
        "test \"plant i refs\" {\n    std.testing.refAllDecls(@This());\n}\n"),
        add(s, "tests/plant_i_inner_test.zig",
            "const deep = @import(\"plant_i_target_test.zig\");\ntest \"plant i inner\" {\n    _ = deep;\n}\n"),
        add(s, "tests/plant_i_target_test.zig", target("plant i")), in_root(s, "plant_i_mid_test")),
    # J: a file imported by path from two modules (core's root and a tests/ file)
    "J-two-modules": lambda s: (add(s, "core/plant_j_test.zig", target("plant j")),
        replace(s, "core/core.zig", "pub const fold_test = @import(\"fold_test.zig\");",
                "pub const fold_test = @import(\"fold_test.zig\");\npub const plant_j_test = @import(\"plant_j_test.zig\");"),
        replace(s, "core/core.zig", "        _ = fold_test;\n", "        _ = fold_test;\n        _ = plant_j_test;\n"),
        add(s, "tests/plant_j_mid_test.zig", "test \"plant j mid\" {\n    _ = @import(\"../core/plant_j_test.zig\");\n}\n"),
        in_root(s, "plant_j_mid_test")),
    # K: usingnamespace
    "K-usingnamespace": lambda s: mid(s, "k",
        "pub usingnamespace @import(\"plant_k_target_test.zig\");\ntest \"plant k\" {}\n"),
    # L: a test file reached only from a benchmark's test
    "L-bench-only": lambda s: (add(s, "tests/plant_l_target_test.zig", target("plant l")),
        append(s, "tests/fold_bench.zig", "\ntest \"plant l reach\" {\n    _ = @import(\"plant_l_target_test.zig\");\n}\n")),
    # M: a struct field with the import's name, in a test
    "M-field-name": lambda s: mid(s, "m",
        "const std = @import(\"std\");\nconst helpers = @import(\"plant_m_target_test.zig\");\n"
        "test \"plant m\" {\n    const S = struct { helpers: u32 = 0 };\n    const v = S{};\n"
        "    try std.testing.expectEqual(@as(u32, 0), v.helpers);\n}\n"),
    # R: an import as a declaration of a nested struct a test names
    "R-import-in-named-struct": lambda s: mid(s, "r",
        "const Fixture = struct {\n    const data = @import(\"plant_r_target_test.zig\");\n    pub const n: u32 = 3;\n};\n"
        "test \"plant r uses Fixture\" {\n    try @import(\"std\").testing.expectEqual(@as(u32, 3), Fixture.n);\n}\n"),
    # Y: check 5, docs/layers.md's "A new test" followed literally for ops/
    "Y-doc-ops": lambda s: (add(s, "ops/report_doc_test.zig",
        "const std = @import(\"std\");\nconst report = @import(\"report.zig\");\n"
        f"test \"doc-followed ops test fails on purpose\" {{\n    _ = report;\n    {FAIL}\n}}\n"),
        replace(s, "ops/operations.zig", "pub const report = @import(\"report.zig\");\n",
                "pub const report = @import(\"report.zig\");\npub const report_doc_test = @import(\"report_doc_test.zig\");\n"),
        replace(s, "ops/operations.zig", "        _ = report;\n", "        _ = report;\n        _ = report_doc_test;\n")),
    # Build-file mutations (check 2)
    "X-remove-core-row": lambda s: replace(s, "zig/build.zig",
        "        .{ .name = \"core\", .path = \"src/core/core.zig\" },\n", ""),
    "X-remove-fastmem-step": lambda s: replace(s, "zig/build.zig",
        "    test_step.dependOn(&b.addRunArtifact(fastmem_tests).step);\n", "    _ = fastmem_tests;\n"),
    "X-copy-paste-ops-row": lambda s: replace(s, "zig/build.zig",
        ".{ .name = \"operations\", .path = \"src/ops/operations.zig\" }",
        ".{ .name = \"operations\", .path = \"src/core/core.zig\" }"),
    "X-remove-tests-row": lambda s: replace(s, "zig/build.zig",
        "        .{ .name = \"tests\", .path = \"src/tests/root.zig\" },\n", ""),
    "X-change-tests-root": lambda s: (replace(s, "zig/build.zig", "\"src/tests/root.zig\"", "\"src/tests/root2.zig\""),
        (s / "zig/src/tests/root2.zig").write_bytes((s / "zig/src/tests/root.zig").read_bytes())),
    "X-add-test-step": lambda s: (replace(s, "zig/build.zig",
        "        .{ .name = \"tests\", .path = \"src/tests/root.zig\" },\n",
        "        .{ .name = \"tests\", .path = \"src/tests/root.zig\" },\n        .{ .name = \"extra\", .path = \"src/tests/extra_test.zig\" },\n"),
        add(s, "tests/extra_test.zig", "test \"extra\" {}\n")),
}

CHECKER_ONLY = set(sys.argv[4:]) if False else set()


def run(name, build):
    d = V / "runs" / name
    if d.exists():
        print(f"{name}: {d} exists, skipped", flush=True)
        return
    src = d / "src"
    src.mkdir(parents=True)
    subprocess.run(f"git -C '{WT}' archive {COMMIT} | tar -x -C '{src}'", shell=True, check=True)
    PLANTS[name](src)
    diff = subprocess.run(["git", "diff", "--no-index", "--stat", str(V / "runs" / "pristine"), str(src)],
                          capture_output=True, text=True).stdout if (V / "runs" / "pristine").exists() else ""
    log = [f"# plant {name} on {COMMIT}", diff]
    ck = subprocess.run([sys.executable, "-I", str(src / "scripts/check_layers.py"), "--root", str(src), "--list-tests"],
                        capture_output=True, text=True)
    out = ck.stdout.replace(str(src), "<copy>")
    log += [f"## checker exit {ck.returncode}", "\n".join(l for l in out.splitlines()
            if not l.startswith("| `") or "plant" in l or "extra" in l), ck.stderr]
    if build:
        env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(d / "gc"))
        env.pop("SEARCH_SIMPLI_LIBRARY_PATH", None)
        t0 = time.time()
        zb = subprocess.run(["zig", "build", "test", "--summary", "all", "--cache-dir", str(d / "lc"),
                             "--global-cache-dir", str(d / "gc")], cwd=src / "zig", env=env,
                            capture_output=True, text=True)
        z = (zb.stdout + zb.stderr).replace(str(d), "<run>")
        keep = [l for l in z.splitlines() if re.search(r"Build Summary|run test|plant|extra|error:|failed|tests? passed", l)]
        log += [f"## zig build test exit {zb.returncode} ({time.time() - t0:.0f} s)", "\n".join(keep[:80])]
        (d / "zig-full.txt").write_text(z, encoding="utf-8")
    text = "\n".join(log) + "\n"
    (V / "logs").mkdir(exist_ok=True)
    (V / "logs" / f"{name}.txt").write_text(text, encoding="utf-8")
    print(text, flush=True)


if __name__ == "__main__":
    build = True
    names = list(PLANTS) if NAMES == ["all"] else NAMES
    if names and names[0] == "--no-build":
        build, names = False, names[1:]
    for n in names:
        run(n, build)
