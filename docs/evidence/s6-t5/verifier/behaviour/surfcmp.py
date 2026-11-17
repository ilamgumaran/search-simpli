"""S6-T5 verifier: compare surf.py outputs of main and head."""
import json, collections, sys
sys.path.insert(0, __import__("os").path.dirname(__file__))
import ssdrv
m = [json.loads(l) for l in open(sys.argv[1])]; h = [json.loads(l) for l in open(sys.argv[2])]
assert [(x['surface'], x['case']) for x in m] == [(x['surface'], x['case']) for x in h]
c = collections.Counter(); nokey = collections.Counter()
for a, b in zip(m, h):
    s = a['surface']; field = a['case'].split('\t')[1] if '\t' in a['case'] else '-'
    if a['out'] == b['out']:
        c[(s, field, 'identical')] += 1
    elif s == 'ss_query' and field in ('both', 'filename') and ssdrv.outside_warnings(a['out'].encode()) == ssdrv.outside_warnings(b['out'].encode()) and ssdrv.warnings_bytes(a['out'].encode()) == b'[]':
        c[(s, field, 'differs only inside warnings (main [])')] += 1
    elif s == 'mcp-initialize' and a['out'].replace('"version":"2.7.0"', '"version":"2.8.0"') == b['out']:
        c[(s, field, 'differs only in serverInfo.version 2.7.0 -> 2.8.0')] += 1
    else:
        c[(s, field, 'DIFFERS')] += 1
    if s != 'ss_query':
        nokey[(s, '"warnings"' in b['out'])] += 1
for k in sorted(c): print(*k, c[k], sep='\t')
print('head outputs carrying a "warnings" key, per non-ss_query surface:', dict((f"{k[0]}:{k[1]}", v) for k, v in nokey.items()))
