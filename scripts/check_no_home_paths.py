#!/usr/bin/env python3
"""Check that no home paths are present in tracked text files.

S1-T5 criterion 3: tracked text files must not contain absolute home paths
like /Users/<name>/ or /home/<name>/ (use <home>/... instead).
"""

import re
import subprocess
import sys
from pathlib import Path


def get_tracked_text_files():
    """Return the list of tracked text files from git."""
    try:
        # Get all tracked files
        result = subprocess.run(
            ["git", "ls-files"],
            check=True,
            capture_output=True,
            text=True,
        )
        tracked = result.stdout.strip().split("\n")

        # Filter to text files (exclude binary extensions)
        binary_exts = {
            ".so", ".dylib", ".a", ".o", ".pyc",
            ".png", ".jpg", ".gif", ".jpeg",
            ".exe", ".bin", ".pdf", ".zip",
        }
        text_files = []
        for path in tracked:
            if not path:
                continue
            if any(path.endswith(ext) for ext in binary_exts):
                continue
            text_files.append(path)

        return text_files
    except subprocess.CalledProcessError:
        return []


def check_file_for_home_paths(file_path):
    """Check a file for home paths.

    Returns list of (line_number, line_text) tuples with violations.
    """
    violations = []
    home_path_pattern = re.compile(r'(?:^|[^<])/(?:Users|home)/[a-zA-Z0-9_\-\.]+/')

    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            for line_num, line in enumerate(f, 1):
                if home_path_pattern.search(line):
                    violations.append((line_num, line.rstrip()))
    except Exception:
        # Skip files that can't be read as text
        pass

    return violations


def main():
    """Check all tracked text files for home paths."""
    files = get_tracked_text_files()
    found_violations = False

    for file_path in files:
        violations = check_file_for_home_paths(file_path)
        if violations:
            found_violations = True
            print(f"{file_path}:")
            for line_num, line_text in violations:
                print(f"  {line_num}: {line_text}")

    if found_violations:
        print("\nERROR: Found home paths in tracked files.", file=sys.stderr)
        print("Replace /Users/<name>/ or /home/<name>/ with <home>/...", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
