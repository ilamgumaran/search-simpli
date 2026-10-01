#!/usr/bin/env python3
"""SHA-256 over the Zig sources the prebuilt native libraries are built from.

Used by tool/build_native.sh (writes native/SOURCE-SHA256) and by
tests/test_native_freshness.py (recomputes and compares), so the two cannot
drift. Inputs, sorted by repo-relative path: zig/build.zig, zig/build.zig.zon
(if present), every zig/src/**/*.zig, zig/include/search_simpli.h. Each file
contributes its path, a NUL, its bytes and a NUL.
"""
import hashlib
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[4]


def source_files(root=REPO_ROOT):
    zig = root / "zig"
    files = [zig / "build.zig", zig / "build.zig.zon", zig / "include" / "search_simpli.h"]
    files += (zig / "src").rglob("*.zig")
    return sorted((f for f in files if f.is_file()), key=lambda f: f.relative_to(root).as_posix())


def source_digest(root=REPO_ROOT):
    h = hashlib.sha256()
    for f in source_files(root):
        h.update(f.relative_to(root).as_posix().encode() + b"\0" + f.read_bytes() + b"\0")
    return h.hexdigest()


if __name__ == "__main__":
    print(source_digest())
    sys.exit(0)
