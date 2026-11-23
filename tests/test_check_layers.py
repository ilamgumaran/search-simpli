"""S6-T1, S6-T14, S6-T15: the layer checker (scripts/check_layers.py, docs/layers.md).

The real repository must pass; small synthetic trees in the folder layout
(core/, ops/, interfaces/, tests/), with a zig/build.zig naming their roots, show
that each rule fails with the file and line named."""

from __future__ import annotations

import io
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

import check_layers  # noqa: E402

FILES = {
    "core/engine.zig": ("core", "the engine"),
    "core/store.zig": ("core", "a format"),
    "ops/ops.zig": ("operations", "the seam"),
    "interfaces/cli.zig": ("interfaces", "commands"),
    "interfaces/rpc.zig": ("interfaces", "json-rpc"),
    "interfaces/mcp.zig": ("interfaces", "mcp"),
}
MODULE_ROOTS = {
    "core/core.zig": ("core", "core", "the core module"),
    "ops/operations.zig": ("operations", "operations", "the operations module"),
    "interfaces/interfaces.zig": ("interfaces", "interfaces", "the interfaces, for tests"),
}
ALLOWED = {("interfaces/mcp.zig", "interfaces/cli.zig"): ("debt", "the arguments")}
EXEMPT_FILES = {"tests/root.zig": "the test root"}
BUILD_ROOTS = {
    "core/core.zig": ("core", "the core module and its step"),
    "ops/operations.zig": ("operations", "the operations module and its step"),
    "interfaces/interfaces.zig": ("interfaces", "the interfaces module and its step"),
    "tests/root.zig": ("tests", "the cross-layer step"),
}
ROWS = "\n".join([
    '        .{ .name = "core", .path = "src/core/core.zig" },',
    '        .{ .name = "operations", .path = "src/ops/operations.zig" },',
    '        .{ .name = "interfaces", .path = "src/interfaces/interfaces.zig" },',
    '        .{ .name = "tests", .path = "src/tests/root.zig" },',
    "",
])
# The shape of zig/build.zig's test steps (S6-T15 rework): one row of test_roots per step.
BUILD = "\n".join([
    "const std = @import(\"std\");",
    "// src/old.zig in a comment is not a root",
    "pub fn build(b: *std.Build) void {",
    '    const test_step = b.step("test", "Run the tests");',
    "    const test_roots = [_]struct { name: []const u8, path: []const u8 }{",
    ROWS + "    };",
    "    for (test_roots) |root| {",
    "        const module = b.createModule(.{ .root_source_file = b.path(root.path) });",
    "        const name = root.name;",
    "        const unit_tests = b.addTest(.{ .name = name, .root_module = module });",
    "        test_step.dependOn(&b.addRunArtifact(unit_tests).step);",
    "    }",
    "    // more",
    "}",
    "",
])
MORE = "    // more\n"
TEST_BUILD = "comptime {\n    if (@import(\"builtin\").is_test) {\n%s    }\n}\n"


def compiled(*names):
    """A module root's test-build comptime block naming names."""
    return TEST_BUILD % "".join(f"        _ = {name};\n" for name in names)


# S6-T16: the public core API at the end of the core root: one namespace, `engine`, with no name.
API = ("/// The public core API.\npub const api = struct {\n    /// The engine.\n    pub const engine = struct {};\n"
       "};\nconst internal = @This();\n")

CLEAN = {
    "core/core.zig": 'pub const engine = @import("engine.zig");\npub const store = @import("store.zig");\n'
                     'pub const store_test = @import("store_test.zig");\n' + compiled("engine", "store", "store_test")
                     + API,
    "core/engine.zig": 'const std = @import("std");\nconst store = @import("store.zig");\n',
    "core/store.zig": 'const std = @import("std");\n',
    "core/store_test.zig": 'const store = @import("store.zig");\n',
    "ops/operations.zig": 'pub const ops = @import("ops.zig");\n' + compiled("ops"),
    "ops/ops.zig": 'const engine = @import("core").api.engine;\n',
    "interfaces/interfaces.zig": 'pub const cli = @import("cli.zig");\npub const rpc = @import("rpc.zig");\n'
                                 'pub const mcp = @import("mcp.zig");\n' + compiled("cli", "rpc", "mcp"),
    "interfaces/cli.zig": 'const ops = @import("operations").ops;\nconst engine = @import("core").api.engine;\n',
    "interfaces/rpc.zig": 'const ops = @import("operations").ops;\nconst options = @import("build_options");\n',
    "interfaces/mcp.zig": 'const ops = @import("operations").ops;\nconst cli = @import("cli.zig");\n',
    "tests/root.zig": 'const cli = @import("interfaces").cli;\nconst t = @import("core").store_test;\n'
                      'const e = @import("engine_test.zig");\n',
    "tests/engine_test.zig": 'const rpc = @import("interfaces").rpc;\nconst engine = @import("core").engine;\n',
    "tests/query_bench.zig": 'const mcp = @import("interfaces").mcp;\nconst ops = @import("operations").ops;\n',
}


class Tree:
    """A temporary repository with zig/src and docs/layers.md."""

    def __init__(self, sources=None, files=FILES, allowed=ALLOWED, exempt_files=EXEMPT_FILES,
                 module_roots=MODULE_ROOTS, build_roots=BUILD_ROOTS, build=BUILD):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.files, self.allowed, self.exempt_files = dict(files), dict(allowed), dict(exempt_files)
        self.module_roots, self.build_roots, self.outside_module = dict(module_roots), dict(build_roots), {}
        for rel, text in (CLEAN if sources is None else sources).items():
            self.write(rel, text)
        self.write_build(build)
        doc = self.root / "docs" / "layers.md"
        doc.parent.mkdir(parents=True)
        doc.write_text("# Layers\n\n" + self.render() + "\n\nAfter.\n", encoding="utf-8")

    def write(self, rel, text):
        path = self.root / "zig" / "src" / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def write_build(self, text):
        (self.root / "zig" / "build.zig").write_text(text, encoding="utf-8")

    def read(self, rel):
        return (self.root / "zig" / "src" / rel).read_text(encoding="utf-8")

    def remove(self, rel):
        (self.root / "zig" / "src" / rel).unlink()

    def render(self):
        return check_layers.render_doc(self.files, self.allowed, self.exempt_files, module_roots=self.module_roots,
                                       build_roots=self.build_roots)

    def check(self, doc=True, report=None):
        return check_layers.check(self.root, self.files, self.allowed, self.exempt_files, doc=doc,
                                  module_roots=self.module_roots, build_roots=self.build_roots,
                                  outside_module=self.outside_module, report=report)

    def close(self):
        self.tmp.cleanup()


class RepositoryTests(unittest.TestCase):
    def test_the_repository_passes(self):
        self.assertEqual(check_layers.check(REPO), [])

    def test_main_reports_ok(self):
        out = io.StringIO()
        with redirect_stdout(out):
            code = check_layers.main(["--root", str(REPO)])
        self.assertEqual(code, 0, out.getvalue())
        self.assertIn("check_layers: OK", out.getvalue())

    def test_the_document_holds_the_generated_block(self):
        text = (REPO / "docs" / "layers.md").read_text(encoding="utf-8")
        self.assertIn(check_layers.render_doc(), text)

    def test_the_plan_s_named_exception_is_listed(self):
        self.assertEqual(check_layers.ALLOWED[("interfaces/mcp.zig", "interfaces/cli.zig")][0], "debt")

    def test_every_layer_is_known_and_in_its_folder(self):
        for rel, (layer, role) in check_layers.FILES.items():
            self.assertIn(layer, check_layers.LAYER_ORDER, rel)
            self.assertTrue(role, rel)
            self.assertEqual(rel.split("/")[0], check_layers.FOLDERS[layer], rel)

    def test_every_zig_file_sits_in_one_of_the_four_folders(self):
        for rel in check_layers.zig_files(REPO / "zig" / "src"):
            self.assertIn(rel.split("/")[0], ("core", "ops", "interfaces", "tests"), rel)


