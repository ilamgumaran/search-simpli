#!/usr/bin/env python3
"""Copy a text file with the scratch folder and the home directory replaced by
placeholders, so no home path enters the repository. Usage: v_sanitize.py IN OUT"""
import os
import sys

src, dst = sys.argv[1:3]
home = os.path.expanduser("~")
scratch = os.path.join(home, "workspace/repos/search-simpli-wt/S6-T14-vscratch.noindex")
text = open(src, encoding="utf-8", errors="replace").read()
text = text.replace(scratch, "<vscratch>").replace(home, "~")
open(dst, "w", encoding="utf-8").write(text)
