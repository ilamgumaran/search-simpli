"""S6-T7 verifier: compare two abi_dump outputs answer by answer (the request's cursor generation ignored)."""
import json, re, sys
a, b = open(sys.argv[1]).readlines(), open(sys.argv[2]).readlines()
assert len(a) == len(b), (len(a), len(b))
n = 0
for x, y in zip(a, b):
    X, Y = json.loads(x), json.loads(y)
    rx = re.sub(r'"cursor": "\d+:', '"cursor": "G:', json.dumps(X[1]))
    ry = re.sub(r'"cursor": "\d+:', '"cursor": "G:', json.dumps(Y[1]))
    if X[0] != Y[0] or rx != ry or X[2] != Y[2]:
        n += 1
        if n <= 3:
            print("DIFF", X[0], X[1])
print(sys.argv[1].split("/")[-1], "vs", sys.argv[2].split("/")[-1], "calls", len(a), "differ", n)