class RuleTests(unittest.TestCase):
    def setUp(self):
        self.tree = Tree()

    def tearDown(self):
        self.tree.close()

    def test_clean_tree_passes(self):
        self.assertEqual(self.tree.check(), [])

    # S6-T14: the folders.

    def test_a_file_outside_its_layer_s_folder_fails(self):
        self.tree.remove("core/store.zig")
        self.tree.write("ops/store.zig", 'const std = @import("std");\n')
        problems = self.tree.check()
        self.assertIn("zig/src/ops/store.zig:1: sits in zig/src/ops/, outside its layer's folder: FILES assigns "
                      "store.zig to core as core/store.zig (zig/src/core/)", problems)
        self.assertTrue(any("FILES names zig/src/core/store.zig, which does not exist" in p for p in problems), problems)

    def test_files_naming_a_path_outside_the_layer_s_folder_fails(self):
        self.tree.files["ops/extra.zig"] = ("core", "misplaced")
        self.tree.write("ops/extra.zig", 'const std = @import("std");\n')
        problems = self.tree.check(doc=False)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("FILES assigns ops/extra.zig to core, whose folder is zig/src/core/", problems[0])

    def test_a_file_directly_in_zig_src_fails(self):
        self.tree.write("extra.zig", 'const std = @import("std");\n')
        self.assertEqual(self.tree.check(), [
            "zig/src/extra.zig:1: sits directly in zig/src/, outside the layer folders (core/, ops/, interfaces/) "
            "and tests/: move it to its layer's folder"])

    def test_a_file_in_an_unknown_folder_fails(self):
        self.tree.write("lib/extra_test.zig", 'const std = @import("std");\n')
        self.assertEqual(self.tree.check(), [
            "zig/src/lib/extra_test.zig:1: sits in zig/src/lib/, outside the layer folders (core/, ops/, "
            "interfaces/) and tests/: move it to its layer's folder"])

    def test_a_layer_file_in_tests_fails(self):
        self.tree.write("tests/helper.zig", 'const std = @import("std");\n')
        problems = self.tree.check()
        self.assertEqual(len(problems), 1, problems)
        self.assertTrue(problems[0].startswith("zig/src/tests/helper.zig:1: zig/src/tests/ holds tests, "
                                               "benchmarks and tools only"), problems[0])

    def test_an_import_by_path_into_another_folder_fails(self):
        self.tree.write("interfaces/cli.zig", 'const engine = @import("../core/engine.zig");\n'
                                              'const ops = @import("operations").ops;\n')
        self.assertEqual(self.tree.check(), [
            "zig/src/interfaces/cli.zig:1: imports ../core/engine.zig (zig/src/core/engine.zig), a file of another "
            'folder: core is reached through its module, @import("core"), never by path'])

    def test_an_import_by_path_into_tests_fails(self):
        self.tree.write("core/engine.zig", CLEAN["core/engine.zig"] + 'const t = @import("../tests/engine_test.zig");\n')
        self.assertEqual(self.tree.check(), [
            "zig/src/core/engine.zig:3: imports ../tests/engine_test.zig (zig/src/tests/engine_test.zig), a file of "
            "another folder: zig/src/tests/ is no module, and nothing outside it imports its files"])

    def test_a_test_in_tests_of_one_layer_only_fails(self):
        self.tree.write("tests/store_more_test.zig", 'const store = @import("core").store;\n')
        self.assertEqual(self.tree.check(), [
            "zig/src/tests/store_more_test.zig:1: imports core files only: a test, benchmark or tool of one layer "
            "sits beside its subject, in zig/src/core/"])

    def test_a_test_in_tests_that_crosses_through_another_test_passes(self):
        self.tree.write("tests/engine_more_test.zig", 'const engine = @import("core").engine;\n'
                                                      'const t = @import("engine_test.zig");\n')
        self.assertEqual(self.tree.check(), [])

    def test_a_test_in_a_layer_s_folder_is_held_to_that_layer(self):
        self.tree.write("core/store_test.zig", CLEAN["core/store_test.zig"] + 'const ops = @import("operations").ops;\n')
        self.assertEqual(self.tree.check(), [
            "zig/src/core/store_test.zig:2: core file imports the module operations, which only files of "
            "interfaces and tests may import"])

    def test_a_name_the_module_root_does_not_export_fails(self):
        self.tree.write("ops/ops.zig", 'const engine = @import("core").nothing;\n')
        self.assertEqual(self.tree.check(), [
            "zig/src/ops/ops.zig:1: imports core.nothing, which zig/src/core/core.zig does not export "
            "(no pub const nothing)"])

    def test_a_layer_file_importing_a_test_through_a_module_fails(self):
        self.tree.write("ops/ops.zig", CLEAN["ops/ops.zig"] + 'const t = @import("core").store_test;\n')
        self.assertEqual(self.tree.check(), [
            "zig/src/ops/ops.zig:2: operations file imports core.store_test (zig/src/core/store_test.zig), "
            "a test, benchmark or tool file"])

    def test_a_module_root_imported_by_path_fails(self):
        self.tree.write("core/engine.zig", CLEAN["core/engine.zig"] + 'const c = @import("core.zig");\n')
        self.assertEqual(self.tree.check(), [
            "zig/src/core/engine.zig:3: imports core.zig, a module root, by path: import the module by name"])

    def test_a_module_root_outside_its_folder_fails(self):
        self.tree.module_roots["core/ops_root.zig"] = ("operations", "ops2", "misplaced")
        self.tree.write("core/ops_root.zig", "\n")
        problems = self.tree.check(doc=False)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("MODULE_ROOTS puts core/ops_root.zig, the operations module's root, outside zig/src/ops/",
                      problems[0])

    # The direction rule (S6-T1), through the modules.

    def test_core_importing_operations_fails_with_file_and_line(self):
        self.tree.write("core/engine.zig", CLEAN["core/engine.zig"] + 'const ops = @import("operations").ops;\n')
        self.assertEqual(self.tree.check(), [
            "zig/src/core/engine.zig:3: core file imports the module operations, which only files of "
            "interfaces and tests may import"])

    def test_core_importing_an_interface_fails(self):
        self.tree.write("core/store.zig", 'const rpc = @import("interfaces").rpc;\n')
        self.assertEqual(self.tree.check(), [
            "zig/src/core/store.zig:1: core file imports the module interfaces, which only files of tests may import"])

    def test_core_importing_its_own_module_fails(self):
        self.tree.write("core/store.zig", 'const engine = @import("core").engine;\n')
        self.assertEqual(self.tree.check(), [
            "zig/src/core/store.zig:1: core file imports the module core, which only files of operations, "
            "interfaces and tests may import"])

    def test_operations_importing_an_interface_fails(self):
        self.tree.write("ops/ops.zig", CLEAN["ops/ops.zig"] + 'const cli = @import("interfaces").cli;\n')
        self.assertEqual(self.tree.check(), [
            "zig/src/ops/ops.zig:2: operations file imports the module interfaces, which only files of tests "
            "may import"])

    def test_an_interface_importing_another_fails_unless_allowed(self):
        self.tree.write("interfaces/rpc.zig", 'const cli = @import("cli.zig");\n')
        self.assertEqual(self.tree.check(), [
            "zig/src/interfaces/rpc.zig:1: interface file imports cli.zig, another interface, "
            "and the pair is not in ALLOWED (scripts/check_layers.py)"])

    def test_removing_the_allowed_pair_fails(self):
        self.tree.allowed = {}
        self.assertEqual(self.tree.check(doc=False), [
            "zig/src/interfaces/mcp.zig:2: interface file imports cli.zig, another interface, "
            "and the pair is not in ALLOWED (scripts/check_layers.py)"])

    def test_an_allowed_pair_that_no_longer_occurs_fails(self):
        self.tree.write("interfaces/mcp.zig", 'const ops = @import("operations").ops;\n')
        problems = self.tree.check()
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("allowed pair interfaces/mcp.zig -> interfaces/cli.zig no longer occurs", problems[0])

    def test_an_unassigned_file_fails(self):
        self.tree.write("core/extra.zig", 'const std = @import("std");\n')
        problems = self.tree.check()
        self.assertEqual(len(problems), 1, problems)
        self.assertTrue(problems[0].startswith("zig/src/core/extra.zig:1: not assigned to a layer"), problems[0])

    def test_an_assigned_file_that_no_longer_exists_fails(self):
        self.tree.remove("core/store.zig")
        self.tree.write("core/engine.zig", 'const std = @import("std");\n')
        self.tree.write("core/store_test.zig", 'const std = @import("std");\n')
        self.tree.write("core/core.zig", 'pub const engine = @import("engine.zig");\n'
                                         'pub const store_test = @import("store_test.zig");\n'
                                         + compiled("engine", "store_test") + API)
        problems = self.tree.check()
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("FILES names zig/src/core/store.zig, which does not exist", problems[0])

    def test_an_exempt_file_that_no_longer_exists_fails(self):
        self.tree.remove("tests/root.zig")
        problems = self.tree.check()
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("EXEMPT_FILES names zig/src/tests/root.zig, which does not exist", problems[0])

    def test_tests_and_benchmarks_are_exempt_but_must_match_a_pattern(self):
        # tests/engine_test.zig imports rpc and tests/query_bench.zig imports mcp: allowed.
        self.assertEqual(self.tree.check(), [])
        self.tree.write("tests/engine_tests.zig", 'const rpc = @import("interfaces").rpc;\n')
        problems = self.tree.check()
        self.assertEqual(len(problems), 1, problems)
        self.assertTrue(problems[0].startswith("zig/src/tests/engine_tests.zig:1: zig/src/tests/ holds tests"),
                        problems[0])

    def test_an_assigned_file_importing_a_test_file_fails(self):
        self.tree.write("core/engine.zig", CLEAN["core/engine.zig"] + 'const t = @import("store_test.zig");\n')
        self.assertEqual(self.tree.check(), [
            "zig/src/core/engine.zig:3: core file imports store_test.zig, a test, benchmark or tool file"])

    def test_comments_and_strings_are_not_imports(self):
        self.tree.write("core/engine.zig", "\n".join([
            '// const ops = @import("operations");',
            'const store = @import("store.zig"); // was @import("../interfaces/rpc.zig")',
            'const text = "@import(\\"interfaces\\")";',
            '    \\\\ @import("mcp.zig") in a multiline string',
            "const quote = '\"'; const s = @import(\"store.zig\");",
            'const url = "http://example.invalid"; const t = @import("store.zig");',
            "",
        ]))
        self.assertEqual(self.tree.check(), [])

    # Rework after S6-T1's first Verdict: the verifier's plants P1, P2 and P6, and their kin.

    def core_imports(self, text):
        """core/engine.zig given text after a clean first line; the problems found."""
        self.tree.write("core/engine.zig", 'const store = @import("store.zig");\n' + text)
        return self.tree.check()

    OPS_FROM_CORE = ("core file imports the module operations, which only files of interfaces and tests may import")

    def test_p1_an_import_over_three_lines_with_a_trailing_comma(self):
        self.assertEqual(self.core_imports('const ops_plant = @import(\n    "operations",\n);\n'), [
            f"zig/src/core/engine.zig:2: {self.OPS_FROM_CORE}"])

    def test_p2_spaces_before_and_inside_the_parentheses(self):
        self.assertEqual(self.core_imports('const a = @import ("operations");\nconst b = @import\t(\n"operations" ) ;\n'), [
            f"zig/src/core/engine.zig:2: {self.OPS_FROM_CORE}",
            f"zig/src/core/engine.zig:3: {self.OPS_FROM_CORE}"])

    def test_p6_a_path_out_of_zig_src_and_back_in(self):
        self.assertEqual(self.core_imports('const ops_plant = @import("../../src/ops/ops.zig");\n'), [
            "zig/src/core/engine.zig:2: imports ../../src/ops/ops.zig (zig/src/ops/ops.zig), a file of another "
            'folder: operations is reached through its module, @import("operations"), never by path'])

    def test_dot_segments_resolve(self):
        self.assertEqual(self.core_imports('const a = @import("./store.zig");\nconst b = @import("x/../store.zig");\n'
                                           'const c = @import("x/../../ops/ops.zig");\n'), [
            "zig/src/core/engine.zig:4: imports x/../../ops/ops.zig (zig/src/ops/ops.zig), a file of another "
            'folder: operations is reached through its module, @import("operations"), never by path'])

    def test_escapes_in_the_string_are_decoded(self):
        # Zig 0.16.0 compiles both (S6-T1 rework, scratch probe).
        self.assertEqual(self.core_imports('const a = @import("oper\\x61tions");\nconst b = @import("oper\\u{61}tions");\n'), [
            f"zig/src/core/engine.zig:2: {self.OPS_FROM_CORE}",
            f"zig/src/core/engine.zig:3: {self.OPS_FROM_CORE}"])

    def test_a_target_outside_zig_src_fails(self):
        problems = self.core_imports('const a = @import("../../../tools/x.zig");\n')
        self.assertEqual(problems, ["zig/src/core/engine.zig:2: imports ../../../tools/x.zig, which is outside zig/src/"])

    def test_a_target_naming_no_file_fails(self):
        problems = self.core_imports('const a = @import("nope.zig");\n')
        self.assertEqual(problems, [
            "zig/src/core/engine.zig:2: imports nope.zig, which resolves to zig/src/core/nope.zig: no such file"])

    def test_an_imported_unassigned_file_fails_at_the_import_too(self):
        self.tree.write("core/.hidden/extra.zig", 'const std = @import("std");\n')
        problems = self.core_imports('const a = @import(".hidden/extra.zig");\n')
        self.assertEqual(problems, [
            "zig/src/core/.hidden/extra.zig:1: not assigned to a layer: add it to FILES in scripts/check_layers.py "
            "(core, operations or interfaces), then run scripts/check_layers.py --write-doc",
            "zig/src/core/engine.zig:2: imports .hidden/extra.zig (zig/src/core/.hidden/extra.zig), which is not "
            "assigned to a layer"])

    def test_an_operand_that_is_not_one_string_literal_fails(self):
        problems = self.core_imports("\n".join([
            'const a = @import("o" ++ "ps.zig");',
            'const path = "ops.zig";',
            "const b = @import(path);",
            "const c = @import(",
            "    \\\\ops.zig",
            ");",
            "const d = @import;",
            "",
        ]))
        self.assertEqual([p.split(": ", 1)[0] for p in problems],
                         ["zig/src/core/engine.zig:2", "zig/src/core/engine.zig:4", "zig/src/core/engine.zig:5",
                          "zig/src/core/engine.zig:8"])
        self.assertTrue(all("not one string literal" in p for p in problems[:3]), problems)
        self.assertIn("@import without an argument list", problems[3])

    def test_named_modules_are_listed_and_bound_to_layers(self):
        problems = self.core_imports('const b = @import("builtin");\nconst t = @import("tool_schemas");\n'
                                     'const u = @import("unknown_module");\n')
        self.assertEqual(problems, [
            "zig/src/core/engine.zig:3: core file imports the module tool_schemas, which only files of interfaces "
            "and tests may import",
            "zig/src/core/engine.zig:4: imports 'unknown_module', which is neither a .zig file nor a module listed "
            "in MODULES (scripts/check_layers.py)"])

    def test_p3_text_that_only_looks_like_an_import_is_ignored(self):
        self.assertEqual(self.core_imports("\n".join([
            '// const a = @import("operations");',
            '/// @import("operations") in a doc comment',
            '//! @import("../ops/ops.zig") in a top-level doc comment',
            'const s1 = "say \\"@import(\\\\\\"operations\\\\\\")\\" // not a comment";',
            'const s2 = "@import(\\"operations\\")";',
            "const m = ",
            '    \\\\@import("operations")',
            '    \\\\@import(',
            '    \\\\    "operations",',
            "    \\\\)",
            ";",
            "const q = '\"'; const r = '\\''; const s = '@';",
            'const url = "http://example.invalid"; // @import("operations")',
            'const @"@import(\\"operations\\")" = 1;',
            "",
        ])), [])

    def test_the_document_out_of_step_fails_with_its_line(self):
        doc = self.tree.root / "docs" / "layers.md"
        doc.write_text(doc.read_text(encoding="utf-8").replace("| `core/store.zig` | core |",
                                                               "| `core/store.zig` | operations |"),
                       encoding="utf-8")
        problems = self.tree.check()
        self.assertEqual(len(problems), 1, problems)
        line = int(problems[0].split(":")[1])
        self.assertIn("`core/store.zig` | operations", doc.read_text(encoding="utf-8").split("\n")[line - 1])
        self.assertIn("the generated block differs", problems[0])

    def test_the_document_without_markers_fails(self):
        (self.tree.root / "docs" / "layers.md").write_text("# Layers\n", encoding="utf-8")
        problems = self.tree.check()
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("no generated block", problems[0])

    def test_an_allowed_pair_must_join_two_interfaces(self):
        self.tree.allowed = {**ALLOWED, ("ops/ops.zig", "interfaces/cli.zig"): ("debt", "wrong")}
        problems = self.tree.check(doc=False)
        self.assertIn("is not between two interface files", " ".join(problems))


