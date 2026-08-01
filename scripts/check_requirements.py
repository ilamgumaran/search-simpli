#!/usr/bin/env python3
"""Validate the requirements register against every declared source of truth.

Dependency-free (stdlib only), per NFR-01. Run from the repo root:

    python3 scripts/check_requirements.py

It checks, across the register, the executable specification, the use-case
catalog, the contracts directory, and each capability spec:

  1.  IDs are unique within their defining table (CAP/FR/NFR/CFT).
  2.  Capability/FR/NFR status tokens are in the allowed vocabulary.
  3.  Every CAP referenced by an FR/NFR row exists in the capability catalog.
  4.  Every capability-catalog spec link resolves to a file.
  5.  Conflict rows have a valid status, and an INV conflict is never "Accepted".
  6.  Every UC referenced (register + capability specs) is defined in the
      use-case catalog, and every catalogued UC has a file.
  7.  Every CON referenced is defined in the register's CON table, and every
      defined CON schema file exists.
  8.  One-to-one FR/NFR coverage between the register and specification.md
      (proposed appendix counts) — no requirement lives in only one place.
  9.  Each capability spec that the catalog links exists, carries a Dependencies
      section and a maintainer-approval block, references only defined UCs, and
      only mentions register-defined FRs.

Exits non-zero with a list of violations if anything is inconsistent. The core
logic is `validate(root)`, exercised by tests/test_requirements_validator.py.
"""
import re
import sys
from pathlib import Path

ALLOWED_STATUS = {
    "proposed", "diagnostic", "validated", "operational",
    "blocked", "standing", "withdrawn", "implemented",
}
ALLOWED_CFT_STATUS = {"resolved", "blocked", "accepted", "invariant-change"}


def _cells(line):
    return [c.strip() for c in line.strip().strip("|").split("|")]


def _first_token(text):
    return re.split(r"[\s·/(]", text.strip(), maxsplit=1)[0].lower()


def _ids(text, prefix):
    # Negative lookbehind so FR does not match inside NFR, etc.
    return set(re.findall(rf"(?<![A-Za-z]){prefix}-\d+", text))


