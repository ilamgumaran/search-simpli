"""Test privacy rules for the repository.

S1-T5 criterion 3: tracked text files must not contain absolute home paths.
"""

import importlib.util
import os
import subprocess
import unittest
from pathlib import Path


class PrivacyTest(unittest.TestCase):
    """Test privacy constraints."""

    def test_no_home_paths_in_tracked_files(self):
        """Verify no home paths like /Users/<name>/ or /home/<name>/ in tracked files.

        S1-T5 criterion 3: use <home>/... instead.
        """
        # Run the check script
        script_path = Path(__file__).parent.parent / "scripts" / "check_no_home_paths.py"
        result = subprocess.run(
            ["python3", str(script_path)],
            capture_output=True,
            text=True,
        )

        self.assertEqual(
            result.returncode,
            0,
            f"Found home paths in tracked files:\n{result.stdout}",
        )

    def test_file_list_is_independent_of_caller_directory(self):
        """S1-T6 criterion 3: `git ls-files` runs from the repo root, so the
        inspected file list is the same from a subdirectory as from the root.
        """
        root = Path(__file__).resolve().parent.parent
        script_path = root / "scripts" / "check_no_home_paths.py"
        spec = importlib.util.spec_from_file_location("check_no_home_paths", script_path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)

        original = os.getcwd()
        try:
            os.chdir(root)
            from_root = module.get_tracked_text_files()
            os.chdir(root / "tests")
            from_subdir = module.get_tracked_text_files()
        finally:
            os.chdir(original)

        self.assertGreater(len(from_root), 10)
        self.assertEqual(from_root, from_subdir)


if __name__ == "__main__":
    unittest.main()
