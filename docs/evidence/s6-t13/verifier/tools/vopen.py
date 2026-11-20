"""S6-T13 verifier: ss_open time, one library and one index per process (ctypes).
    python3 -I vopen.py LIB INDEX BUILD CORPUS RUN OUT.jsonl
8 untimed opens, then 50 timed ss_open (each followed by an untimed ss_close); wall (perf_counter_ns) and thread CPU
(thread_time_ns) of ss_open alone; median and min in ms, one JSON line appended to OUT."""
import ctypes, json, statistics, sys, time

lib_path, index, build, corpus, run, out = sys.argv[1:7]
lib = ctypes.CDLL(lib_path)
lib.ss_open.argtypes = [ctypes.c_char_p]; lib.ss_open.restype = ctypes.c_void_p
lib.ss_close.argtypes = [ctypes.c_void_p]; lib.ss_close.restype = None
lib.ss_last_error.restype = ctypes.c_char_p
path = index.encode()
wall, cpu = [], []
for i in range(58):
    c0 = time.thread_time_ns(); w0 = time.perf_counter_ns()
    h = lib.ss_open(path)
    w1 = time.perf_counter_ns(); c1 = time.thread_time_ns()
    if not h:
        sys.exit("ss_open failed: " + lib.ss_last_error().decode())
    lib.ss_close(h)
    if i >= 8:
        wall.append((w1 - w0) / 1e6); cpu.append((c1 - c0) / 1e6)
row = dict(build=build, corpus=corpus, run=run, n=len(wall), wall_med=statistics.median(wall), wall_min=min(wall),
           cpu_med=statistics.median(cpu), at=time.strftime("%F %T"))
open(out, "a").write(json.dumps(row) + "\n")
