#!/usr/bin/env python3
"""Remove the contract-1.2.0 additions from a `capture_query_outputs.py` file.

S2-T4 bar (a): with `warnings`, `request` and `profile` removed, the new
library's output must be byte-identical to the previous library's. The three
keys are appended after `answer_policy` (which used to be last), so stripping
is a byte-level cut, not a JSON re-serialisation: the bytes in front of the cut
are exactly what the library wrote. The script also checks, on every output,
that the new keys are present in the order warnings, request[, profile] and
that nothing else follows them.

    python3 -I scripts/strip_report_keys.py NEW.jsonl STRIPPED.jsonl
    cmp OLD.jsonl STRIPPED.jsonl

Error outputs ("ERROR ...") are passed through unchanged.
"""

from __future__ import annotations

import json
import sys

ANSWER_POLICY_END = '"say_when_evidence_is_insufficient":true}'
TAIL_KEYS = ["warnings", "request", "profile"]


def strip(output: str) -> tuple[str, list[str]]:
    """Return the output without the new keys and the new keys' names in order."""
    marker = output.index(ANSWER_POLICY_END) + len(ANSWER_POLICY_END)
    if not output.startswith(',"warnings":', marker):
        raise ValueError("no warnings key after answer_policy")
    tail = json.loads("{" + output[marker + 1 :])
    names = list(tail)
    if names not in (["warnings", "request"], ["warnings", "request", "profile"]):
        raise ValueError(f"unexpected tail keys {names}")
    return output[:marker] + "}", names


def main() -> int:
    source, target = sys.argv[1], sys.argv[2]
    stripped = errors = 0
    with open(source, encoding="utf-8") as reader, open(target, "w", encoding="utf-8") as writer:
        for line in reader:
            record = json.loads(line)
            if record["output"].startswith("ERROR"):
                errors += 1
            else:
                record["output"], _ = strip(record["output"])
                stripped += 1
            writer.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
    print(f"stripped {stripped} outputs, {errors} error outputs passed through")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
