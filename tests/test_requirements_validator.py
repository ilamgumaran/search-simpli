"""Negative fixtures for the requirements-register validator.

Builds a minimal but fully-consistent doc tree in a temp dir, asserts it passes,
then injects one defect per failure mode and asserts the validator catches it.
Dependency-free (unittest + tempfile), per NFR-01.
"""
import importlib.util
import tempfile
import unittest
from pathlib import Path

_SPEC = Path(__file__).resolve().parents[1] / "scripts" / "check_requirements.py"
_mod_spec = importlib.util.spec_from_file_location("check_requirements", _SPEC)
checker = importlib.util.module_from_spec(_mod_spec)
_mod_spec.loader.exec_module(checker)


def write_valid_tree(root):
    """Create a minimal tree the validator accepts. Returns the root Path."""
    root = Path(root)
    (root / "docs" / "requirements").mkdir(parents=True)
    (root / "docs" / "recreation").mkdir(parents=True)
    (root / "docs" / "use-cases").mkdir(parents=True)
    (root / "contracts").mkdir(parents=True)

    (root / "docs" / "requirements" / "README.md").write_text(
        "## Capability catalog (CAP)\n"
        "| ID | Capability | Use cases | Key requirements | Status / evidence |\n"
        "|---|---|---|---|---|\n"
        "| CAP-01 | [X](cap-01-x.md) | UC-001 | FR-01, NFR-01 | Proposed |\n\n"
        "## Functional requirements (FR)\n"
        "| ID | Requirement | Capability | Status |\n"
        "|---|---|---|---|\n"
        "| FR-01 | x | CAP-01 | Proposed |\n\n"
        "## Non-functional requirements (NFR)\n"
        "| ID | Requirement | Applies to | Status |\n"
        "|---|---|---|---|\n"
        "| NFR-01 | x | CAP-01 | Standing |\n\n"
        "## Contracts (CON)\n"
        "| ID | Schema | Purpose |\n"
        "|---|---|---|\n"
        "| CON-01 | `contracts/a.schema.json` | x |\n\n"
        "## Conflict register (CFT)\n"
        "| ID | Between | Tension | Resolution | Status |\n"
        "|---|---|---|---|---|\n"
        "| CFT-01 | CAP-01 (x) INV-01 | t | r | Resolved |\n"
    )
    (root / "docs" / "requirements" / "cap-01-x.md").write_text(
        "# CAP-01 — X\n\n"
        "Traces to FR-01 for UC-001, contract CON-01.\n\n"
        "## 8b. Dependencies\n- none\n\n"
        "## 12. Maintainer approval\n- Status: Pending approval\n"
    )
    (root / "docs" / "recreation" / "specification.md").write_text(
        "# spec\n\nFR-01 is defined here.\nNFR-01 is defined here.\n"
    )
    (root / "docs" / "use-cases" / "README.md").write_text(
        "| ID | Use case | ... |\n|---|---|---|\n| UC-001 | [x](uc-001-x.md) | a |\n"
    )
    (root / "docs" / "use-cases" / "uc-001-x.md").write_text("# UC-001\n")
    (root / "contracts" / "a.schema.json").write_text("{}\n")
    return root


class RequirementsValidatorTests(unittest.TestCase):
    def _with_tree(self):
        self._tmp = tempfile.TemporaryDirectory()
        return write_valid_tree(self._tmp.name)

    def tearDown(self):
        tmp = getattr(self, "_tmp", None)
        if tmp:
            tmp.cleanup()

    def _assert_fails(self, root, needle):
        errors = checker.validate(root)
        self.assertTrue(errors, "expected validation to fail but it passed")
        self.assertTrue(
            any(needle in e for e in errors),
            f"expected an error containing '{needle}', got: {errors}",
        )

    def test_valid_tree_passes(self):
        self.assertEqual(checker.validate(self._with_tree()), [])

    def test_undefined_uc_reference(self):
        root = self._with_tree()
        reg = root / "docs" / "requirements" / "README.md"
        reg.write_text(reg.read_text().replace("UC-001", "UC-999", 1))
        self._assert_fails(root, "UC-999")

    def test_fr_missing_from_specification(self):
        root = self._with_tree()
        spec = root / "docs" / "recreation" / "specification.md"
        spec.write_text(spec.read_text().replace("FR-01 is defined here.\n", ""))
        self._assert_fails(root, "FR-01 is in the register but absent from specification.md")

    def test_missing_approval_block(self):
        root = self._with_tree()
        cap = root / "docs" / "requirements" / "cap-01-x.md"
        cap.write_text(cap.read_text().replace("## 12. Maintainer approval", "## 12. Notes"))
        self._assert_fails(root, "maintainer-approval block")

    def test_missing_dependencies_section(self):
        root = self._with_tree()
        cap = root / "docs" / "requirements" / "cap-01-x.md"
        cap.write_text(cap.read_text().replace("## 8b. Dependencies", "## 8b. Notes")
                       .replace("Dependencies", "Notes"))
        self._assert_fails(root, "Dependencies section")

    def test_bad_status_token(self):
        root = self._with_tree()
        reg = root / "docs" / "requirements" / "README.md"
        reg.write_text(reg.read_text().replace("| FR-01 | x | CAP-01 | Proposed |",
                                               "| FR-01 | x | CAP-01 | Bogus-status |"))
        self._assert_fails(root, "not in allowed vocabulary")

    def test_invariant_conflict_cannot_be_accepted(self):
        root = self._with_tree()
        reg = root / "docs" / "requirements" / "README.md"
        reg.write_text(reg.read_text().replace(
            "| CFT-01 | CAP-01 (x) INV-01 | t | r | Resolved |",
            "| CFT-01 | CAP-01 (x) INV-01 | t | r | Accepted with rationale |"))
        self._assert_fails(root, "touches an invariant but is 'Accepted'")

    def test_dangling_cap_reference(self):
        root = self._with_tree()
        reg = root / "docs" / "requirements" / "README.md"
        reg.write_text(reg.read_text().replace("| FR-01 | x | CAP-01 | Proposed |",
                                               "| FR-01 | x | CAP-77 | Proposed |"))
        self._assert_fails(root, "CAP-77")

    def test_undefined_con_reference(self):
        root = self._with_tree()
        cap = root / "docs" / "requirements" / "cap-01-x.md"
        cap.write_text(cap.read_text().replace("CON-01", "CON-42"))
        self._assert_fails(root, "CON-42")

    def test_missing_capability_spec_link(self):
        root = self._with_tree()
        (root / "docs" / "requirements" / "cap-01-x.md").unlink()
        self._assert_fails(root, "missing spec")


if __name__ == "__main__":
    unittest.main()