class TestReachTests(unittest.TestCase):
    """S6-T15: a file holding a test that no step of `zig build test` runs fails."""

    FAILING = 'const std = @import("std");\ntest "planted" {\n    try std.testing.expect(false);\n}\n'
    UNNAMED = "holds 1 test that no step of `zig build test` runs: no test step's root reaches it"

    def setUp(self):
        self.tree = Tree()

    def tearDown(self):
        self.tree.close()

    def reach(self):
        report = {}
        problems = self.tree.check(report=report)
        return problems, report

    def name_in_core(self, name, compiled_too=True):
        """core/core.zig with name.zig as a fourth pub const, compiled in its block or not."""
        head, _, _ = self.tree.read("core/core.zig").partition("comptime {")
        names = ["engine", "store", "store_test"] + ([name] if compiled_too else [])
        self.tree.write("core/core.zig", head + f'pub const {name} = @import("{name}.zig");\n' + compiled(*names)
                        + API)

    def test_the_clean_tree_counts_its_tests_by_step(self):
        self.tree.write("core/store.zig", 'const std = @import("std");\ntest "store" {}\ntest {}\n')
        self.tree.write("ops/ops.zig", CLEAN["ops/ops.zig"] + "test decltest {}\n")
        problems, report = self.reach()
        self.assertEqual(problems, [])
        self.assertEqual(report["tests"]["core/store.zig"], 2)
        self.assertEqual(report["reached"]["core/store.zig"], [("core", "core/core.zig")])
        self.assertEqual(report["reached"]["ops/ops.zig"], [("operations", "ops/operations.zig")])

    def test_the_verifier_s_plant_a_test_named_nowhere_fails(self):
        self.tree.write("core/plant_unnamed_test.zig", 'const std = @import("std");\nconst store = @import("store.zig");\n'
                        'test "plant" {\n    _ = store;\n    try std.testing.expectEqual(@as(u32, 1), 2);\n}\n')
        problems = self.tree.check()
        self.assertEqual(problems, [
            "zig/src/core/plant_unnamed_test.zig:3: " + self.UNNAMED + " (name it in zig/src/core/core.zig: a pub "
            "const and a line in its test-build comptime block)",
            "zig/src/core/core.zig:1: does not name core/plant_unnamed_test.zig: a module root names every file of "
            "its folder (a pub const, and a line in its test-build comptime block), so the module's step of "
            "`zig build test` compiles it and runs its tests"])

    def test_a_named_test_passes(self):
        self.tree.write("core/plant_test.zig", self.FAILING)
        self.name_in_core("plant_test")
        problems, report = self.reach()
        self.assertEqual(problems, [])
        self.assertEqual(report["reached"]["core/plant_test.zig"], [("core", "core/core.zig")])

    def test_a_test_named_only_as_a_pub_const_fails(self):
        self.tree.write("core/plant_test.zig", self.FAILING)
        self.name_in_core("plant_test", compiled_too=False)
        problems = self.tree.check()
        self.assertEqual(problems, [
            "zig/src/core/plant_test.zig:2: " + self.UNNAMED + " (name it in zig/src/core/core.zig: a pub const and "
            "a line in its test-build comptime block)",
            "zig/src/core/core.zig:4: names core/plant_test.zig (pub const plant_test) but no test build compiles it: "
            "add `_ = plant_test;` to its test-build comptime block"])

    def test_a_test_reached_only_through_a_module_fails(self):
        # tests/root.zig compiles core.plant_test in its test block, but through the module
        # `core`: the tests step's root module does not hold it, so its tests do not run there.
        self.tree.write("core/plant_test.zig", self.FAILING)
        self.name_in_core("plant_test", compiled_too=False)
        self.tree.write("tests/root.zig", CLEAN["tests/root.zig"] + 'const p = @import("core").plant_test;\n'
                        'test "load" {\n    _ = p;\n    _ = e;\n}\n')
        problems = self.tree.check()
        self.assertIn("zig/src/core/plant_test.zig:2: " + self.UNNAMED + " (name it in zig/src/core/core.zig: a pub "
                      "const and a line in its test-build comptime block); zig/src/tests/root.zig reaches it only "
                      "through the module core, and a test build runs the tests of its root module's files only",
                      problems)

    def test_a_test_in_tests_named_nowhere_fails(self):
        self.tree.write("tests/plant_test.zig", self.FAILING)
        self.assertEqual(self.tree.check(), [
            "zig/src/tests/plant_test.zig:2: " + self.UNNAMED + " (name it in zig/src/tests/root.zig's test block, "
            "or from a test that zig/src/tests/root.zig reaches)"])

    def test_a_test_reached_by_path_through_another_test_passes(self):
        self.tree.write("tests/plant_test.zig", self.FAILING)
        self.tree.write("tests/engine_test.zig", CLEAN["tests/engine_test.zig"] + 'const plant = @import("plant_test.zig");\n'
                        'test "engine" {\n    _ = plant;\n}\n')
        self.tree.write("tests/root.zig", CLEAN["tests/root.zig"] + 'test "load" {\n    _ = e;\n}\n')
        problems, report = self.reach()
        self.assertEqual(problems, [])
        self.assertEqual(report["reached"]["tests/plant_test.zig"], [("tests", "tests/engine_test.zig")])
        self.assertEqual(report["reached"]["tests/engine_test.zig"], [("tests", "tests/root.zig")])

    def test_an_import_nothing_compiled_names_does_not_reach(self):
        # The root's `const e = @import("engine_test.zig");` is named by no test or comptime block.
        self.tree.write("tests/engine_test.zig", CLEAN["tests/engine_test.zig"] + 'test "engine" {}\n')
        self.assertEqual(self.tree.check(), [
            "zig/src/tests/engine_test.zig:3: " + self.UNNAMED + " (name it in zig/src/tests/root.zig's test block, "
            "or from a test that zig/src/tests/root.zig reaches)"])

    def test_an_import_reached_through_the_file_s_own_declarations_counts(self):
        self.tree.write("tests/engine_test.zig", CLEAN["tests/engine_test.zig"] + 'test "engine" {}\n')
        self.tree.write("tests/root.zig", CLEAN["tests/root.zig"] + "const more = alias;\n"
                        "const alias = e;\ntest \"load\" {\n    _ = more;\n}\n")
        self.assertEqual(self.tree.check(), [])

    def test_an_import_named_only_in_a_function_body_is_not_followed(self):
        # The strict side: Zig compiles helper's body because the test calls it, and runs
        # engine_test's test; the checker does not trace calls and says it does not run.
        self.tree.write("tests/engine_test.zig", CLEAN["tests/engine_test.zig"] + 'test "engine" {}\n')
        self.tree.write("tests/root.zig", CLEAN["tests/root.zig"] + "fn helper() void {\n    _ = e;\n}\n"
                        "test \"load\" {\n    helper();\n}\n")
        self.assertEqual(len(self.tree.check()), 1)

    def test_an_import_named_only_from_an_uncompiled_function_does_not_reach(self):
        self.tree.write("tests/engine_test.zig", CLEAN["tests/engine_test.zig"] + 'test "engine" {}\n')
        self.tree.write("tests/root.zig", CLEAN["tests/root.zig"] + "fn unused() void {\n    _ = e;\n}\n")
        self.assertEqual(len(self.tree.check()), 1)

    def test_a_member_of_the_same_name_is_not_a_reference(self):
        # `x.e` and `.{ .e = 1 }` name a member and a field, not the declaration `e`.
        self.tree.write("tests/engine_test.zig", CLEAN["tests/engine_test.zig"] + 'test "engine" {}\n')
        self.tree.write("tests/root.zig", CLEAN["tests/root.zig"] + 'const std = @import("std");\n'
                        'test "load" {\n    _ = std.e;\n    _ = .{ .e = 1 };\n}\n')
        self.assertEqual(len(self.tree.check()), 1)

    def test_test_in_a_comment_a_string_or_a_name_is_not_a_test(self):
        self.tree.write("tests/words_test.zig", "\n".join([
            'const std = @import("std");',
            '// test "in a comment" {}',
            '/// test "in a doc comment" {}',
            'const s = "test \\"in a string\\" {}";',
            "const m =",
            '    \\\\test "in a multiline string" {}',
            ";",
            "const c = 't';",
            'const @"test" = 1;',
            "",
        ]))
        problems, report = self.reach()
        self.assertEqual(problems, [])
        self.assertEqual(report["tests"]["tests/words_test.zig"], 0)

    def test_a_test_in_a_nested_struct_counts(self):
        self.tree.write("tests/nested_test.zig", 'const S = struct {\n    test "nested" {}\n};\n')
        self.assertEqual(self.tree.check(), [
            "zig/src/tests/nested_test.zig:2: " + self.UNNAMED + " (name it in zig/src/tests/root.zig's test block, "
            "or from a test that zig/src/tests/root.zig reaches)"])

    def test_a_test_in_a_nested_struct_a_test_names_counts(self):
        self.tree.write("tests/engine_test.zig", CLEAN["tests/engine_test.zig"]
                        + 'const S = struct {\n    test "nested" {}\n};\ntest "engine" {\n    _ = S;\n}\n')
        self.tree.write("tests/root.zig", CLEAN["tests/root.zig"] + 'test "load" {\n    _ = e;\n}\n')
        problems, report = self.reach()
        self.assertEqual(problems, [])
        self.assertEqual(report["tests"]["tests/engine_test.zig"], 2)

    # The S6-T15 Verdict's seven plants where the checker said a test ran and Zig did not
    # (finding 2): each now fails the checker. Each is the verifier's plant, in tests/,
    # through a file the root names (plant_mid_test.zig) and a target holding one test.

    UNREACHED = ("zig/src/tests/plant_target_test.zig:2: holds 1 test that no step of `zig build test` runs: no test "
                 "step's root reaches it")

    def mid(self, body):
        """tests/plant_mid_test.zig holding body, named by tests/root.zig; the problems found."""
        self.tree.write("tests/plant_target_test.zig", self.FAILING)
        self.tree.write("tests/plant_mid_test.zig", body)
        self.tree.write("tests/root.zig", CLEAN["tests/root.zig"] + 'const m = @import("plant_mid_test.zig");\n'
                        'test "load" {\n    _ = m;\n    _ = e;\n}\n')
        return self.tree.check()

    def test_verdict_a_a_test_in_a_struct_nothing_names_fails(self):
        self.tree.write("tests/plant_a_test.zig", 'test "top" {}\nconst Unused = struct {\n    test "nested" {}\n};\n')
        self.tree.write("tests/root.zig", CLEAN["tests/root.zig"] + 'const a = @import("plant_a_test.zig");\n'
                        'test "load" {\n    _ = a;\n    _ = e;\n}\n')
        problems, report = self.reach()
        self.assertEqual(problems, [
            "zig/src/tests/plant_a_test.zig:3: holds 1 test that no step of `zig build test` runs, though a step "
            "reaches the file: each sits inside a declaration nothing compiled names (a struct no test or comptime "
            "block uses); lines 3"])
        self.assertEqual(report["tests"]["tests/plant_a_test.zig"], 1)

    def test_verdict_c_a_function_named_and_not_called_fails(self):
        problems = self.mid('const target = @import("plant_target_test.zig");\nfn helper() void {\n    _ = target;\n}\n'
                            'test "names helper" {\n    _ = helper;\n}\n')
        self.assertTrue(problems and problems[0].startswith(self.UNREACHED), problems)

    def test_verdict_d_a_method_never_called_fails(self):
        problems = self.mid('const std = @import("std");\nconst target = @import("plant_target_test.zig");\n'
                            "const Helper = struct {\n    x: u32 = 0,\n    fn touch() void {\n        _ = target;\n"
                            "    }\n};\ntest \"uses Helper\" {\n    const h = Helper{};\n    _ = h;\n}\n")
        self.assertTrue(problems and problems[0].startswith(self.UNREACHED), problems)

    def test_verdict_e_comptime_if_false_fails(self):
        problems = self.mid('const target = @import("plant_target_test.zig");\ncomptime {\n    if (false) {\n'
                            '        _ = target;\n    }\n}\ntest "e" {}\n')
        self.assertTrue(problems and problems[0].startswith(self.UNREACHED), problems)

    def test_verdict_f_comptime_not_is_test_fails(self):
        problems = self.mid('const target = @import("plant_target_test.zig");\ncomptime {\n'
                            '    if (!@import("builtin").is_test) {\n        _ = target;\n    }\n}\ntest "f" {}\n')
        self.assertTrue(problems and problems[0].startswith(self.UNREACHED), problems)
        problems = self.mid('const builtin = @import("builtin");\nconst target = @import("plant_target_test.zig");\n'
                            "comptime {\n    if (!builtin.is_test) _ = target;\n}\ntest \"f\" {\n    _ = builtin;\n}\n")
        self.assertTrue(problems and problems[0].startswith(self.UNREACHED), problems)

    def test_verdict_m_a_field_of_the_import_s_name_fails(self):
        problems = self.mid('const helpers = @import("plant_target_test.zig");\n'
                            'test "m" {\n    const S = struct { helpers: u32 = 0 };\n    const v = S{};\n'
                            "    _ = v.helpers;\n}\n")
        self.assertTrue(problems and problems[0].startswith(self.UNREACHED), problems)

    def test_verdict_r_an_import_in_a_named_struct_fails(self):
        problems = self.mid('const Fixture = struct {\n    const data = @import("plant_target_test.zig");\n'
                            '    pub const n: u32 = 3;\n};\ntest "r" {\n    _ = Fixture.n;\n}\n')
        self.assertTrue(problems and problems[0].startswith(self.UNREACHED), problems)

    BODY = ("holds 1 test written inside a body (a function's, such as a generic type's returned struct, a test "
            "block's or a comptime block's): Zig runs such a test as often as the body is analysed, once per "
            "instantiation, once or never, which the checker cannot count; write it at the top level of the file, "
            "or of a struct declared at the top level; lines ")

    def in_root(self, name, text):
        """tests/<name>.zig holding text, named by tests/root.zig; the problems found."""
        self.tree.write(f"tests/{name}.zig", text)
        self.tree.write("tests/root.zig", CLEAN["tests/root.zig"] + f'const p = @import("{name}.zig");\n'
                        'test "load" {\n    _ = p;\n    _ = e;\n}\n')
        return self.tree.check()

    def test_verdict_b_a_test_in_a_generic_type_fails(self):
        # The first Verdict's B: Zig runs it once per instantiation (here once). The checker
        # cannot count that, so it fails the test, on the strict side.
        problems = self.in_root("plant_b_test", 'fn Gen(comptime T: type) type {\n    return struct {\n'
                                '        pub const t = T;\n        test "generic" {}\n    };\n}\n'
                                'test "b" {\n    _ = Gen(u8);\n}\n')
        self.assertEqual(problems, ["zig/src/tests/plant_b_test.zig:4: " + self.BODY + "4"])

    def test_second_verdict_b2_two_generics_that_cancel_fail(self):
        # Ring(T) instantiated twice runs its test twice; Queue named, never instantiated,
        # runs its test never: the totals cancel, so only this rule sees it.
        problems = self.in_root("plant_b2_test", "\n".join([
            'const std = @import("std");',
            "fn Ring(comptime T: type) type {",
            "    return struct {",
            "        pub const Item = T;",
            '        test "ring" {}',
            "    };",
            "}",
            "fn Queue(comptime T: type) type {",
            "    return struct {",
            "        pub const Item = T;",
            '        test "queue fails" {}',
            "    };",
            "}",
            'test "rings" {',
            "    _ = Ring(u8).Item;",
            "    _ = Ring(u32).Item;",
            "}",
            'test "queue" {',
            "    _ = Queue;",
            "}",
            ""]))
        self.assertEqual(problems, ["zig/src/tests/plant_b2_test.zig:5: " + self.BODY.replace("holds 1 test", "holds 2 tests")
                                    + "5, 11"])

    def test_a_test_in_a_local_struct_of_a_test_block_fails(self):
        # Zig 0.16 runs it when the test block runs (scratch probe); the checker does not count it.
        problems = self.in_root("plant_local_test", 'test "outer" {\n    const Local = struct {\n'
                                '        test "local" {}\n    };\n    _ = Local;\n}\n')
        self.assertEqual(problems, ["zig/src/tests/plant_local_test.zig:3: " + self.BODY + "3"])

    def test_a_test_in_a_function_s_local_struct_fails(self):
        problems = self.in_root("plant_fnlocal_test", "fn helper() void {\n    const S = struct {\n"
                                '        test "in fn" {}\n    };\n    _ = S;\n}\ntest "calls" {\n    helper();\n}\n')
        self.assertEqual(problems, ["zig/src/tests/plant_fnlocal_test.zig:3: " + self.BODY + "3"])

    def test_a_test_in_a_top_level_struct_a_test_names_still_counts(self):
        problems = self.in_root("plant_top_test", 'const S = struct {\n    test "in S" {}\n};\n'
                                'test "names S" {\n    _ = S;\n}\n')
        self.assertEqual(problems, [])

    def test_verdict_g_an_import_only_a_pub_fn_uses_fails(self):
        problems = self.mid('pub const target = @import("plant_target_test.zig");\npub fn helper() void {\n'
                            '    _ = target;\n}\ntest "g" {}\n')
        self.assertTrue(problems and problems[0].startswith(self.UNREACHED), problems)

    def test_a_test_under_a_false_guard_in_a_reached_file_fails(self):
        self.tree.write("tests/engine_test.zig", CLEAN["tests/engine_test.zig"]
                        + 'test "engine" {}\ncomptime {\n    if (false) {\n        _ = struct {\n'
                          '            test "dead" {}\n        };\n    }\n}\n')
        self.tree.write("tests/root.zig", CLEAN["tests/root.zig"] + 'test "load" {\n    _ = e;\n}\n')
        self.assertEqual(self.tree.check(), ["zig/src/tests/engine_test.zig:7: " + self.BODY + "7"])

    def test_a_benchmark_or_a_tool_holding_a_test_fails(self):
        self.tree.write("tests/query_bench.zig", CLEAN["tests/query_bench.zig"] + 'test "bench" {}\n')
        self.assertEqual(len(self.tree.check()), 1)

    def test_a_file_reached_by_two_roots_is_counted_in_each(self):
        self.tree.build_roots["core/store.zig"] = ("store", "a step of its own")
        self.tree.write_build(BUILD.replace(ROWS, ROWS + '        .{ .name = "store", .path = "src/core/store.zig" },\n'))
        self.tree.write("core/store.zig", 'test "store" {}\n')
        report = {}
        self.assertEqual(self.tree.check(doc=False, report=report), [])
        self.assertEqual(sorted(report["reached"]["core/store.zig"]), [("core", "core/core.zig"), ("store", None)])

    # A module root names every file of its folder.

    def test_removing_a_name_from_a_module_root_s_block_fails(self):
        self.tree.write("core/core.zig", self.tree.read("core/core.zig").replace("        _ = store;\n", ""))
        self.assertEqual(self.tree.check(), [
            "zig/src/core/core.zig:2: names core/store.zig (pub const store) but no test build compiles it: "
            "add `_ = store;` to its test-build comptime block"])

    def test_removing_a_name_from_a_module_root_fails(self):
        self.tree.write("interfaces/interfaces.zig", 'pub const cli = @import("cli.zig");\n'
                        'pub const mcp = @import("mcp.zig");\n' + compiled("cli", "mcp"))
        # tests/engine_test.zig's @import("interfaces").rpc now fails as well.
        self.assertIn("zig/src/interfaces/interfaces.zig:1: does not name interfaces/rpc.zig: a module root names "
                      "every file of its folder (a pub const, and a line in its test-build comptime block), so the "
                      "module's step of `zig build test` compiles it and runs its tests", self.tree.check())

    def test_a_file_outside_the_module_is_not_required(self):
        self.tree.files["interfaces/main.zig"] = ("interfaces", "the executable")
        self.tree.build_roots["interfaces/main.zig"] = (None, "the executable")
        self.tree.outside_module["interfaces/main.zig"] = "its own root"
        self.tree.write("interfaces/main.zig", 'const ops = @import("operations").ops;\n')
        self.tree.write_build(BUILD.replace(MORE, '    _ = b.path("src/interfaces/main.zig");\n'))
        self.assertEqual(self.tree.check(doc=False), [])

    # The roots zig/build.zig compiles.

    def test_a_root_zig_build_names_that_the_table_lacks_fails(self):
        self.tree.write_build(BUILD.replace(MORE, '    _ = b.path("src/tests/other_root.zig");\n'))
        self.assertEqual(self.tree.check(), [
            "zig/build.zig:17: names src/tests/other_root.zig, which BUILD_ROOTS (scripts/check_layers.py) does not "
            "list: add it, with the step of `zig build test` it is the root of, or None"])

    def test_a_listed_root_zig_build_does_not_name_fails(self):
        self.tree.write_build(BUILD.replace('        .{ .name = "tests", .path = "src/tests/root.zig" },\n', ""))
        problems = self.tree.check()
        self.assertEqual(len(problems), 2, problems)
        self.assertIn("BUILD_ROOTS names tests/root.zig, which zig/build.zig does not name", problems[0])
        self.assertIn("BUILD_ROOTS makes tests/root.zig the root of the step 'tests', but no test the `test` step of "
                      "zig/build.zig runs is rooted there", problems[1])

    def test_a_missing_build_file_fails(self):
        (self.tree.root / "zig" / "build.zig").unlink()
        self.assertIn("zig/build.zig:1: missing; the checker reads the roots of `zig build test` from it",
                      self.tree.check())

    def test_the_repository_s_build_roots_are_the_build_s(self):
        text = (REPO / "zig" / "build.zig").read_text(encoding="utf-8")
        self.assertEqual({rel for _, rel in check_layers.build_root_paths(text)}, set(check_layers.BUILD_ROOTS))
        steps = [step for step, _ in check_layers.BUILD_ROOTS.values() if step]
        self.assertEqual(sorted(steps), ["core", "fastmem", "interfaces", "operations", "tests"])

    def test_the_repository_s_test_steps_are_read_from_the_build(self):
        steps, problems = check_layers.build_test_steps((REPO / "zig" / "build.zig").read_text(encoding="utf-8"))
        self.assertEqual(problems, [])
        self.assertEqual(sorted((label, root) for label, root, _, _ in steps), [
            ("", "core/fastmem.zig"), ("core", "core/core.zig"), ("interfaces", "interfaces/interfaces.zig"),
            ("operations", "ops/operations.zig"), ("tests", "tests/root.zig")])


