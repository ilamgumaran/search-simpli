#!/usr/bin/env python3
"""S5-T12 Phase 2: the scoped workload's changes file.

    python3 -I two_roots.py CORPUS_DIR OUT_JSON

The 10k timing corpus as two host roots: `group-00`..`group-49` in
`r-left`, `group-50`..`group-99` in `r-right` (paths relative to the
group's parent, as `gen_timing_corpus.py` wrote them). No labels. Applied
with `searchd apply <new dir> --changes OUT_JSON --filename-index`.
"""

from __future__ import annotations

import base64
import json
import sys
from pathlib import Path


def main(argv: list[str]) -> int:
    corpus, out = Path(argv[1]), Path(argv[2])
    changes = []
    for path in sorted(corpus.rglob("*.md")):
        relative = path.relative_to(corpus).as_posix()
        group = int(relative.split("/")[0].split("-")[1])
        root = "r-left" if group < 50 else "r-right"
        changes.append({"op": "add", "root_id": root, "path": relative,
                        "content_base64": base64.b64encode(path.read_bytes()).decode("ascii")})
    request = {"roots": [{"root_id": "r-left", "label": "Left", "kind": "host"},
                         {"root_id": "r-right", "label": "Right", "kind": "host"}],
               "changes": changes}
    out.write_text(json.dumps(request), encoding="utf-8")
    print(f"{len(changes)} files: {sum(1 for c in changes if c['root_id'] == 'r-left')} r-left, "
          f"{sum(1 for c in changes if c['root_id'] == 'r-right')} r-right")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
