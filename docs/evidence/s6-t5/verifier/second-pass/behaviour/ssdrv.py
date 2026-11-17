"""S6-T5 verifier: a small ctypes driver over libsearch_simpli (ss_apply_changes, ss_open, ss_query)."""
import base64
import ctypes
import json
import os


class Lib:
    def __init__(self, path):
        lib = ctypes.CDLL(path)
        lib.ss_open.argtypes = [ctypes.c_char_p]
        lib.ss_open.restype = ctypes.c_void_p
        lib.ss_close.argtypes = [ctypes.c_void_p]
        lib.ss_close.restype = None
        lib.ss_query.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_float), ctypes.c_size_t,
                                 ctypes.c_size_t, ctypes.c_char_p]
        lib.ss_query.restype = ctypes.c_void_p
        lib.ss_apply_changes.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]
        lib.ss_apply_changes.restype = ctypes.c_void_p
        lib.ss_free.argtypes = [ctypes.c_void_p]
        lib.ss_free.restype = None
        lib.ss_last_error.restype = ctypes.c_char_p
        lib.ss_version.restype = ctypes.c_char_p
        self.lib = lib
        self.path = path

    def version(self):
        return self.lib.ss_version().decode()

    def apply(self, directory, roots, files, opts=None):
        changes = {"roots": roots, "changes": []}
        for f in files:
            c = {"op": "add", "root_id": f["root"], "path": f["path"],
                 "content_base64": base64.b64encode(f["text"].encode()).decode()}
            if f.get("labels"):
                c["required_labels"] = f["labels"]
            changes["changes"].append(c)
        os.makedirs(directory, exist_ok=True)
        p = self.lib.ss_apply_changes(directory.encode(), json.dumps(changes).encode(),
                                      json.dumps(opts or {"filename_index": True}).encode())
        if not p:
            raise RuntimeError("ss_apply_changes: " + self.lib.ss_last_error().decode())
        out = ctypes.string_at(p)
        self.lib.ss_free(p)
        return out

    def open(self, directory):
        h = self.lib.ss_open(directory.encode())
        if not h:
            raise RuntimeError("ss_open: " + self.lib.ss_last_error().decode())
        return h

    def close(self, h):
        self.lib.ss_close(h)

    def query(self, h, text, field, extra=None, vector=None, top_k=5):
        options = {"retrieval_mode": "lexical", "search_field": field}
        options.update(extra or {})
        if vector:
            arr = (ctypes.c_float * len(vector))(*vector)
            vp, vn = arr, len(vector)
        else:
            vp, vn = None, 0
        p = self.lib.ss_query(h, text.encode(), vp, vn, top_k, json.dumps(options).encode())
        if not p:
            return None, self.lib.ss_last_error().decode()
        out = ctypes.string_at(p)
        self.lib.ss_free(p)
        return out, None


def warnings_bytes(answer: bytes) -> bytes:
    start = answer.index(b'"warnings":[')
    end = answer.index(b'],"request":', start)
    return answer[start + len(b'"warnings":'):end + 1]


def outside_warnings(answer: bytes) -> bytes:
    w = warnings_bytes(answer)
    start = answer.index(b'"warnings":[')
    return answer[:start] + b'"warnings":<W>' + answer[start + len(b'"warnings":') + len(w):]
