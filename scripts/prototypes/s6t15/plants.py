#!/usr/bin/env python3
"""S6-T15 ruling 1: the Zig plants, each a failing test placed so that
`zig build test` either runs it or does not, applied to a copy of the repository.

    python3 -I scripts/prototypes/s6t15/plants.py NAME COPY

NAME is one of:

- unnamed: the S6-T14 verifier's plant, verbatim: a new core/plant_unnamed_test.zig
  with a failing test, named in no root. Zig: not run. Checker: fails.
- module-only: a new core/plant_module_test.zig with a failing test, a `pub const`
  of core/core.zig but not in its test-build block, and compiled by tests/root.zig's
  test block through the module, `@import("core").plant_module_test`. Zig: not run
  (a test build runs its root module's tests only). Checker: fails.
- named: the same file, also in core/core.zig's test-build block. Zig: runs it, fails.
  Checker: passes.
- path-in-test: a new tests/plant_path_test.zig with a failing test, imported by path
  by tests/reload_test.zig and named in a test there. Zig: runs it. Checker: passes.
- unreferenced: a new tests/plant_unref_test.zig with a failing test, imported by
  tests/reload_test.zig at container level and named nowhere. Zig: not run.
  Checker: fails.
- via-function: a new tests/plant_fn_test.zig with a failing test, imported by a new
  tests/plant_mid_test.zig (no test of its own) and named only in a function of it,
  which a new test in tests/reload_test.zig calls. Zig: runs it. Checker: fails, the
  strict side it states (it does not follow a function of another file).
- words: a new tests/plant_words_test.zig whose only `test`s are in comments and
  strings, named in tests/root.zig's test block. Zig: no new test. Checker: passes
  and counts 0 tests in it.
"""
import sys
from pathlib import Path

FAILING = '''const std = @import("std");

test "plant {name}: a failing test" {{
    try std.testing.expectEqual(@as(u32, 1), 2);
}}
'''


def edit(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    assert text.count(old) == 1, (path, old)
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def main(name: str, copy: Path) -> int:
    src = copy / "zig" / "src"
    core_root, tests_root, reload_test = src / "core" / "core.zig", src / "tests" / "root.zig", src / "tests" / "reload_test.zig"
    if name == "unnamed":
        (src / "core" / "plant_unnamed_test.zig").write_text(
            'const std = @import("std");\nconst scoring = @import("scoring.zig");\n\n'
            'test "plant: a new core test named in no module root" {\n    _ = scoring;\n'
            '    try std.testing.expectEqual(@as(u32, 1), 2);\n}\n', encoding="utf-8")
    elif name in ("module-only", "named"):
        (src / "core" / "plant_module_test.zig").write_text(FAILING.format(name=name), encoding="utf-8")
        edit(core_root, 'pub const nfc_timing_test = @import("nfc_timing_test.zig");\n',
             'pub const nfc_timing_test = @import("nfc_timing_test.zig");\n'
             'pub const plant_module_test = @import("plant_module_test.zig");\n')
        if name == "named":
            edit(core_root, "        _ = nfc_timing_test;\n", "        _ = nfc_timing_test;\n        _ = plant_module_test;\n")
        edit(tests_root, 'pub const field_warnings_test = @import("interfaces").field_warnings_test;\n',
             'pub const field_warnings_test = @import("interfaces").field_warnings_test;\n'
             'pub const plant_module_test = @import("core").plant_module_test;\n')
        edit(tests_root, "    _ = direct_search_test;\n}\n", "    _ = direct_search_test;\n    _ = plant_module_test;\n}\n")
    elif name == "path-in-test":
        (src / "tests" / "plant_path_test.zig").write_text(FAILING.format(name=name), encoding="utf-8")
        with reload_test.open("a", encoding="utf-8") as out:
            out.write('\nconst plant_path = @import("plant_path_test.zig");\n\n'
                      'test "plant: reach plant_path_test.zig by path" {\n    _ = plant_path;\n}\n')
    elif name == "unreferenced":
        (src / "tests" / "plant_unref_test.zig").write_text(FAILING.format(name=name), encoding="utf-8")
        with reload_test.open("a", encoding="utf-8") as out:
            out.write('\nconst plant_unref = @import("plant_unref_test.zig");\n')
    elif name == "via-function":
        (src / "tests" / "plant_fn_test.zig").write_text(
            FAILING.format(name=name) + "\npub fn one() u32 {\n    return 1;\n}\n", encoding="utf-8")
        (src / "tests" / "plant_mid_test.zig").write_text(
            'const leaf = @import("plant_fn_test.zig");\n\npub fn one() u32 {\n    return leaf.one();\n}\n',
            encoding="utf-8")
        with reload_test.open("a", encoding="utf-8") as out:
            out.write('\nconst plant_mid = @import("plant_mid_test.zig");\n\n'
                      'test "plant: call a function of another file" {\n'
                      '    try std.testing.expectEqual(@as(u32, 1), plant_mid.one());\n}\n')
    elif name == "words":
        (src / "tests" / "plant_words_test.zig").write_text("\n".join([
            "//! A file whose only `test`s are text: none is a test declaration.",
            'const std = @import("std");',
            '// test "in a comment" { try std.testing.expect(false); }',
            '/// test "in a doc comment" {}',
            'pub const in_a_string = "test \\"in a string\\" { try std.testing.expect(false); }";',
            "pub const in_a_multiline_string =",
            '    \\\\test "in a multiline string" { try std.testing.expect(false); }',
            ";",
            "pub const t_char = 't';",
            'pub const @"test" = 1;',
            "",
        ]), encoding="utf-8")
        edit(tests_root, 'pub const reload_test = @import("reload_test.zig");\n',
             'pub const reload_test = @import("reload_test.zig");\npub const plant_words_test = @import("plant_words_test.zig");\n')
        edit(tests_root, "    _ = direct_search_test;\n}\n", "    _ = direct_search_test;\n    _ = plant_words_test;\n}\n")
    else:
        print(f"unknown plant {name}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], Path(sys.argv[2])))
