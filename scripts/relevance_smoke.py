#!/usr/bin/env python3
"""Entry point for the relevance smoke runner: `python3 scripts/relevance_smoke.py --pack family-folder`.

The implementation is relevance_smoke.py at the repository root; this wrapper
puts the root on the import path and forwards the arguments.
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from relevance_smoke import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main())
