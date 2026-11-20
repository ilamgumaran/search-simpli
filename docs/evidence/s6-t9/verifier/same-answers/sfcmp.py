"""S6-T7 verifier: compare two surf.py outputs after normalising generation numbers and cursors
in every textual form (plain text, JSON, JSON escaped inside MCP text)."""
import json, re, sys
PATS = [(re.compile(r'generation[ =]\d+'), 'generation G'), (re.compile(r'(\\*"generation\\*"\s*:\s*)\d+'), r'\1G'),
        (re.compile(r'(\\*"(?:next_)?cursor\\*"\s*:\s*\\*")\d+:'), r'\1G:'), (re.compile(r'--cursor \d+:'), '--cursor G:'), (re.compile(r'("nextCursor"\s*:\s*")\d+:'), r'\1G:'),
        (re.compile(r'next page: \d+:'), 'next page: G:'), (re.compile(r'cursor \d+:'), 'cursor G:')]
def n(s):
    for p, r in PATS:
        s = p.sub(r, s)
    return s
a, b = open(sys.argv[1]).readlines(), open(sys.argv[2]).readlines()
d = 0
for x, y in zip(a, b):
    X, Y = json.loads(x), json.loads(y)
    if X[0] != Y[0] or X[1] != Y[1] or n(X[2]) != n(Y[2]):
        d += 1
        if d <= 2:
            print("DIFF", X[0], X[1], n(X[2])[:300], "||", n(Y[2])[:300])
print(sys.argv[1].split("/")[-1], "vs", sys.argv[2].split("/")[-1], "rows", len(a), len(b), "differ", d + abs(len(a) - len(b)))
