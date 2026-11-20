"""S6-T9 verifier: one sha256 over a folder's relative paths and bytes, the file count and the byte count.  treehash.py DIR..."""
import hashlib, os, sys
for d in sys.argv[1:]:
    h = hashlib.sha256(); n = b = 0
    for a, ds, fs in os.walk(d):
        ds.sort()
        for f in sorted(fs):
            p = os.path.join(a, f); data = open(p, 'rb').read()
            h.update(os.path.relpath(p, d).encode() + b'\0' + data + b'\0'); n += 1; b += len(data)
    print(f"{h.hexdigest()[:16]} files={n} bytes={b} {os.path.basename(d.rstrip('/'))}")
