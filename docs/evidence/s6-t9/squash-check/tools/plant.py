# plant.py SRC_FILE PLANT : write one planted incremental_state.zig (A, B or C) from the committed copy
import sys
path, plant = sys.argv[1], sys.argv[2]
text = open(path).read()
rp = text.index("pub fn resolvePointer(")
lb = text.index("pub fn loadBound(")
miss = "        else => return null,\n    }).bytes;"
if plant == "A":  # resolvePointer returns the state with a wrong generation
    old = "    if (state.generation != metadata.generation or !std.mem.eql(u8, state.analyzer_id, metadata.analyzer_id)) return error.InvalidState;\n    return state;\n"
    assert text.count(old) == 1
    text = text.replace(old, old.replace("    return state;\n", "    var planted = state;\n    planted.generation +%= 1;\n    return planted;\n"))
elif plant == "B":  # resolvePointer: a missing MANIFEST is an error, not null
    i = text.index(miss, rp)
    assert i < lb
    text = text[:i] + "        error.FileNotFound => return error.InvalidState,\n" + text[i:]
elif plant == "C":  # loadBound: a missing MANIFEST is an error, not null
    i = text.index(miss, lb)
    text = text[:i] + "        error.FileNotFound => return error.InvalidState,\n" + text[i:]
open(path, "w").write(text)
