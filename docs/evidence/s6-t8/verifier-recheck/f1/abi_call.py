"""S6-T8 verifier (recheck): one C ABI writer call in its own process.
  abi_call.py LIB ss_index_folder INDEX_DIR FOLDER
  abi_call.py LIB ss_apply_changes INDEX_DIR CHANGES_JSON
  An optional fifth argument replaces the options JSON (default {"filename_index":true}).
Prints "WROTE: <payload start>" or "refused: <ss_last_error>"."""
import ctypes, sys

lib = ctypes.CDLL(sys.argv[1])
fn = getattr(lib, sys.argv[2])
fn.restype = ctypes.c_void_p
fn.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]
lib.ss_last_error.restype = ctypes.c_char_p
p = fn(sys.argv[3].encode(), sys.argv[4].encode(), (sys.argv[5] if len(sys.argv) > 5 else '{"filename_index":true}').encode())
if p:
    print("WROTE: " + ctypes.string_at(p).decode("utf-8", "replace")[:80])
else:
    print("refused: " + (lib.ss_last_error() or b"").decode("utf-8", "replace"))
