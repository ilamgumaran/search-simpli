"""S6-T13 verifier: ss_open across real processes while another process publishes through the library.
    python3 -I vxproc.py writer LIB DIR SECONDS KEEP [FIRST]     (KEEP: none, 1 or 2; FIRST generation, default 1)
    python3 -I vxproc.py reader LIB DIR SECONDS TAG
The writer publishes generations 1, 2, 3, ... with ss_import_json (240 documents each, or $VXDOCS; the embedding model id
alternates between 1 and 40 characters, so every other MANIFEST is 39 bytes longer than the one it replaces), with
"keep_generations" KEEP. A reader runs ss_open / ss_status / ss_close in a loop and counts the opens, the error
messages, and any status whose generation is not one the writer published. Not part of any library or the build."""
import collections, ctypes, json, os, sys, time

role, lib_path, d, seconds = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
lib = ctypes.CDLL(lib_path)
lib.ss_last_error.restype = ctypes.c_char_p
if role == "writer":
    keep = sys.argv[5]
    lib.ss_import_json.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_size_t]
    lib.ss_import_json.restype = ctypes.c_int64
    docs = [{"id": f"d{i}", "path": f"notes/n{i % 37}.md", "start_line": 1 + i, "end_line": 2 + i,
             "text": f"kestrel lantern harbour note {i} " + "meadow ferry quillon " * (1 + i % 9), "vector": [0.6, 0.8],
             "required_labels": []} for i in range(int(os.environ.get("VXDOCS", "240")))]
    first = int(sys.argv[6]) if len(sys.argv) > 6 else 1
    end, n, fails = time.monotonic() + seconds, first - 1, collections.Counter()
    while n == first - 1 or time.monotonic() < end:
        g = n + 1
        p = {"format_version": 1, "generation": g, "analyzer_id": "analyzer-v2",
             "embedding_model_id": "m" if g % 2 else "m" * 40, "documents": docs}
        if keep != "none":
            p["keep_generations"] = int(keep)
        b = json.dumps(p).encode()
        r = lib.ss_import_json(d.encode(), b, len(b))
        if r < 0:
            fails[lib.ss_last_error().decode()] += 1
        n += 1
    print(json.dumps({"role": "writer", "keep": keep, "publishes": n - first + 1, "last_generation": n, "failures": dict(fails),
                      "manifest_bytes": os.path.getsize(os.path.join(d, "MANIFEST"))}))
elif role == "folder":
    # python3 -I vxproc.py folder LIB DIR SECONDS KEEP FOLDER: ss_index_folder --update in a loop over FOLDER (one
    # file rewritten each time, its length alternating), filename index on, keep_generations KEEP (v2 generations
    # with source, file-name and state sections).
    keep, folder = sys.argv[5], sys.argv[6]
    lib.ss_index_folder.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]
    lib.ss_index_folder.restype = ctypes.c_void_p
    lib.ss_free.argtypes = [ctypes.c_void_p]
    end, n, fails = time.monotonic() + seconds, 0, collections.Counter()
    while n == 0 or time.monotonic() < end:
        with open(os.path.join(folder, "changing.md"), "w") as f:
            f.write("kestrel lantern " * (1 + n % 2 * 30) + f"{n}\n")
        o = {"update": True, "filename_index": True}
        if keep != "none":
            o["keep_generations"] = int(keep)
        r = lib.ss_index_folder(d.encode(), folder.encode(), json.dumps(o).encode())
        if not r:
            fails[lib.ss_last_error().decode()] += 1
        else:
            lib.ss_free(r)
        n += 1
    print(json.dumps({"role": "folder-writer", "keep": keep, "publishes": n, "failures": dict(fails)}))
else:
    tag = sys.argv[5]
    lib.ss_open.argtypes = [ctypes.c_char_p]; lib.ss_open.restype = ctypes.c_void_p
    lib.ss_close.argtypes = [ctypes.c_void_p]
    lib.ss_status.argtypes = [ctypes.c_void_p]; lib.ss_status.restype = ctypes.c_void_p
    lib.ss_free.argtypes = [ctypes.c_void_p]
    end, opens, errors, gens, odd = time.monotonic() + seconds, 0, collections.Counter(), set(), 0
    while time.monotonic() < end:
        h = lib.ss_open(d.encode())
        opens += 1
        if not h:
            errors[lib.ss_last_error().decode()] += 1
            continue
        s = lib.ss_status(h)
        st = json.loads(ctypes.string_at(s).decode())
        lib.ss_free(s)
        if os.environ.get("VXFOLDER") is None and (st["documents"] != int(os.environ.get("VXDOCS", "240")) or st["embedding_model_id"] != ("m" if st["generation"] % 2 else "m" * 40)):
            odd += 1
        gens.add(st["generation"])
        lib.ss_close(h)
    print(json.dumps({"role": "reader", "tag": tag, "opens": opens, "errors": dict(errors), "mixed_status": odd,
                      "distinct_generations": len(gens)}))
