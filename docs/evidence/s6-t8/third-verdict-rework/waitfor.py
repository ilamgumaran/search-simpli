"""Block until the process whose command line contains PATTERN exits, or 160 s pass (kqueue NOTE_EXIT; no reads)."""
import select, subprocess, sys
pids = subprocess.run(["pgrep", "-f", sys.argv[1]], capture_output=True, text=True).stdout.split()
if not pids:
    print("not running"); sys.exit(0)
kq = select.kqueue()
ev = select.kevent(int(pids[0]), filter=select.KQ_FILTER_PROC, flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT, fflags=select.KQ_NOTE_EXIT)
try:
    print("exited" if kq.control([ev], 1, 160) else "timeout")
except ProcessLookupError:
    print("exited")