# The three edits of zig/build.zig the S6-T15 Verdict found passing the checker (finding 1),
# applied to the repository's own build file in a synthetic tree of the same roots.
REAL_BUILD = (REPO / "zig" / "build.zig").read_text(encoding="utf-8")


class BuildStepTests(unittest.TestCase):
    """S6-T15 rework: the steps of `zig build test` are read from zig/build.zig's structure."""

    def setUp(self):
        roots = dict(BUILD_ROOTS)
        roots["core/fastmem.zig"] = ("fastmem", "its own step")
        self.tree = Tree(build_roots=roots, build=BUILD.replace(MORE, FASTMEM))
        self.tree.files["core/fastmem.zig"] = ("core", "memcpy")
        self.tree.outside_module["core/fastmem.zig"] = "its own object"
        self.tree.write("core/fastmem.zig", 'test "fastmem" {}\n')

    def tearDown(self):
        self.tree.close()

    def edit(self, old, new):
        text = BUILD.replace(MORE, FASTMEM)
        self.assertEqual(text.count(old), 1, old)
        self.tree.write_build(text.replace(old, new))
        return self.tree.check(doc=False)

    def test_the_clean_build_passes_and_gives_each_step_its_label(self):
        report = {}
        self.assertEqual(self.tree.check(doc=False, report=report), [])
        self.assertEqual(report["labels"], {"core/core.zig": "core", "ops/operations.zig": "operations",
                                            "interfaces/interfaces.zig": "interfaces", "tests/root.zig": "tests",
                                            "core/fastmem.zig": ""})

    def test_deleting_the_core_row_fails(self):
        problems = self.edit('        .{ .name = "core", .path = "src/core/core.zig" },\n', "")
        self.assertIn("BUILD_ROOTS makes core/core.zig the root of the step 'core', but no test the `test` step of "
                      "zig/build.zig runs is rooted there", " ".join(problems))

    def test_a_test_the_test_step_does_not_run_fails(self):
        problems = self.edit("    test_step.dependOn(&b.addRunArtifact(fastmem_tests).step);\n",
                             "    _ = fastmem_tests;\n")
        joined = " ".join(problems)
        self.assertIn("b.addTest (fastmem_tests) is compiled but the `test` step does not run it", joined)
        self.assertIn("BUILD_ROOTS makes core/fastmem.zig the root of the step 'fastmem'", joined)

    def test_one_root_pasted_into_another_row_fails(self):
        problems = self.edit('.{ .name = "operations", .path = "src/ops/operations.zig" }',
                             '.{ .name = "operations", .path = "src/core/core.zig" }')
        joined = " ".join(problems)
        self.assertIn("src/core/core.zig is the root of 2 test steps", joined)
        self.assertIn("the test_roots row 'operations' is rooted at src/core/core.zig, the root of the step 'core'",
                      joined)
        self.assertIn("BUILD_ROOTS makes ops/operations.zig the root of the step 'operations'", joined)

    def test_a_row_for_a_root_without_a_step_fails(self):
        self.tree.build_roots["interfaces/main.zig"] = (None, "the executable")
        self.tree.files["interfaces/main.zig"] = ("interfaces", "the executable")
        self.tree.outside_module["interfaces/main.zig"] = "its own root"
        self.tree.write("interfaces/main.zig", 'const ops = @import("operations").ops;\n')
        problems = self.edit(ROWS, ROWS + '        .{ .name = "main", .path = "src/interfaces/main.zig" },\n')
        self.assertIn("a test step is rooted at src/interfaces/main.zig, which BUILD_ROOTS (scripts/check_layers.py) "
                      "gives no step", " ".join(problems))

    def test_a_loop_test_not_named_by_its_row_fails(self):
        problems = self.edit("const name = root.name;", 'const name = "all";')
        self.assertIn("the test compiled in the loop over test_roots is not named `root.name`", " ".join(problems))

    def test_no_test_step_fails(self):
        problems = self.edit('const test_step = b.step("test", "Run the tests");', 'const test_step = b.step("t", "");')
        self.assertIn('no `const ... = b.step("test", ...)`', " ".join(problems))

    def test_a_test_outside_the_loop_named_otherwise_than_step_labels_fails(self):
        # The count comparison matches steps by the Build Summary's name (STEP_LABELS).
        self.tree.write_build(BUILD.replace(MORE, FASTMEM.replace(".{ .root_module", '.{ .name = "mem", .root_module')))
        self.assertEqual(self.tree.check(doc=False), [
            "zig/build.zig:17: the test rooted at src/core/fastmem.zig is named 'mem', so the Build Summary shows "
            "`run test mem`; the step 'fastmem' is expected as `run test` (STEP_LABELS in scripts/check_layers.py)"])

    def test_the_verifier_s_edits_to_the_real_build_fail(self):
        # Finding 1's three edits, on the real zig/build.zig: each makes build_test_steps
        # disagree with the repository's BUILD_ROOTS.
        edits = {
            "remove the core row": ('        .{ .name = "core", .path = "src/core/core.zig" },\n', ""),
            "drop fastmem's dependOn": ("    test_step.dependOn(&b.addRunArtifact(fastmem_tests).step);\n",
                                        "    _ = fastmem_tests;\n"),
            "paste core's path into the operations row": (
                '.{ .name = "operations", .path = "src/ops/operations.zig" }',
                '.{ .name = "operations", .path = "src/core/core.zig" }'),
        }
        for what, (old, new) in edits.items():
            with self.subTest(what):
                self.assertEqual(REAL_BUILD.count(old), 1, old)
                steps, unread = check_layers.build_test_steps(REAL_BUILD.replace(old, new))
                roots = sorted(root for _, root, _, _ in steps)
                want = sorted(rel for rel, (step, _) in check_layers.BUILD_ROOTS.items() if step)
                self.assertTrue(unread or roots != want, (what, steps))


