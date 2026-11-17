"""S6-T7 verifier: recompute every record id as the format document states
(sha256(path NUL start NUL end NUL text)[:20]) from the decoded fields."""
import hashlib, os, sys
from pathlib import Path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import v5dec
root = Path(sys.argv[1])
for c in sys.argv[2:]:
    p = root / c / "documents-1.hybseg"
    docs = v5dec.decode_documents(p.read_bytes(), True, str(p))
    bad = 0
    for r in docs["records"]:
        h = hashlib.sha256(r["path"] + b"\0" + str(r["start"]).encode() + b"\0" + str(r["end"]).encode() + b"\0" + r["text"]).hexdigest()[:20].encode()
        bad += h != r["id"]
    print(c, "records", len(docs["records"]), "id-mismatch", bad)
