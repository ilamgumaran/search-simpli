"""S6-T5 verifier: apply each plant to its own copy (plants.noindex/<name>/zig). Exact-string edits; each must apply once."""
import pathlib, sys
P = pathlib.Path(sys.argv[1])
ONLY = set(sys.argv[2:])
def edit(name, rel, old, new):
    if ONLY and name not in ONLY:
        return
    f = P / name / "zig" / rel
    s = f.read_text()
    assert s.count(old) == 1, (name, rel, s.count(old))
    f.write_text(s.replace(old, new))
    print("planted", name, rel)
# The builder's four (S6-T5 Report section 5), re-made from their descriptions.
edit("p1", "src/filename_response.zig",
     "        if (report.hasWarnings(extras)) try report.writeWarnings(&json, extras);",
     "        if (field != .both) if (report.hasWarnings(extras)) try report.writeWarnings(&json, extras);")
edit("p2", "src/filename_field.zig",
     "        if (inScope(decoded.catalog[p.document_index], decoded.anchors[p.document_index], options)) return true;",
     "        _ = p;\n        _ = options;\n        return true;")
edit("p3", "src/filename_field.zig",
     "        var kept: usize = 0;\n        for (trace.unmatched.items) |item| {",
     "        if (trace.unique_terms != std.math.maxInt(usize)) return;\n        var kept: usize = 0;\n        for (trace.unmatched.items) |item| {")
edit("p4", "src/engine.zig",
     "\n            if (computed.expanded) |g| try noteExpanded(t, g);\n",
     "\n")
# Mine.
# v5: `unmatched` under filename decided from every name, hidden or not (the both path keeps the scope test).
edit("v5", "src/filename_field.zig",
     "        if (!visibleNameHolds(decoded, token, options)) try postings.noteUnmatched(trace, token, false);",
     "        if (decoded.filenameTerm(token) == null) try postings.noteUnmatched(trace, token, false);")
# v6: under both, each fold group's member list cut to its first member.
edit("v6", "src/engine.zig",
     "\n            if (computed.folded) |g| try noteGrouped(t, g);\n",
     "\n            if (computed.folded) |g| {\n                const before = t.grouped.items.len;\n                try noteGrouped(t, g);\n                for (t.grouped.items[before..]) |*item| item.members = item.members[0..@min(item.members.len, 1)];\n            }\n")
# v7 (second pass): under both, each expansion list cut to its first word.
edit("v7", "src/engine.zig",
     "\n            if (computed.expanded) |g| try noteExpanded(t, g);\n",
     "\n            if (computed.expanded) |g| {\n                const before = t.expanded.items.len;\n                try noteExpanded(t, g);\n                for (t.expanded.items[before..]) |*item| item.expansions = item.expansions[0..@min(item.expansions.len, 1)];\n            }\n")
