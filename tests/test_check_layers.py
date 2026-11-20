"""S6-T1, S6-T14: the layer checker (scripts/check_layers.py, docs/layers.md).

The real repository must pass; small synthetic trees in the folder layout
(core/, ops/, interfaces/, tests/) show that each rule fails with the file and
line named."""

from __future__ import annotations

import io
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
CLEAN = {
    "core/core.zig": 'pub const engine = @import("engine.zig");\npub const store = @import("store.zig");\n'
                     'pub const store_test = @import("store_test.zig");\n',
    "core/engine.zig": 'const std = @import("std");\nconst store = @import("store.zig");\n',
    "core/store.zig": 'const std = @import("std");\n',
    "core/store_test.zig": 'const store = @import("store.zig");\n',
    "ops/operations.zig": 'pub const ops = @import("ops.zig");\n',
    "ops/ops.zig": 'const engine = @import("core").engine;\n',
    "interfaces/interfaces.zig": 'pub const cli = @import("cli.zig");\npub const rpc = @import("rpc.zig");\n'
                                 'pub const mcp = @import("mcp.zig");\n',
    "interfaces/cli.zig": 'const ops = @import("operations").ops;\nconst engine = @import("core").engine;\n',
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
                 module_roots=MODULE_ROOTS):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.files, self.allowed, self.exempt_files = dict(files), dict(allowed), dict(exempt_files)
        self.module_roots = dict(module_roots)
        for rel, text in (CLEAN if sources is None else sources).items():
            self.write(rel, text)
        doc = self.root / "docs" / "layers.md"
        doc.parent.mkdir(parents=True)
        doc.write_text("# Layers\n\n" + self.render() + "\n\nAfter.\n", encoding="utf-8")

    def write(self, rel, text):
        path = self.root / "zig" / "src" / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def remove(self, rel):
        (self.root / "zig" / "src" / rel).unlink()

    def render(self):
        return check_layers.render_doc(self.files, self.allowed, self.exempt_files, module_roots=self.module_roots)

    def check(self, doc=True):
        return check_layers.check(self.root, self.files, self.allowed, self.exempt_files, doc=doc,
                                  module_roots=self.module_roots)

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
                                         'pub const store_test = @import("store_test.zig");\n')
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


if __name__ == "__main__":
    unittest.main()