FASTMEM = "\n".join([
    "    const fastmem_tests = b.addTest(.{ .root_module = fastmemModule(b) });",
    "    test_step.dependOn(&b.addRunArtifact(fastmem_tests).step);",
    "}",
    "",
    "fn fastmemModule(b: *std.Build) *std.Build.Module {",
    '    return b.createModule(.{ .root_source_file = b.path("src/core/fastmem.zig") });',
    "",
])


class CoreApiTests(unittest.TestCase):
    """S6-T16: ops/ and interfaces/ reach the core only through `api` (docs/core-api.md)."""

    def setUp(self):
        self.tree = Tree()
        # A core name to publish: engine.zig gains `pub const Engine`, and `api.engine` lists it.
        self.tree.write("core/engine.zig", CLEAN["core/engine.zig"] + "pub const Engine = struct {};\n"
                                                                      "pub fn open() void {}\n")
        self.write_api("    /// The engine.\n    pub const engine = struct {\n        /// An opened generation.\n"
                       "        pub const Engine = internal.engine.Engine;\n    };\n")

    def tearDown(self):
        self.tree.close()

    def write_api(self, body, tail="const internal = @This();\n"):
        head, _, _ = CLEAN["core/core.zig"].partition("/// The public core API.")
        self.tree.write("core/core.zig", head + "/// The public core API.\npub const api = struct {\n" + body
                        + "};\n" + tail)

    def use(self, rel, text):
        self.tree.write(rel, CLEAN[rel] + text)
        return self.tree.check()

    INTERNAL = ('outside the public core API: operations and interfaces reach the core through @import("core").api '
                "(docs/core-api.md); tests in tests/ may use internals")

    def test_a_published_name_passes_inline_and_through_aliases(self):
        self.assertEqual(self.use("ops/ops.zig", "const E = engine.Engine;\n"
                                                 "const F = @import(\"core\").api.engine.Engine;\n"
                                                 "const core = @import(\"core\").api;\n"
                                                 "fn f() void { const e = core.engine; _ = e.Engine.x; }\n"), [])

    def test_the_clean_tree_s_tests_use_internals_and_pass(self):
        self.assertIn('@import("core").engine', CLEAN["tests/engine_test.zig"])
        self.assertEqual(self.tree.check(), [])

    def test_planted_internal_inline_in_ops_fails(self):
        self.assertEqual(self.use("ops/ops.zig", 'const S = @import("core").store.Store;\n'), [
            "zig/src/ops/ops.zig:2: uses core.store.Store, " + self.INTERNAL])

    def test_planted_internal_alias_in_interfaces_fails_once_at_the_binding(self):
        self.assertEqual(self.use("interfaces/cli.zig", 'const store = @import("core").store;\n'
                                                        "fn f() void { _ = store.Store; _ = store.open; }\n"), [
            "zig/src/interfaces/cli.zig:3: uses core.store, " + self.INTERNAL])

    def test_an_internal_in_a_test_block_of_an_interface_fails(self):
        self.assertEqual(self.use("interfaces/rpc.zig", 'test "x" {\n    const e = @import("core").engine;\n'
                                                        "    _ = e.Engine;\n}\n"), [
            "zig/src/interfaces/rpc.zig:4: uses core.engine, " + self.INTERNAL])

    def test_a_name_the_namespace_lacks_fails(self):
        self.assertEqual(self.use("ops/ops.zig", "fn f() void { _ = engine.open; }\n"), [
            "zig/src/ops/ops.zig:2: uses core.api.engine.open, which api.engine does not have: add it by the rule "
            "in docs/core-api.md"])

    def test_a_name_the_namespace_lacks_fails_through_an_alias_of_an_alias(self):
        problems = self.use("interfaces/cli.zig", 'const core = @import("core").api;\nconst e = core.engine;\n'
                                                  "const O = e.open;\n")
        self.assertEqual(problems, ["zig/src/interfaces/cli.zig:5: uses core.api.engine.open, which api.engine does "
                                    "not have: add it by the rule in docs/core-api.md"])

    def test_a_namespace_api_lacks_fails(self):
        self.assertEqual(self.use("ops/ops.zig", 'const store = @import("core").api.store;\n'), [
            "zig/src/ops/ops.zig:2: uses core.api.store, but api has no namespace store: add the name to api by the "
            "rule in docs/core-api.md"])

    WHOLE = ('binds the module core whole (const {} = @import("core")): operations and interfaces reach the core '
             'through @import("core").api (docs/core-api.md), written `@import("core").api`')

    def test_the_module_used_whole_fails(self):
        self.assertEqual(self.use("ops/ops.zig", 'test { _ = @field(@import("core"), "engine").Engine; }\n'), [
            'zig/src/ops/ops.zig:2: uses the module core whole: operations and interfaces reach the core through '
            '@import("core").api (docs/core-api.md)'])

    # S6-T16 Verdict, finding 1: a binding of the whole module fails wherever it is, once, at the binding.

    def test_a_binding_of_the_whole_module_fails_once_even_if_used_through_api(self):
        problems = self.use("ops/ops.zig", 'const core = @import("core");\nfn f() void { _ = core; '
                                           "_ = core.api.engine.Engine; _ = core.engine.Engine; }\n")
        self.assertEqual(problems, ["zig/src/ops/ops.zig:2: " + self.WHOLE.format("core")])

    def test_a_binding_of_the_whole_module_inside_a_struct_fails(self):
        problems = self.use("ops/ops.zig", 'const deps = struct {\n    const c = @import("core");\n};\n'
                                           "test { _ = deps.c.engine.Engine; }\n")
        self.assertEqual(problems, ["zig/src/ops/ops.zig:3: " + self.WHOLE.format("c")])

    def test_a_pub_binding_of_the_whole_module_fails(self):
        problems = self.use("interfaces/rpc.zig", 'pub const all = @import("core");\n')
        self.assertEqual(problems, ["zig/src/interfaces/rpc.zig:3: " + self.WHOLE.format("all")])

    def test_a_binding_of_api_whole_passes(self):
        self.assertEqual(self.use("ops/ops.zig", 'pub const core_api = @import("core").api;\n'
                                                 "const deps = struct { const c = @import(\"core\").api; };\n"
                                                 "test { _ = deps.c.engine.Engine; }\n"), [])

    def test_a_pub_internal_fails(self):
        problems = self.api_problems("    /// The engine.\n    pub const engine = struct {};\n",
                                     tail="pub const internal = @This();\n")
        self.assertEqual(problems, ["zig/src/core/core.zig:16: `internal` is `pub`: it names every core file, so a "
                                    "`pub` one would publish them all past `api` (`const internal = @This();`, never "
                                    "`pub`) (docs/core-api.md)"])

    def test_comments_strings_and_fields_named_like_an_alias_are_not_uses(self):
        self.assertEqual(self.use("ops/ops.zig", '// @import("core").store.Store\nconst s = "@import(\\"core\\").store";\n'
                                                 "const T = struct { engine: u8 };\nconst v = .{ .engine = 1 };\n"
                                                 "fn f(t: T) u8 { return t.engine; }\n"), [])

    def test_without_api_every_use_of_it_fails(self):
        head, _, _ = CLEAN["core/core.zig"].partition("/// The public core API.")
        self.tree.write("core/core.zig", head)
        problems = self.tree.check()
        self.assertEqual(problems, [
            "zig/src/interfaces/cli.zig:2: imports core.api, which zig/src/core/core.zig does not export "
            "(no pub const api)",
            "zig/src/interfaces/cli.zig:2: uses core.api.engine, but api has no namespace engine: add the name to api "
            "by the rule in docs/core-api.md",
            "zig/src/ops/ops.zig:1: imports core.api, which zig/src/core/core.zig does not export (no pub const api)",
            "zig/src/ops/ops.zig:1: uses core.api.engine, but api has no namespace engine: add the name to api by "
            "the rule in docs/core-api.md"])

    # The shape of `api` itself.

    def api_problems(self, body, tail="const internal = @This();\n"):
        self.write_api(body, tail)
        return [p for p in self.tree.check() if p.startswith("zig/src/core/core.zig")]

    def test_an_entry_renamed_or_from_another_file_fails(self):
        for entry in ("pub const Handle = internal.engine.Engine;", "pub const Engine = internal.store.Engine;",
                      "pub const Engine = engine_file.Engine;", "pub fn Engine() void {}"):
            problems = self.api_problems("    /// The engine.\n    pub const engine = struct {\n        /// E.\n"
                                         f"        {entry}\n    }};\n")
            self.assertEqual(len(problems), 1, (entry, problems))
            self.assertIn("zig/src/core/core.zig:16: `api.engine` holds something other than an alias "
                          "`pub const NAME = internal.engine.NAME;`", problems[0])

    def test_a_missing_doc_comment_fails(self):
        problems = self.api_problems("    /// The engine.\n    pub const engine = struct {\n"
                                     "        pub const Engine = internal.engine.Engine;\n    };\n"
                                     "    pub const store = struct {};\n")
        self.assertEqual(problems, [
            "zig/src/core/core.zig:15: `api.engine.Engine` has no `///` doc comment (docs/core-api.md)",
            "zig/src/core/core.zig:17: `api.store` has no `///` doc comment (docs/core-api.md)"])

    def test_a_namespace_that_is_no_exported_core_file_fails(self):
        for ns in ("nothing", "store_test"):
            problems = self.api_problems(f"    /// X.\n    pub const {ns} = struct {{}};\n")
            self.assertEqual(len(problems), 1, problems)
            self.assertIn(f"zig/src/core/core.zig:14: `api.{ns}` is not a core file the root exports", problems[0])

    def test_a_name_its_file_does_not_declare_pub_fails(self):
        self.tree.write("core/engine.zig", CLEAN["core/engine.zig"] + "const Engine = struct {};\n")
        problems = [p for p in self.tree.check() if p.startswith("zig/src/core/core.zig")]
        self.assertEqual(problems, ["zig/src/core/core.zig:16: `api.engine.Engine` names zig/src/core/engine.zig's "
                                    "Engine, which is not a top-level pub declaration of it"])

    def test_api_without_internal_fails(self):
        problems = self.api_problems("    /// The engine.\n    pub const engine = struct {};\n", tail="")
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("does not declare `const internal = @This();`", problems[0])

    def test_something_other_than_a_namespace_in_api_fails(self):
        problems = self.api_problems("    /// A function.\n    pub fn helper() void {}\n")
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("zig/src/core/core.zig:14: `api` holds something other than a namespace", problems[0])

    def test_the_repository_s_api(self):
        text = (REPO / "zig" / "src" / "core" / "core.zig").read_text(encoding="utf-8")
        api, problems = check_layers.core_api(text)
        self.assertEqual(problems, [])
        self.assertEqual((len(api), sum(len(names) for _, names in api.values())), (24, 101))


