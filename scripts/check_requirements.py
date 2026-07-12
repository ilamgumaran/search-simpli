#!/usr/bin/env python3
"""Validate the requirements register so the consolidated view cannot drift.

Dependency-free (stdlib only), per NFR-01. Run from the repo root:

    python3 scripts/check_requirements.py

Checks:
  1. IDs are unique within their defining table (CAP/FR/NFR/CFT).
  2. Capability/FR/NFR status tokens are in the allowed vocabulary.
  3. Every CAP referenced by an FR/NFR row exists in the capability catalog.
  4. Every capability-catalog row that links a cap-*.md spec resolves to a file.
  5. Conflict rows have a status, and an INV conflict is never merely "Accepted".

Exits non-zero with a list of violations if the register is inconsistent.
"""
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
REGISTER = REPO / "docs" / "requirements" / "README.md"

# A status cell may combine a lifecycle status with an evidence tag, e.g.
# "Operational · implemented". Only the first token is checked.
ALLOWED_STATUS = {
    "proposed", "diagnostic", "validated", "operational",
    "blocked", "standing", "withdrawn", "implemented",
}
ALLOWED_CFT_STATUS = {"resolved", "blocked", "accepted", "invariant-change"}


def cells(line):
    # "| a | b | c |" -> ["a", "b", "c"]
    inner = line.strip().strip("|")
    return [c.strip() for c in inner.split("|")]


def first_token(text):
    return re.split(r"[\s·/(]", text.strip(), maxsplit=1)[0].lower()


def main():
    errors = []
    if not REGISTER.exists():
        print(f"register not found: {REGISTER}", file=sys.stderr)
        return 1

    section = ""
    seen = {"CAP": {}, "FR": {}, "NFR": {}, "CFT": {}}
    cap_ids = set()
    fr_nfr_cap_refs = []  # (row_id, capref, lineno)

    for lineno, raw in enumerate(REGISTER.read_text().splitlines(), 1):
        h = re.match(r"#{2,3}\s+(.*)", raw)
        if h:
            section = h.group(1)
            continue
        if not raw.lstrip().startswith("|"):
            continue
        row = cells(raw)
        if not row:
            continue
        rid = row[0]

        # Capability catalog defining table
        if section.startswith("Capability catalog") and re.match(r"CAP-\d+$", rid):
            if rid in seen["CAP"]:
                errors.append(f"L{lineno}: duplicate {rid} in capability catalog")
            seen["CAP"][rid] = lineno
            cap_ids.add(rid)
            status = row[-1]
            if first_token(status) not in ALLOWED_STATUS:
                errors.append(f"L{lineno}: {rid} status '{status}' not in allowed vocabulary")
            # spec link existence
            for target in re.findall(r"\(([^)]+\.md)\)", row[1]):
                if not (REGISTER.parent / target).exists():
                    errors.append(f"L{lineno}: {rid} links missing spec '{target}'")

        elif section.startswith("Functional requirements") and re.match(r"FR-\d+$", rid):
            if rid in seen["FR"]:
                errors.append(f"L{lineno}: duplicate {rid} in FR index")
            seen["FR"][rid] = lineno
            if first_token(row[-1]) not in ALLOWED_STATUS:
                errors.append(f"L{lineno}: {rid} status '{row[-1]}' not in allowed vocabulary")
            for m in re.findall(r"CAP-\d+", row[2]):
                fr_nfr_cap_refs.append((rid, m, lineno))

        elif section.startswith("Non-functional requirements") and re.match(r"NFR-\d+$", rid):
            if rid in seen["NFR"]:
                errors.append(f"L{lineno}: duplicate {rid} in NFR index")
            seen["NFR"][rid] = lineno
            if first_token(row[-1]) not in ALLOWED_STATUS:
                errors.append(f"L{lineno}: {rid} status '{row[-1]}' not in allowed vocabulary")
            for m in re.findall(r"CAP-\d+", row[2]):
                fr_nfr_cap_refs.append((rid, m, lineno))

        elif section.startswith("Conflict register") and re.match(r"CFT-\d+$", rid):
            if rid in seen["CFT"]:
                errors.append(f"L{lineno}: duplicate {rid} in conflict register")
            seen["CFT"][rid] = lineno
            status, between = row[-1], row[1]
            tok = first_token(status)
            if not status or tok not in ALLOWED_CFT_STATUS:
                errors.append(f"L{lineno}: {rid} conflict status '{status}' invalid (need {sorted(ALLOWED_CFT_STATUS)})")
            if "INV-" in between and tok == "accepted":
                errors.append(
                    f"L{lineno}: {rid} touches an invariant but is 'Accepted' — INV conflicts must be Resolved/Blocked/Invariant-change"
                )

    for rid, capref, lineno in fr_nfr_cap_refs:
        if capref not in cap_ids:
            errors.append(f"L{lineno}: {rid} references {capref}, absent from the capability catalog")

    if errors:
        print("Requirements register validation FAILED:")
        for e in errors:
            print(f"  - {e}")
        return 1
    print(f"Requirements register OK: {len(seen['CAP'])} capabilities, "
          f"{len(seen['FR'])} FR, {len(seen['NFR'])} NFR, {len(seen['CFT'])} conflicts.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
