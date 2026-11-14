#!/usr/bin/env python3
"""S5-T12: part 2 with a verb form's compared key df kept for its member
(no second read). python3 -I part2b.py FOLD_ZIG"""
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
reps = [
("""/// A group's members as `compute` collects them, each with the body entry
/// its key df is read from (`member`), until the group is kept.
const Collected = struct {
    members: std.ArrayList(fuzzy.Member) = .empty,
    sources: std.ArrayList(?postings.TermEntry) = .empty,

    fn append(collected: *Collected, allocator: std.mem.Allocator, m: fuzzy.Member, source: ?postings.TermEntry) !void {
        try collected.members.append(allocator, m);
        try collected.sources.append(allocator, source);
    }
""",
"""/// A group's members as `compute` collects them, each with the body entry
/// its key df is read from (`member`), until the group is kept; a verb form
/// whose df was read to compare it with a held word's keeps that df, so no
/// key df is read twice.
const Collected = struct {
    members: std.ArrayList(fuzzy.Member) = .empty,
    sources: std.ArrayList(Source) = .empty,

    const Source = struct { entry: ?postings.TermEntry, key_df: ?u32 = null };

    fn append(collected: *Collected, allocator: std.mem.Allocator, m: fuzzy.Member, source: Source) !void {
        try collected.members.append(allocator, m);
        try collected.sources.append(allocator, source);
    }
"""),
("""        for (collected.members.items, collected.sources.items) |*m, source| m.key_df = try keyFrequencyOf(context, source);""",
 """        for (collected.members.items, collected.sources.items) |*m, source| m.key_df = source.key_df orelse try keyFrequencyOf(context, source.entry);"""),
("""        var m = member(context, candidate) orelse continue;
        if (held == null) held = heldOf(context, token);
        if (held.?.held) {
            if (held.?.key_df == null) held.?.key_df = try keyFrequencyOf(context, held.?.entry);
            if (try keyFrequencyOf(context, candidate.body) > held.?.key_df.?) continue;
            m.weight = verb_form_held_weight;
        } else {
            m.weight = verb_form_unheld_weight;
        }
        try collected.append(allocator, m, candidate.body);""",
"""        var m = member(context, candidate) orelse continue;
        if (held == null) held = heldOf(context, token);
        var source = Collected.Source{ .entry = candidate.body };
        if (held.?.held) {
            if (held.?.key_df == null) held.?.key_df = try keyFrequencyOf(context, held.?.entry);
            source.key_df = try keyFrequencyOf(context, candidate.body);
            if (source.key_df.? > held.?.key_df.?) continue;
            m.weight = verb_form_held_weight;
        } else {
            m.weight = verb_form_unheld_weight;
        }
        try collected.append(allocator, m, source);"""),
("""if (member(context, candidate)) |m| try collected.append(allocator, m, candidate.body);
        }
        const r""", """if (member(context, candidate)) |m| try collected.append(allocator, m, .{ .entry = candidate.body });
        }
        const r"""),
("""            if (member(context, candidate)) |m| try collected.append(allocator, m, candidate.body);
        }
        try appendVerbForms""", """            if (member(context, candidate)) |m| try collected.append(allocator, m, .{ .entry = candidate.body });
        }
        try appendVerbForms"""),
]
for old, new in reps:
    assert s.count(old) == 1, old[:60]
    s = s.replace(old, new)
open(p, "w", encoding="utf-8").write(s)
