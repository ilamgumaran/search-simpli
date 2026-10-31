#!/usr/bin/env python3
"""Write `fixtures/markdown/`, the md-section-v1 edge-case files (S3-T1 ruling 6).

Invented content only. The files are written from this script so the byte-level
cases (CRLF, CR, BOM, no final newline, empty) are reproducible and reviewable
here rather than hidden in invisible bytes. Run from the repository root:

    python3 scripts/gen_markdown_fixture.py

then regenerate the golden: `python3 scripts/gen_chunk_golden_md.py > fixtures/chunk-golden-md.json`.
"""
from __future__ import annotations

from pathlib import Path

OUT = Path("fixtures/markdown")


def para(word: str, count: int) -> str:
    """A deterministic line of about 70 codepoints mentioning `word`."""
    return f"Line {count:03d} of the {word} notes keeps the window counting steadily onward."


FILES: dict[str, str] = {}

FILES["atx-setext.md"] = """Opening words before any heading belong to no section.

# Garden club

The garden club meets on Tuesdays.

## Beds and borders ##

Raised beds near the shed.

### Watering rota

Pip waters on Monday, Ada on Thursday.

#hashtag is not a heading because no space follows the hash.

####### Seven hashes are not a heading either.

#

Compost corner
--------------

Turn the compost every second week.

Seed swap
=========

Bring seeds in paper envelopes.

- a list item
---

## Closing  #

Last words of the club notes.
"""

small_fence = "\n".join([
    "```text",
    "# not a heading inside a fence",
    "Setext text inside a fence",
    "---",
    "```",
])
tilde_fence = "\n".join(["~~~", "## still not a heading", "~~~~"])
straddle_lead = "\n".join(para("pond", n) for n in range(1, 21))
straddle_fence = "\n".join(["```"] + [f"step {n}: count the newts again" for n in range(1, 8)] + ["```"])
overlap_lead = "\n".join(para("heron", n) for n in range(1, 20))
overlap_fence = "\n".join(["```"] + [f"tally {n}: herons seen at dawn" for n in range(1, 7)] + ["```"])
overlap_tail = "\n".join(para("heron", n) for n in range(20, 32))
long_fence = "\n".join(["```python"] + [f"value_{n:03d} = {n} * 7  # times table row {n}" for n in range(1, 60)] + ["```"])
FILES["fences.md"] = f"""# Fences

Short fence:

{small_fence}

Tilde fence:

{tilde_fence}

## Straddling fence

{straddle_lead}
{straddle_fence}
Words after the straddling fence.

## Overlap into fence

{overlap_lead}
{overlap_fence}
One line after the heron fence.
{overlap_tail}

## Long fence

{long_fence}

## Unclosed fence

```
# an unclosed fence runs to the end of the file
## so this is not a heading
"""

FILES["front-matter.md"] = """---
title: Front matter notes
owner: Ada
empty:
url: https://example.invalid/a:b
---
# Body heading

The body starts after the closing line.
"""

FILES["front-matter-invalid.md"] = """---
title: Half valid
this line has no colon
---
# Still chunks

The file still chunks when its front matter is not key: value.
"""

FILES["front-matter-unclosed.md"] = "---\ntitle: never closed\n" + "".join(
    f"filler line {n}\n" for n in range(1, 105)
) + "---\n# Late heading\n\nAfter the late heading.\n"

FILES["front-matter-only.md"] = "---\ntitle: Only metadata\n---\n"

FILES["preamble-only.md"] = "No headings here at all.\nJust two lines of text.\n"

FILES["long-section.md"] = "# Long section\n\n" + "\n".join(para("orchard", n) for n in range(1, 61)) + "\n\n## Short tail\n\nThe end.\n"

FILES["tamil.md"] = """# பள்ளி குறிப்புகள்

இன்று கணிதம் மற்றும் அறிவியல் வகுப்புகள் நடந்தன.

## வீட்டுப் பாடம்

நாளை காலை புத்தகம் கொண்டு வர வேண்டும்.
"""

FILES["empty.md"] = ""

FILES["no-final-newline.md"] = "# Last line\n\nThis file ends without a terminator."

BYTES: dict[str, bytes] = {}
crlf_text = "# Shopping\n\nApples and pears.\n\n## Bakery\n\nBread rolls.\nSetext under CRLF\n=================\nMilk.\n"
BYTES["crlf.md"] = crlf_text.replace("\n", "\r\n").encode("utf-8")
BYTES["cr-only.md"] = crlf_text.replace("\n", "\r").encode("utf-8")
BYTES["bom.md"] = b"\xef\xbb\xbf" + "# Checklist with a BOM\n\n- passports\n- tickets\n\n## Later\n\nPack the night before.\n".encode("utf-8")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for name, text in FILES.items():
        (OUT / name).write_bytes(text.encode("utf-8"))
    for name, data in BYTES.items():
        (OUT / name).write_bytes(data)


if __name__ == "__main__":
    main()
