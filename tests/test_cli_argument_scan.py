"""S1-T8 criterion 1 source scan: every argument-parsing decision lives in
`zig/src/cli.zig` (`parseArgs`). `main.zig` only prints what it returns and
exits, so none of the old bypasses may reappear there."""

import re
import unittest
from pathlib import Path

MAIN = Path(__file__).resolve().parents[1] / "zig" / "src" / "main.zig"

# (description, pattern) searched in main.zig with comments removed.
FORBIDDEN = [
    ("orelse return error.Missing...", r"orelse\s+return\s+error\.Missing\w*"),
    ("return error.Invalid...", r"return\s+error\.Invalid\w*"),
    ("error.InvalidArgument", r"error\.InvalidArgument"),
    ('std.debug.print("unknown ...', r'std\.debug\.print\(\s*"unknown\b'),
    ("a local number parser (parseUsize/parseByteCount/parsePositiveUsize)", r"\bparse(?:Positive)?Usize\b|\bparseByteCount\w*"),
    ("std.fmt.parseInt on an argument or address", r"parseInt\([^;]*(?:arguments\.next\(\)|address_text)"),
    ("a retrieval-mode parser outside cli.zig", r"\bparseRetrievalMode\b"),
]


def code_of(text):
    return "\n".join(line.split("//", 1)[0] for line in text.splitlines())


def violations(text):
    code = code_of(text)
    found = [what for what, pattern in FORBIDDEN if re.search(pattern, code)]
    # The only place main.zig may pull arguments is the collector loop that
    # hands them to cli.parseArgs.
    pulls = re.findall(r"\barguments\.next\(\)", code)
    if len(pulls) != 2:  # skipping argv[0], then the collector loop
        found.append(f"{len(pulls)} arguments.next() calls (expected the 2 in the collector)")
    if "cli.parseArgs" not in code:
        found.append("main.zig no longer calls cli.parseArgs")
    return found


class CliArgumentScanTest(unittest.TestCase):
    def test_main_zig_does_not_bypass_cli_parse_args(self):
        self.assertEqual(violations(MAIN.read_text()), [])

    def test_the_scan_catches_the_old_bypasses(self):
        for snippet in (
            "const f = arguments.next() orelse return error.MissingFolder;",
            "return error.InvalidArgument;",
            'std.debug.print("unknown command: {s}\\n", .{command});',
            "options.generation = try std.fmt.parseInt(u64, arguments.next() orelse x, 10);",
        ):
            self.assertTrue(violations(snippet), snippet)


if __name__ == "__main__":
    unittest.main()
