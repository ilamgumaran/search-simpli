"""vcompare.py MAINDIR HEADDIR : compare raw test-runner output by declared test name."""
import re
import sys
from collections import Counter

LINE = re.compile(r'^(\d+)/(\d+) (.+?)\.(test\.|test_)(.*)$')


def read(d):
    tests = Counter()
    full = {}
    other = Counter()
    count = 0
    for step in ('core', 'operations', 'interfaces', 'tests', 'test'):
        for raw in open(f'{d}/raw-{step}.txt', errors='replace').read().split('\n'):
            m = LINE.match(raw)
            if not m:
                if raw.strip():
                    other[(step, re.sub(r'\d+(\.\d+)? ?ms', 'N ms', raw))] += 1
                continue
            count += 1
            prefix, kind, rest = m.group(3), m.group(4), m.group(5)
            if kind == 'test_':
                name, status = 'test_' + rest.split('...')[0], rest.split('...', 1)[1] if '...' in rest else ''
            else:
                if '...' in rest:
                    name, status = rest.rsplit('...', 1) if rest.endswith(('OK', 'SKIP', 'FAIL')) else rest.split('...', 1)
                else:
                    name, status = rest, ''
            status = re.sub(r'\d+(\.\d+)? ?ms', 'N ms', status)
            status = re.sub(r'growth [0-9.]+x', 'growth Nx', status)
            tests[(name, status)] += 1
            full.setdefault(name, []).append((step, prefix))
    return tests, full, other, count


a, fa, oa, ca = read(sys.argv[1])
b, fb, ob, cb = read(sys.argv[2])
print(f'numbered test lines: main {ca}, head {cb}')
print(f'(name,status) pairs: main {sum(a.values())}, head {sum(b.values())}; distinct names main {len(fa)}, head {len(fb)}')
print('only main:', sorted((a - b).items()))
print('only head:', sorted((b - a).items()))
moved = [(n, fa[n], fb.get(n)) for n in fa if sorted(fa[n]) != sorted(fb.get(n, []))]
print('step/prefix changed:', moved)
print('names on one side only:', sorted(set(fa) ^ set(fb)))
print('status counts main:', Counter(s if s in ('OK', 'SKIP', 'FAIL') else 'other' for (_, s) in a.elements()))
print('status counts head:', Counter(s if s in ('OK', 'SKIP', 'FAIL') else 'other' for (_, s) in b.elements()))
print('other lines only main:', sorted((oa - ob).items()))
print('other lines only head:', sorted((ob - oa).items()))
