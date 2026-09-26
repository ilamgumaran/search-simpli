"""Test privacy rules for the repository.

S1-T5 criterion 3: tracked text files must not contain absolute home paths.
"""

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


if __name__ == "__main__":
    unittest.main()
