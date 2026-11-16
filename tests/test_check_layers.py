"""S6-T1: the layer checker (scripts/check_layers.py, docs/layers.md).

The real repository must pass; small synthetic trees show that each rule fails
with the file and line named."""

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
    "engine.zig": ("core", "the engine"),
    "store.zig": ("core", "a format"),
    "ops.zig": ("operations", "the seam"),
    "cli.zig": ("interfaces", "commands"),
    "rpc.zig": ("interfaces", "json-rpc"),
    "mcp.zig": ("interfaces", "mcp"),
}
ALLOWED = {("mcp.zig", "cli.zig"): ("debt", "the arguments")}
EXEMPT_FILES = {"root.zig": "the test root"}
CLEAN = {
    "engine.zig": 'const std = @import("std");\nconst store = @import("store.zig");\n',
    "store.zig": 'const std = @import("std");\n',
    "ops.zig": 'const engine = @import("engine.zig");\n',
    "cli.zig": 'const ops = @import("ops.zig");\nconst engine = @import("engine.zig");\n',
    "rpc.zig": 'const ops = @import("ops.zig");\nconst options = @import("build_options");\n',
    "mcp.zig": 'const ops = @import("ops.zig");\nconst cli = @import("cli.zig");\n',
    "root.zig": 'const cli = @import("cli.zig");\nconst mcp = @import("mcp.zig");\n',
    "engine_test.zig": 'const rpc = @import("rpc.zig");\n',
    "query_bench.zig": 'const mcp = @import("mcp.zig");\n',
}


class Tree:
    """A temporary repository with zig/src and docs/layers.md."""

    def __init__(self, sources=None, files=FILES, allowed=ALLOWED, exempt_files=EXEMPT_FILES):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.files, self.allowed, self.exempt_files = dict(files), dict(allowed), dict(exempt_files)
        for rel, text in (CLEAN if sources is None else sources).items():
            self.write(rel, text)
        doc = self.root / "docs" / "layers.md"
        doc.parent.mkdir(parents=True)
        doc.write_text("# Layers\n\n" + self.render() + "\n\nAfter.\n", encoding="utf-8")

    def write(self, rel, text):
        path = self.root / "zig" / "src" / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def render(self):
        return check_layers.render_doc(self.files, self.allowed, self.exempt_files)

    def check(self, doc=True):
        return check_layers.check(self.root, self.files, self.allowed, self.exempt_files, doc=doc)

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
        self.assertEqual(check_layers.ALLOWED[("mcp.zig", "cli.zig")][0], "debt")

    def test_every_layer_is_known(self):
        for rel, (layer, role) in check_layers.FILES.items():
            self.assertIn(layer, check_layers.LAYER_ORDER, rel)
            self.assertTrue(role, rel)


