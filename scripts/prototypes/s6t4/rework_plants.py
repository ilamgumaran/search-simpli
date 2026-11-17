import sys
root, name = sys.argv[1], sys.argv[2]
p = root + '/zig/src/lexical_segment.zig'
s = open(p).read()
def rep(a, b):
    global s
    assert s.count(a) == 1, (name, a[:70])
    s = s.replace(a, b)
if name == 'P3':
    rep("postings.decodeList(posting_bytes[coded_start..][0..coded_length], document_frequency",
        "postings.decodeList(if (term_index + 1 == header.term_count) posting_bytes[coded_start..] else posting_bytes[coded_start..][0..coded_length], document_frequency")
    rep("if (posting_start != header.posting_count or coded_start != posting_bytes.len) return error.InvalidPostingRange;",
        "if (posting_start != header.posting_count) return error.InvalidPostingRange;")
elif name in ('L1', 'L3'):
    rep("""    if (at != document_length_bytes.len) return error.InvalidSectionLength;

    // Sections 2 and 3: front-coded""", """
    // Sections 2 and 3: front-coded""")
    if name == 'L3':
        rep("""    for (document_length_output[0..header.document_count]) |*length| {
        length.* = postings.readVarint(document_length_bytes, &at) orelse return error.InvalidSectionLength;""",
            """    for (document_length_output[0..header.document_count], 0..) |*length, i| {
        length.* = postings.readVarint(if (i + 1 == header.document_count) encoded[header_length_v3..] else document_length_bytes, &at) orelse return error.InvalidSectionLength;""")
elif name == 'L2':
    rep("if (at != dictionary_bytes.len or text_at != header.term_text_bytes) return error.InvalidSectionLength;",
        "if (text_at != header.term_text_bytes) return error.InvalidSectionLength;")
open(p, 'w').write(s)
print('planted', name)