def validate(root):
    """Return a list of violation strings (empty when the register is consistent)."""
    root = Path(root)
    register = root / "docs" / "requirements" / "README.md"
    spec = root / "docs" / "recreation" / "specification.md"
    uc_catalog = root / "docs" / "use-cases" / "README.md"
    errors = []

    if not register.exists():
        return [f"register not found: {register}"]

    reg_text = register.read_text()
    section = ""
    seen = {"CAP": {}, "FR": {}, "NFR": {}, "CFT": {}}
    cap_ids = set()
    reg_fr = set()
    reg_nfr = set()
    con_defined = {}       # CON id -> schema path
    fr_nfr_cap_refs = []   # (row_id, capref, lineno)
    uc_refs = []           # (where, uc_id, lineno)
    con_refs = []          # (where, con_id, lineno)
    cap_spec_links = {}    # CAP id -> spec filename
    catalog_frs = {}       # CAP id -> {FR ids} from the catalog Key-requirements cell
    catalog_nfrs = {}      # CAP id -> {NFR ids} from the catalog Key-requirements cell
    fr_to_cap = {}         # FR id -> primary CAP from the FR index
    nfr_applies = {}       # NFR id -> {CAP ids} from the NFR index

    for lineno, raw in enumerate(reg_text.splitlines(), 1):
        h = re.match(r"#{2,3}\s+(.*)", raw)
        if h:
            section = h.group(1)
            continue
        if not raw.lstrip().startswith("|"):
            continue
        row = _cells(raw)
        rid = row[0]

        if section.startswith("Capability catalog") and re.match(r"CAP-\d+$", rid):
            if rid in seen["CAP"]:
                errors.append(f"register L{lineno}: duplicate {rid} in capability catalog")
            seen["CAP"][rid] = lineno
            cap_ids.add(rid)
            if _first_token(row[-1]) not in ALLOWED_STATUS:
                errors.append(f"register L{lineno}: {rid} status '{row[-1]}' not in allowed vocabulary")
            for target in re.findall(r"\(([^)]+\.md)\)", row[1]):
                cap_spec_links[rid] = target
                if not (register.parent / target).exists():
                    errors.append(f"register L{lineno}: {rid} links missing spec '{target}'")
            for uc in _ids(row[2], "UC"):
                uc_refs.append(("register", uc, lineno))
            key_reqs = row[3] if len(row) > 3 else ""
            catalog_frs[rid] = _ids(key_reqs, "FR")
            catalog_nfrs[rid] = _ids(key_reqs, "NFR")

        elif section.startswith("Functional requirements") and re.match(r"FR-\d+$", rid):
            if rid in seen["FR"]:
                errors.append(f"register L{lineno}: duplicate {rid} in FR index")
            seen["FR"][rid] = lineno
            reg_fr.add(rid)
            if _first_token(row[-1]) not in ALLOWED_STATUS:
                errors.append(f"register L{lineno}: {rid} status '{row[-1]}' not in allowed vocabulary")
            caps = re.findall(r"CAP-\d+", row[2])
            if caps:
                fr_to_cap[rid] = caps[0]
            for m in set(caps):
                fr_nfr_cap_refs.append((rid, m, lineno))

        elif section.startswith("Non-functional requirements") and re.match(r"NFR-\d+$", rid):
            if rid in seen["NFR"]:
                errors.append(f"register L{lineno}: duplicate {rid} in NFR index")
            seen["NFR"][rid] = lineno
            reg_nfr.add(rid)
            if _first_token(row[-1]) not in ALLOWED_STATUS:
                errors.append(f"register L{lineno}: {rid} status '{row[-1]}' not in allowed vocabulary")
            nfr_applies[rid] = set(re.findall(r"CAP-\d+", row[2]))
            for m in nfr_applies[rid]:
                fr_nfr_cap_refs.append((rid, m, lineno))

        elif section.startswith("Contracts") and re.match(r"CON-\d+$", rid):
            con_defined[rid] = row[1]
            for target in re.findall(r"`([^`]+\.json)`", row[1]):
                if not (root / target).exists():
                    errors.append(f"register L{lineno}: {rid} schema '{target}' does not exist")

        elif section.startswith("Conflict register") and re.match(r"CFT-\d+$", rid):
            if rid in seen["CFT"]:
                errors.append(f"register L{lineno}: duplicate {rid} in conflict register")
            seen["CFT"][rid] = lineno
            status, between = row[-1], row[1]
            tok = _first_token(status)
            if not status or tok not in ALLOWED_CFT_STATUS:
                errors.append(f"register L{lineno}: {rid} conflict status '{status}' invalid")
            if "INV-" in between and tok == "accepted":
                errors.append(f"register L{lineno}: {rid} touches an invariant but is 'Accepted' "
                              "(INV conflicts must be Resolved/Blocked/Invariant-change)")

    # CON references anywhere in the register
    for lineno, raw in enumerate(reg_text.splitlines(), 1):
        for con in _ids(raw, "CON"):
            con_refs.append(("register", con, lineno))

    # 3. CAP references resolve
    for rid, capref, lineno in fr_nfr_cap_refs:
        if capref not in cap_ids:
            errors.append(f"register L{lineno}: {rid} references {capref}, absent from the capability catalog")

    # 3b. Catalog <-> FR-index agreement (bidirectional, FR); NFR one-direction
    for fr, cap in fr_to_cap.items():
        if fr not in catalog_frs.get(cap, set()):
            errors.append(f"agreement: {fr} maps to {cap} in the FR index but is absent from "
                          f"{cap}'s catalog Key requirements")
    for cap, frs in catalog_frs.items():
        for fr in frs:
            mapped = fr_to_cap.get(fr)
            if mapped != cap:
                errors.append(f"agreement: {cap} lists {fr} in its catalog Key requirements but the "
                              f"FR index maps {fr} to {mapped or 'no capability'}")
    for cap, nfrs in catalog_nfrs.items():
        for nfr in nfrs:
            if cap not in nfr_applies.get(nfr, set()):
                errors.append(f"agreement: {cap} lists {nfr} in its catalog Key requirements but the "
                              f"NFR index does not apply {nfr} to {cap}")

    # 6. UC references resolve, and catalogued UCs have files
    uc_defined = {}
    if uc_catalog.exists():
        for lineno, raw in enumerate(uc_catalog.read_text().splitlines(), 1):
            if raw.lstrip().startswith("|"):
                row = _cells(raw)
                if re.match(r"UC-\d+$", row[0]):
                    uc_defined[row[0]] = lineno
                    for target in re.findall(r"\(([^)]+\.md)\)", row[1] if len(row) > 1 else ""):
                        if not (uc_catalog.parent / target).exists():
                            errors.append(f"use-cases L{lineno}: {row[0]} links missing file '{target}'")
    else:
        errors.append("use-case catalog not found")
    for where, uc, lineno in uc_refs:
        if uc not in uc_defined:
            errors.append(f"{where} L{lineno}: references {uc}, absent from the use-case catalog")

    # 7. CON references resolve
    for where, con, lineno in con_refs:
        if con not in con_defined:
            errors.append(f"{where} L{lineno}: references {con}, absent from the register CON table")

    # 8. One-to-one FR/NFR coverage with the specification
    if spec.exists():
        spec_text = spec.read_text()
        spec_fr, spec_nfr = _ids(spec_text, "FR"), _ids(spec_text, "NFR")
        for fid in sorted(reg_fr - spec_fr):
            errors.append(f"coverage: {fid} is in the register but absent from specification.md")
        for fid in sorted(spec_fr - reg_fr):
            errors.append(f"coverage: {fid} appears in specification.md but is not a register FR")
        for nid in sorted(reg_nfr - spec_nfr):
            errors.append(f"coverage: {nid} is in the register but absent from specification.md")
        for nid in sorted(spec_nfr - reg_nfr):
            errors.append(f"coverage: {nid} appears in specification.md but is not a register NFR")
    else:
        errors.append("specification.md not found")

    # 9. Capability records: dependencies + approval + valid UC/FR/CON references.
    #
    # Checked for EVERY docs/requirements/cap-*.md, not only catalog-linked ones,
    # so a sub-record (e.g. a follow-on tranche of an existing capability) cannot
    # escape validation by not being linked from the catalog. The capability id is
    # taken from the filename prefix (`cap-11-...` -> CAP-11).
    linked_targets = set(cap_spec_links.values())
    records = sorted(register.parent.glob("cap-*.md"))
    for specfile in records:
        m = re.match(r"cap-(\d+)-", specfile.name)
        if not m:
            errors.append(f"{specfile.name}: capability record filename must start with 'cap-<NN>-'")
            continue
        cap = f"CAP-{m.group(1)}"
        target = specfile.name
        if cap not in cap_ids:
            errors.append(f"{target}: names {cap}, which is absent from the capability catalog")
        text = specfile.read_text()
        if not re.search(r"(?im)^#+.*dependencies", text):
            errors.append(f"{target}: {cap} spec is missing a Dependencies section (step 6)")
        if not re.search(r"(?im)^#+.*maintainer approval", text):
            errors.append(f"{target}: {cap} spec is missing a maintainer-approval block (step 6b)")
        for uc in _ids(text, "UC"):
            if uc not in uc_defined:
                errors.append(f"{target}: {cap} references {uc}, absent from the use-case catalog")
        for fr in _ids(text, "FR"):
            if fr not in reg_fr:
                errors.append(f"{target}: {cap} mentions {fr}, which is not a register-defined FR")
        for con in _ids(text, "CON"):
            if con not in con_defined:
                errors.append(f"{target}: {cap} references {con}, absent from the register CON table")

        # The canonical (catalog-linked) spec's declared FRs must match the catalog
        # Key requirements. Sub-records are exempt from this equality check: they
        # legitimately restate a subset of an existing capability's requirements.
        if target in linked_targets:
            spec_frs = set()
            in_fr_table = False
            for line in text.splitlines():
                if re.match(r"#+\s", line):
                    in_fr_table = bool(re.match(r"(?i)#+\s*3\b.*functional requirements", line))
                    continue
                if in_fr_table and line.lstrip().startswith("|"):
                    fm = re.match(r"FR-\d+", _cells(line)[0])
                    if fm:
                        spec_frs.add(fm.group(0))
            if spec_frs and spec_frs != catalog_frs.get(cap, set()):
                errors.append(f"{target}: {cap} spec's functional-requirements table declares "
                              f"{sorted(spec_frs)} but the catalog Key requirements list "
                              f"{sorted(catalog_frs.get(cap, set()))}")

    return errors


def main():
    root = Path(__file__).resolve().parents[1]
    errors = validate(root)
    if errors:
        print("Requirements register validation FAILED:")
        for e in errors:
            print(f"  - {e}")
        return 1
    print("Requirements register OK: consistent across register, "
          "specification, use-cases, contracts, and capability specs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