class RuleTests(unittest.TestCase):
    def setUp(self):
        self.tree = Tree()

    def tearDown(self):
        self.tree.close()

    def test_clean_tree_passes(self):
        self.assertEqual(self.tree.check(), [])

    def test_core_importing_operations_fails_with_file_and_line(self):
        self.tree.write("engine.zig", CLEAN["engine.zig"] + 'const ops = @import("ops.zig");\n')
        self.assertEqual(self.tree.check(), [
            "zig/src/engine.zig:3: core file imports ops.zig (operations); core may import core only"])

    def test_core_importing_an_interface_fails(self):
        self.tree.write("store.zig", 'const rpc = @import("rpc.zig");\n')
        self.assertEqual(self.tree.check(), [
            "zig/src/store.zig:1: core file imports rpc.zig (interfaces); core may import core only"])

    def test_operations_importing_an_interface_fails(self):
        self.tree.write("ops.zig", CLEAN["ops.zig"] + 'const cli = @import("cli.zig");\n')
        self.assertEqual(self.tree.check(), [
            "zig/src/ops.zig:2: operations file imports cli.zig (interfaces); "
            "operations may import core and operations"])

    def test_an_interface_importing_another_fails_unless_allowed(self):
        self.tree.write("rpc.zig", 'const cli = @import("cli.zig");\n')
        self.assertEqual(self.tree.check(), [
            "zig/src/rpc.zig:1: interface file imports cli.zig, another interface, "
            "and the pair is not in ALLOWED (scripts/check_layers.py)"])

    def test_removing_the_allowed_pair_fails(self):
        self.tree.allowed = {}
        problems = self.tree.check(doc=False)
        self.assertEqual(problems, [
            "zig/src/mcp.zig:2: interface file imports cli.zig, another interface, "
            "and the pair is not in ALLOWED (scripts/check_layers.py)"])

    def test_an_allowed_pair_that_no_longer_occurs_fails(self):
        self.tree.write("mcp.zig", CLEAN["mcp.zig"].replace('const cli = @import("cli.zig");\n', ""))
        problems = self.tree.check()
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("allowed pair mcp.zig -> cli.zig no longer occurs", problems[0])

    def test_an_unassigned_file_fails(self):
        self.tree.write("extra.zig", 'const std = @import("std");\n')
        problems = self.tree.check()
        self.assertEqual(len(problems), 1, problems)
        self.assertTrue(problems[0].startswith("zig/src/extra.zig:1: not assigned to a layer"), problems[0])

    def test_an_assigned_file_that_no_longer_exists_fails(self):
        (self.tree.root / "zig" / "src" / "store.zig").unlink()
        self.tree.write("engine.zig", 'const std = @import("std");\n')
        problems = self.tree.check()
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("FILES names zig/src/store.zig, which does not exist", problems[0])

    def test_an_exempt_file_that_no_longer_exists_fails(self):
        (self.tree.root / "zig" / "src" / "root.zig").unlink()
        problems = self.tree.check()
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("EXEMPT_FILES names zig/src/root.zig, which does not exist", problems[0])

    def test_tests_and_benchmarks_are_exempt_but_must_match_a_pattern(self):
        # engine_test.zig imports rpc.zig and query_bench.zig imports mcp.zig: allowed.
        self.assertEqual(self.tree.check(), [])
        self.tree.write("engine_tests.zig", 'const rpc = @import("rpc.zig");\n')
        problems = self.tree.check()
        self.assertEqual(len(problems), 1, problems)
        self.assertTrue(problems[0].startswith("zig/src/engine_tests.zig:1: not assigned"), problems[0])

    def test_an_assigned_file_importing_a_test_file_fails(self):
        self.tree.write("ops.zig", CLEAN["ops.zig"] + 'const t = @import("engine_test.zig");\n')
        self.assertEqual(self.tree.check(), [
            "zig/src/ops.zig:2: operations file imports engine_test.zig, a test, benchmark or tool file"])

    def test_comments_and_strings_are_not_imports(self):
        self.tree.write("engine.zig", "\n".join([
            '// const ops = @import("ops.zig");',
            'const store = @import("store.zig"); // was @import("rpc.zig")',
            'const text = "@import(\\"cli.zig\\")";',
            '    \\\\ @import("mcp.zig") in a multiline string',
            "const quote = '\"'; const s = @import(\"store.zig\");",
            'const url = "http://example.invalid"; const t = @import("store.zig");',
            "",
        ]))
        self.assertEqual(self.tree.check(), [])

    # Rework after the first Verdict: the verifier's plants P1, P2 and P6, and their kin.

    def core_imports(self, text):
        """engine.zig (core) given text after a clean first line; the problems found."""
        self.tree.write("engine.zig", 'const store = @import("store.zig");\n' + text)
        return self.tree.check()

    def test_p1_an_import_over_three_lines_with_a_trailing_comma(self):
        self.assertEqual(self.core_imports('const ops_plant = @import(\n    "ops.zig",\n);\n'), [
            "zig/src/engine.zig:2: core file imports ops.zig (operations); core may import core only"])

    def test_p2_spaces_before_and_inside_the_parentheses(self):
        self.assertEqual(self.core_imports('const a = @import ("ops.zig");\nconst b = @import\t(\n"ops.zig" ) ;\n'), [
            "zig/src/engine.zig:2: core file imports ops.zig (operations); core may import core only",
            "zig/src/engine.zig:3: core file imports ops.zig (operations); core may import core only"])

    def test_p6_a_path_out_of_zig_src_and_back_in(self):
        self.assertEqual(self.core_imports('const ops_plant = @import("../src/ops.zig");\n'), [
            "zig/src/engine.zig:2: core file imports ../src/ops.zig (operations); core may import core only"])

    def test_dot_segments_resolve(self):
        self.assertEqual(self.core_imports('const a = @import("./ops.zig");\nconst b = @import("x/../ops.zig");\n'), [
            "zig/src/engine.zig:2: core file imports ./ops.zig (operations); core may import core only",
            "zig/src/engine.zig:3: core file imports x/../ops.zig (operations); core may import core only"])

    def test_escapes_in_the_string_are_decoded(self):
        # Zig 0.16.0 compiles both (S6-T1 rework, scratch probe).
        self.assertEqual(self.core_imports('const a = @import("ops\\x2ezig");\nconst b = @import("ops\\u{2e}zig");\n'), [
            "zig/src/engine.zig:2: core file imports ops.zig (operations); core may import core only",
            "zig/src/engine.zig:3: core file imports ops.zig (operations); core may import core only"])

    def test_a_target_outside_zig_src_fails(self):
        problems = self.core_imports('const a = @import("../../tools/x.zig");\n')
        self.assertEqual(problems, ["zig/src/engine.zig:2: imports ../../tools/x.zig, which is outside zig/src/"])

    def test_a_target_naming_no_file_fails(self):
        problems = self.core_imports('const a = @import("nope.zig");\n')
        self.assertEqual(problems, ["zig/src/engine.zig:2: imports nope.zig, which resolves to zig/src/nope.zig: no such file"])

    def test_an_imported_unassigned_file_fails_at_the_import_too(self):
        self.tree.write(".hidden/extra.zig", 'const std = @import("std");\n')
        problems = self.core_imports('const a = @import(".hidden/extra.zig");\n')
        self.assertEqual(problems, [
            "zig/src/.hidden/extra.zig:1: not assigned to a layer: add it to FILES in scripts/check_layers.py "
            "(core, operations or interfaces), then run scripts/check_layers.py --write-doc",
            "zig/src/engine.zig:2: imports .hidden/extra.zig (zig/src/.hidden/extra.zig), which is not assigned to a layer"])

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
                         ["zig/src/engine.zig:2", "zig/src/engine.zig:4", "zig/src/engine.zig:5", "zig/src/engine.zig:8"])
        self.assertTrue(all("not one string literal" in p for p in problems[:3]), problems)
        self.assertIn("@import without an argument list", problems[3])

    def test_named_modules_are_listed_and_bound_to_layers(self):
        problems = self.core_imports('const b = @import("builtin");\nconst t = @import("tool_schemas");\n'
                                     'const u = @import("unknown_module");\n')
        self.assertEqual(problems, [
            "zig/src/engine.zig:3: core file imports the module tool_schemas, which only interfaces may import",
            "zig/src/engine.zig:4: imports 'unknown_module', which is neither a .zig file nor a module listed "
            "in MODULES (scripts/check_layers.py)"])

    def test_p3_text_that_only_looks_like_an_import_is_ignored(self):
        self.assertEqual(self.core_imports("\n".join([
            '// const a = @import("ops.zig");',
            '/// @import("ops.zig") in a doc comment',
            '//! @import("ops.zig") in a top-level doc comment',
            'const s1 = "say \\"@import(\\\\\\"ops.zig\\\\\\")\\" // not a comment";',
            'const s2 = "@import(\\"ops.zig\\")";',
            "const m = ",
            '    \\\\@import("ops.zig")',
            '    \\\\@import(',
            '    \\\\    "ops.zig",',
            "    \\\\)",
            ";",
            "const q = '\"'; const r = '\\''; const s = '@';",
            'const url = "http://example.invalid"; // @import("ops.zig")',
            'const @"@import(\\"ops.zig\\")" = 1;',
            "",
        ])), [])

    def test_imports_resolve_relative_to_the_importing_file(self):
        self.tree.files = {
            "core/engine.zig": ("core", "the engine"),
            "ops/ops.zig": ("operations", "the seam"),
        }
        self.tree.allowed, self.tree.exempt_files = {}, {}
        for rel in list(CLEAN):
            (self.tree.root / "zig" / "src" / rel).unlink()
        self.tree.write("core/engine.zig", 'const ops = @import("../ops/ops.zig");\n')
        self.tree.write("ops/ops.zig", 'const engine = @import("../core/engine.zig");\n')
        self.assertEqual(self.tree.check(doc=False), [
            "zig/src/core/engine.zig:1: core file imports ../ops/ops.zig (operations); core may import core only"])

    def test_the_document_out_of_step_fails_with_its_line(self):
        doc = self.tree.root / "docs" / "layers.md"
        doc.write_text(doc.read_text(encoding="utf-8").replace("| `store.zig` | core |", "| `store.zig` | operations |"),
                       encoding="utf-8")
        problems = self.tree.check()
        self.assertEqual(len(problems), 1, problems)
        line = int(problems[0].split(":")[1])
        self.assertIn("`store.zig` | operations", doc.read_text(encoding="utf-8").split("\n")[line - 1])
        self.assertIn("the generated block differs", problems[0])

    def test_the_document_without_markers_fails(self):
        (self.tree.root / "docs" / "layers.md").write_text("# Layers\n", encoding="utf-8")
        problems = self.tree.check()
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("no generated block", problems[0])

    def test_an_allowed_pair_must_join_two_interfaces(self):
        self.tree.allowed = {**ALLOWED, ("ops.zig", "cli.zig"): ("debt", "wrong")}
        problems = self.tree.check(doc=False)
        self.assertIn("is not between two interface files", " ".join(problems))


if __name__ == "__main__":
    unittest.main()
