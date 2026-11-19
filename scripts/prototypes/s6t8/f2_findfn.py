"""S6-T8 F2: find named functions of an unstripped build in a stripped build's disassembly by their first
instructions (operands that are addresses masked), and print each match's address and its offset mod 64.
    findfn.py SYM.s STRIPPED.s NAME [NAME...]"""
import re
import sys

ADDR = re.compile(r"0x[0-9a-f]+( <[^>]*>)?")


def norm(ins):
    ins = ins.split(";")[0].strip()
    return ADDR.sub("A", ins)


def functions(path):
    out, name = {}, None
    for raw in open(path, encoding="utf-8", errors="replace"):
        line = raw.rstrip("\n")
        if line.startswith("<") and line.endswith(">:"):
            name = line[1:-2]
            out[name] = []
        elif name and line.strip():
            out[name].append(norm(line))
    return out


def stream(path):
    # objdump with addresses: "   9df64: \tsub\t..." ; returns [(addr, norm)]
    rows = []
    for raw in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r"^\s*([0-9a-f]+):\s+(.*)$", raw.rstrip("\n"))
        if m:
            rows.append((int(m.group(1), 16), norm(m.group(2))))
    return rows


sym = functions(sys.argv[1])
rows = stream(sys.argv[2])
seq = [r[1] for r in rows]
for name in sys.argv[3:]:
    head = sym[name][:16]
    hits = [i for i in range(len(seq) - len(head)) if seq[i:i + len(head)] == head]
    print(name, " ".join(f"{rows[i][0]:#x}(mod64={rows[i][0] % 64})" for i in hits) or "not found", f"len={len(sym[name])}")
