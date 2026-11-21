"""Independent verifier measurement for S6-T19 (not the builder's measure.py).

Usage: python3 -I vmeasure.py <zig/src dir>
Tokenizes Zig (comments and strings stripped), lists core.api names, resolves
aliases in ops/ and interfaces/, and classifies every use as test or code.
"""
import os
import re
import sys
from collections import defaultdict

TOK = re.compile(r'''
  (?P<ws>\s+)
 |(?P<comment>//[^\n]*)
 |(?P<mstr>\\\\[^\n]*)
 |(?P<str>"(?:\\.|[^"\\\n])*")
 |(?P<chr>'(?:\\.|[^'\\\n])+')
 |(?P<qid>@"(?:\\.|[^"\\\n])*")
 |(?P<builtin>@[A-Za-z_][A-Za-z0-9_]*)
 |(?P<id>[A-Za-z_][A-Za-z0-9_]*)
 |(?P<num>[0-9][0-9A-Za-z_.]*)
 |(?P<p>\.\.\.|\.\.|\.\*|\.\?|\.\{|[{}()\[\];:,.=]|[^\sA-Za-z0-9_"'])
''', re.X)


def tokens(text):
    out = []
    pos = 0
    line = 1
    while pos < len(text):
        m = TOK.match(text, pos)
        if not m:
            raise SystemExit(f"tokenize fail at {pos}: {text[pos:pos+20]!r}")
        kind = m.lastgroup
        val = m.group()
        if kind not in ('ws', 'comment', 'mstr'):
            out.append((kind, val, line))
        line += val.count('\n')
        pos = m.end()
    return out


def test_mask(toks):
    """For each token, True if inside a test block (keyword `test`)."""
    mask = [False] * len(toks)
    i = 0
    depth = 0
    test_depth = None
    for i, (k, v, _) in enumerate(toks):
        if k == 'id' and v == 'test' and test_depth is None:
            # test decl: `test "name" {` / `test name {` / `test {`
            j = i + 1
            if j < len(toks) and toks[j][0] in ('str', 'id'):
                j += 1
            if j < len(toks) and toks[j][1] == '{':
                test_depth = depth
        if test_depth is not None:
            mask[i] = True
        if v in ('{', '.{'):
            depth += 1
        elif v == '}':
            depth -= 1
            if test_depth is not None and depth == test_depth:
                test_depth = None
    return mask


def api_names(core_text):
    toks = tokens(core_text)
    # find `pub const api = struct {`
    for i in range(len(toks)):
        if [t[1] for t in toks[i:i + 5]] == ['pub', 'const', 'api', '=', 'struct']:
            start = i + 5
            break
    assert toks[start][1] == '{'
    depth = 0
    names = []
    ns = None
    other_top = []
    i = start
    while True:
        v = toks[i][1]
        if v in ('{', '.{'):
            depth += 1
        elif v == '}':
            depth -= 1
            if depth == 0:
                break
            if depth == 1:
                ns = None
        elif v == 'pub' and toks[i + 1][1] == 'const':
            name = toks[i + 2][1]
            if depth == 1:
                if toks[i + 4][1] == 'struct':
                    ns = name
                else:
                    other_top.append(name)
            elif depth == 2:
                names.append((ns, name))
        i += 1
    return names, other_top


def chain_at(toks, i):
    """Parse a dotted chain starting at token i. Return (path list, end index) or None.
    Path starts with either ('core',) for @import("core") or ('id', name)."""
    k, v, _ = toks[i]
    if k == 'builtin' and v == '@import':
        if toks[i + 1][1] == '(' and toks[i + 2][0] == 'str' and toks[i + 3][1] == ')':
            path = ['@import(' + toks[i + 2][1] + ')']
            j = i + 4
        else:
            return None
    elif k == 'id':
        path = [v]
        j = i + 1
    else:
        return None
    while j + 1 < len(toks) and toks[j][1] == '.' and toks[j + 1][0] == 'id':
        path.append(toks[j + 1][1])
        j += 2
    return path, j


