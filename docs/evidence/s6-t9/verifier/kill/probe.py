"""S6-T9 verifier: probe_raw.py's answers, each hashed (generation numbers kept). probe.py LIB IDX"""
import hashlib, json, os, subprocess, sys
r = subprocess.run([sys.executable, "-I", os.path.join(os.path.dirname(os.path.abspath(__file__)), "probe_raw.py")] + sys.argv[1:3], capture_output=True, text=True)
if r.returncode != 0:
    print(r.stdout + r.stderr); sys.exit(r.returncode)
print(json.dumps({k: hashlib.sha256(v.encode()).hexdigest()[:16] for k, v in json.loads(r.stdout).items()}))