class OneShotQueryTests(unittest.TestCase):
    """S6-T18: `title_field.derive` left `api`; the one-shot query `engine.queryOneShot` took its place."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        # The repository's own sources, build file and document: the real `api`.
        shutil.copytree(REPO / "zig" / "src", self.root / "zig" / "src")
        shutil.copy(REPO / "zig" / "build.zig", self.root / "zig" / "build.zig")
        (self.root / "docs").mkdir()
        shutil.copy(REPO / "docs" / "layers.md", self.root / "docs" / "layers.md")

    def tearDown(self):
        self.tmp.cleanup()

    def plant(self, rel, text):
        path = self.root / "zig" / "src" / rel
        before = path.read_text(encoding="utf-8")
        path.write_text(before + text, encoding="utf-8")
        return before.count("\n") + 1

    def test_the_api_has_the_call_and_not_the_derive(self):
        text = (REPO / "zig" / "src" / "core" / "core.zig").read_text(encoding="utf-8")
        api, problems = check_layers.core_api(text)
        self.assertEqual(problems, [])
        self.assertIn("queryOneShot", api["engine"][1])
        self.assertNotIn("derive", api["title_field"][1])
        self.assertEqual(sorted(api["title_field"][1]), ["policy_id"])

    def test_the_copy_passes(self):
        self.assertEqual(check_layers.check(self.root), [])

    def test_main_prints_the_api_s_size(self):
        out = io.StringIO()
        with redirect_stdout(out):
            code = check_layers.main(["--root", str(REPO)])
        self.assertEqual(code, 0, out.getvalue())
        self.assertIn("; the public core API `api`: 101 names in 24 namespaces)", out.getvalue())

    def test_main_prints_the_size_of_an_api_with_one_name_more(self):
        path = self.root / "zig" / "src" / "core" / "core.zig"
        text = path.read_text(encoding="utf-8")
        anchor = "        pub const queryOneShot = internal.engine.queryOneShot;\n"
        self.assertEqual(text.count(anchor), 1)
        path.write_text(text.replace(anchor, anchor + "        /// An open, planted.\n"
                                     "        pub const open = internal.engine.open;\n"), encoding="utf-8")
        (self.root / "zig" / "src" / "core" / "engine.zig").write_text(
            (REPO / "zig" / "src" / "core" / "engine.zig").read_text(encoding="utf-8") + "pub fn open() void {}\n",
            encoding="utf-8")
        out = io.StringIO()
        with redirect_stdout(out):
            code = check_layers.main(["--root", str(self.root)])
        self.assertEqual(code, 0, out.getvalue())
        self.assertIn("; the public core API `api`: 102 names in 24 namespaces)", out.getvalue())

    def test_a_planted_derive_in_interfaces_fails_inline_and_through_the_old_alias(self):
        first = self.plant("interfaces/cli.zig",
                           'const title_field = @import("core").api.title_field;\n'
                           "fn plantedRunSearch(a: std.mem.Allocator, engine: engine_module.Engine) !void {\n"
                           "    const title = try title_field.derive(a, a, engine.documents, engine.roots);\n"
                           "    _ = title;\n"
                           '    _ = @import("core").api.title_field.derive;\n'
                           "}\n")
        missing = ("uses core.api.title_field.derive, which api.title_field does not have: add it by the rule in "
                   "docs/core-api.md")
        self.assertEqual(check_layers.check(self.root), [
            f"zig/src/interfaces/cli.zig:{first + 2}: {missing}",
            f"zig/src/interfaces/cli.zig:{first + 4}: {missing}"])

    def test_a_planted_derive_in_ops_fails(self):
        first = self.plant("ops/ops.zig", 'const planted = @import("core").api.title_field.derive;\n')
        self.assertEqual(check_layers.check(self.root), [
            f"zig/src/ops/ops.zig:{first}: uses core.api.title_field.derive, which api.title_field does not have: "
            "add it by the rule in docs/core-api.md"])

    def test_the_call_passes_where_cli_uses_it(self):
        self.plant("interfaces/mcp.zig", 'const planted = @import("core").api.engine.queryOneShot;\n')
        self.assertEqual(check_layers.check(self.root), [])


class TestOnlyNamesTests(unittest.TestCase):
    """S6-T19: the two names only tests beside the code used left `api` once those tests moved to
    tests/: `analyzer_v2.analyzer_id` (and with it the namespace `analyzer_v2`) and `manifest.decode`."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        # The repository's own sources, build file and document: the real `api`.
        shutil.copytree(REPO / "zig" / "src", self.root / "zig" / "src")
        shutil.copy(REPO / "zig" / "build.zig", self.root / "zig" / "build.zig")
        (self.root / "docs").mkdir()
        shutil.copy(REPO / "docs" / "layers.md", self.root / "docs" / "layers.md")

    def tearDown(self):
        self.tmp.cleanup()

    def plant(self, rel, text):
        path = self.root / "zig" / "src" / rel
        before = path.read_text(encoding="utf-8")
        path.write_text(before + text, encoding="utf-8")
        return before.count("\n") + 1

    def test_the_api_has_neither_name(self):
        text = (REPO / "zig" / "src" / "core" / "core.zig").read_text(encoding="utf-8")
        api, problems = check_layers.core_api(text)
        self.assertEqual(problems, [])
        self.assertNotIn("analyzer_v2", api)
        self.assertEqual(sorted(api["manifest"][1]), ["PendingEntry", "create", "encode"])

    def test_the_moved_tests_use_internals_from_tests(self):
        for rel, name in (("tests/filename_response_test.zig", "analyzer_v2"), ("tests/abi_index_folder_test.zig", "manifest")):
            text = (REPO / "zig" / "src" / rel).read_text(encoding="utf-8")
            self.assertIn(f'@import("core").{name}', text)
        self.assertEqual(check_layers.check(self.root), [])

    def test_a_planted_analyzer_id_fails_in_ops_inline_in_a_test(self):
        first = self.plant("ops/filename_response.zig",
                           'test "planted" {\n    _ = @import("core").api.analyzer_v2.analyzer_id;\n}\n')
        self.assertEqual(check_layers.check(self.root), [
            f"zig/src/ops/filename_response.zig:{first + 1}: uses core.api.analyzer_v2.analyzer_id, but api has no "
            "namespace analyzer_v2: add the name to api by the rule in docs/core-api.md"])

    def test_a_planted_analyzer_id_fails_in_interfaces_through_an_alias(self):
        first = self.plant("interfaces/rpc.zig", 'const analyzer_v2 = @import("core").api.analyzer_v2;\n'
                                                 'test "planted" {\n    _ = analyzer_v2.analyzer_id;\n}\n')
        no_namespace = "but api has no namespace analyzer_v2: add the name to api by the rule in docs/core-api.md"
        self.assertEqual(check_layers.check(self.root), [
            f"zig/src/interfaces/rpc.zig:{first}: uses core.api.analyzer_v2, {no_namespace}",
            f"zig/src/interfaces/rpc.zig:{first + 2}: uses core.api.analyzer_v2.analyzer_id, {no_namespace}"])

    def test_a_planted_decode_fails_in_interfaces_through_the_file_s_alias(self):
        first = self.plant("interfaces/abi.zig", 'test "planted" {\n    _ = manifest.decode;\n}\n')
        self.assertEqual(check_layers.check(self.root), [
            f"zig/src/interfaces/abi.zig:{first + 1}: uses core.api.manifest.decode, which api.manifest does not "
            "have: add it by the rule in docs/core-api.md"])

    def test_a_planted_decode_fails_in_ops_inline(self):
        first = self.plant("ops/service.zig", 'const planted = @import("core").api.manifest.decode;\n')
        self.assertEqual(check_layers.check(self.root), [
            f"zig/src/ops/service.zig:{first}: uses core.api.manifest.decode, which api.manifest does not have: "
            "add it by the rule in docs/core-api.md"])


if __name__ == "__main__":
    unittest.main()
