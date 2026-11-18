"""S6-T7 verifier: compare a trial's answers with the new reference, the generation number normalised."""
import json, re, subprocess, sys
def run(i):
    return json.loads(subprocess.run([sys.executable, "-I", "kill/probe_raw.py", sys.argv[1], i], capture_output=True, text=True).stdout)
def norm(s):
    s = s if isinstance(s, str) else json.dumps(s)
    return re.sub(r'"(next_cursor|cursor)":"\d+:', 'CUR', re.sub(r'"generation":\d+', '"generation":G', s))
a, b = run(sys.argv[2]), run(sys.argv[3])
bad = [k for k in a if norm(a[k]) != norm(b[k])]
print(sys.argv[2], "same as the new generation apart from its number" if not bad else f"DIFFERS in {bad}")