def analyse(src, names):
    nameset = set(names)
    nsset = {n for n, _ in names}
    files = []
    for sub in ('ops', 'interfaces'):
        d = os.path.join(src, sub)
        for f in sorted(os.listdir(d)):
            if f.endswith('.zig'):
                files.append(os.path.join(sub, f))
    uses = defaultdict(list)  # (ns,name) -> [(file,line,kind)]
    bare_ns = []
    report = []
    for rel in files:
        text = open(os.path.join(src, rel)).read()
        toks = tokens(text)
        mask = test_mask(toks)
        testfile = rel.endswith('_test.zig')
        # alias bindings: const X [: T] = chain ;
        alias = {}  # ident -> resolved api path tuple
        alias_sites = {}
        changed = True
        binds = []
        for i in range(len(toks) - 3):
            if toks[i][1] == 'const' and toks[i + 1][0] == 'id':
                j = i + 2
                if toks[j][1] == ':':
                    continue
                if toks[j][1] != '=':
                    continue
                c = chain_at(toks, j + 1)
                if c and c[1] < len(toks) and toks[c[1]][1] == ';':
                    binds.append((toks[i + 1][1], c[0], j + 1, i))

        def resolve(path):
            head = path[0]
            if head == '@import("core")':
                if len(path) >= 2 and path[1] == 'api':
                    return ('api',) + tuple(path[2:])
                return ('core-internal',) + tuple(path[1:])
            if head in alias:
                return alias[head] + tuple(path[1:])
            return None

        while changed:
            changed = False
            for ident, path, ci, ti in binds:
                r = resolve(path)
                if r is not None and alias.get(ident) != r:
                    if ident in alias and alias[ident] != r:
                        report.append(f"CONFLICT {rel} {ident}: {alias[ident]} vs {r}")
                    alias[ident] = r
                    alias_sites[ident] = ti
                    changed = True
        bind_token_idx = {ti + 1 for _, _, _, ti in binds}  # the ident token being bound
        # walk every chain start
        i = 0
        while i < len(toks):
            k, v, line = toks[i]
            prev = toks[i - 1][1] if i else ''
            if prev == '.' :  # member, not a chain head
                i += 1
                continue
            if i in bind_token_idx:
                i += 1
                continue
            c = chain_at(toks, i)
            if not c:
                i += 1
                continue
            path, end = c
            r = resolve(path)
            if r and r[0] == 'api':
                where = 'test' if (mask[i] or testfile) else 'code'
                # is this chain the RHS of an alias binding?
                is_bind = (i >= 2 and toks[i - 1][1] == '=' and toks[i - 3][1] == 'const' and end < len(toks) and toks[end][1] == ';')
                if len(r) >= 3:
                    key = (r[1], r[2])
                    if key not in nameset:
                        report.append(f"UNKNOWN {rel}:{line} {'.'.join(r)}")
                    elif not is_bind:
                        uses[key].append((rel, line, where))
                elif not is_bind:
                    bare_ns.append((rel, line, '.'.join(r), where))
            i = end if end > i else i + 1
    return uses, bare_ns, report, files


def main():
    src = sys.argv[1]
    names, other = api_names(open(os.path.join(src, 'core', 'core.zig')).read())
    print(f"api: {len(names)} names in {len({n for n,_ in names})} namespaces; non-struct top entries: {other}")
    uses, bare, report, files = analyse(src, names)
    for r in report:
        print(r)
    print(f"files read: {len(files)}")
    for b in bare:
        print("BARE namespace/api use:", b)
    total = sum(len(v) for v in uses.values())
    print(f"uses: {total}, code {sum(1 for v in uses.values() for u in v if u[2]=='code')}, test {sum(1 for v in uses.values() for u in v if u[2]=='test')}")
    code_only = test_only = none = 0
    for key in names:
        u = uses.get(key, [])
        c = [x for x in u if x[2] == 'code']
        t = [x for x in u if x[2] == 'test']
        if not u:
            print("NONE", '.'.join(key)); none += 1
        elif not c:
            print("TEST-ONLY", '.'.join(key), t); test_only += 1
    for key in names:
        u = uses.get(key, [])
        c = sorted({(x[0], x[1]) for x in u if x[2] == 'code'})
        print(f"  {'.'.join(key):45s} code={len(c):3d} test={sum(1 for x in u if x[2]=='test'):3d} first-code={c[:2]}")
    print(f"summary: names={len(names)} test-only={test_only} unused={none}")


main()
