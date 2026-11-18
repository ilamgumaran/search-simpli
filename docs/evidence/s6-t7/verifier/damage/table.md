56
| d_hdr_flags | documents header flags 0x0003 | open refused: InvalidDocumentSection |
| d_hdr_version6 | documents version 6 | open refused: InvalidDocumentSection |
| d_bound_filecount | file count raised past what the table bytes can hold (table bytes / 4 + 1) | open refused: InvalidFileTable |
| d_bound_doccount | document count raised past records bytes / 8 | open refused: DocumentCountMismatch |
| d_shared_first | entry 0 with shared = 1 | open refused: InvalidFileTable |
| d_shared_gt_prev | entry 1 shared = previous path length + 1 (suffix one shorter) | open refused: InvalidFileTable |
| d_shared_256 | shared = 256 on a pair sharing > 256 bytes (suffix one shorter: the decoded path is unchanged) | open refused: InvalidFileTable |
| d_suffix_zero | an entry with suffix length 0 (shared = the previous path's length) | open refused: InvalidFileTable |
| d_unsorted | entries 1 and 2 swapped (records left in place) | open refused: UnsortedPaths |
| d_noncanonical | a non-canonical entry: shared one short, the byte moved into the suffix | open refused: UnsortedPaths |
| d_pathbytes_plus1 | header decoded path bytes + 1 | open refused: InvalidFileTable |
| d_pathbytes_minus1 | header decoded path bytes - 1 | open refused: InvalidFileTable |
| d_chunks_short_last | last entry's chunk count - 1 (the counts no longer sum to the record count; header document count unchanged) | open refused: InvalidFileTable |
| d_chunks_long_first | first entry's chunk count + 1 (sum passes the record count) | open refused: InvalidFileTable |
| d_chunks0_notretained | an entry with chunk count 0 and retained 0 (its records moved to the next entry) | open refused: InvalidFileTable |
| d_table_leftover | one byte left over after the file table's last entry | open refused: TrailingData |
| d_table_last_cut | the file table's last byte dropped (the last entry's value varint cut) | open refused: InvalidFileTable |
| d_table_varint_overrun | the last entry's value varint given a continuation bit at the end of the area (overruns) | open refused: InvalidFileTable |
| d_records_leftover | one byte left over after the last record | open refused: TrailingData |
| d_records_last_cut | the last record's last byte dropped | open refused: InvalidRecord |
| d_record_flags | the first record's flags with bit 3 | open refused: UnsupportedFlags |
| d_record_start0 | the first record's start line 0 | open refused: InvalidCitation |
| d_varint_overlong | the first record's flags as a 6-byte u32 varint | open refused: InvalidRecord |
| d_last_take_overrun | the last record's text length + 1 (its text and path run one past the area) | open refused: InvalidRecord |
| d_retained_nosource | retained bit set on a file while the manifest binds no source section (a no-source index) | open refused: InvalidFileTable |
| m_bit6_clear | manifest bit 6 cleared over a v5 documents section | open refused: InvalidDocumentSection |
| m_bit6_on_v4 | manifest bit 6 set over v4 documents and HYBSRC01 (main's index) | open refused: InvalidDocumentSection |
| d_truncated | the documents section one byte short (header unchanged) | open refused: DocumentSectionSizeMismatch |
| d_trailing_file | one byte appended to the documents section (header unchanged) | open ok, query ok; one file refused: ; wrong bytes returned: 0 |
| d_checksum | one record byte flipped, checksum not resealed | open refused: InvalidDocumentSection |
| s_count_plus1 | source header file count + 1 | open ok, query ok; outline/read_span refused for all 88 files: SourceFileCountMismatch; wrong bytes returned: 0 |
| s_bound_records | source records bytes lowered below 35 x file count | open ok, query ok; outline/read_span refused for all 88 files: InvalidFileTable; wrong bytes returned: 0 |
| s_flags_unknown | a record with flag bit 2 (unknown) | open ok, query ok; outline/read_span refused for all 88 files: InvalidFileTable; wrong bytes returned: 0 |
| s_chunk0_notwhole | a file with 0 chunks not kept whole | open ok, query ok; outline/read_span refused for all 88 files: InvalidFileTable; wrong bytes returned: 0 |
| s_chunkcount | a record's chunk count + 1 (one more recipe value) | open ok, query ok; outline/read_span refused for all 88 files: InvalidFileTable; wrong bytes returned: 0 |
| s_recipe_pos_past | a gap so large the position passes the file's length | open ok, query ok; outline/read_span refused for all 88 files: InvalidFileTable; wrong bytes returned: 0 |
| s_recipe_varint_overrun | the last record's last recipe varint given a continuation bit at the end of the records area | open ok, query ok; outline/read_span refused for all 88 files: InvalidFileTable; wrong bytes returned: 0 |
| s_overlap_first | the first chunk an overlap (k = 1 > pos = 0) | open ok, query ok; outline/read_span refused for all 88 files: InvalidFileTable; wrong bytes returned: 0 |
| s_overlap_gt_pos | a later chunk's overlap k = pos + 1 | open ok, query ok; outline/read_span refused for all 88 files: InvalidFileTable; wrong bytes returned: 0 |
| s_overlap_gt_prev_le_pos | a later chunk's overlap larger than the previous chunk but <= pos (no walk rule; the SHA-256 must refuse) | open ok, query ok; outline/read_span refused for all 88 files: InvalidFileTable; wrong bytes returned: 0 |
| s_residual_leftover | one byte left over in the residual area | open ok, query ok; outline/read_span refused for all 88 files: InvalidFileTable; wrong bytes returned: 0 |
| s_residual_short | the residual area's last byte dropped | open ok, query ok; outline/read_span refused for all 88 files: InvalidFileTable; wrong bytes returned: 0 |
| s_records_leftover | one byte left over after the last record | open ok, query ok; outline/read_span refused for all 88 files: TrailingData; wrong bytes returned: 0 |
| s_maps_leftover | one varint left over after the last map | open ok, query ok; outline/read_span refused for all 88 files: InvalidLineMap; wrong bytes returned: 0 |
| s_maps_last_cut | the last map's last varint dropped | open ok, query ok; outline/read_span refused for all 88 files: InvalidLineMap; wrong bytes returned: 0 |
| s_sha_residual | one byte of the residual area flipped (a gap or tail byte of the first file with residual bytes) | open ok, query ok; one file refused: SourceFileSha256Mismatch; wrong bytes returned: 0 |
| s_sha_record | a record's stored SHA-256 with one bit flipped | open ok, query ok; one file refused: SourceFileSha256Mismatch; wrong bytes returned: 0 |
| s_sha_chunktext | one byte of a chunk's text flipped in the documents section (a rebuilt file, not kept whole) | open ok, query ok; one file refused: SourceFileSha256Mismatch; wrong bytes returned: 0 |
| s_bom_flag | the BOM flag set on a file without a BOM | open ok, query ok; one file refused: InvalidLineMap; wrong bytes returned: 0 |
| s_map_value | a line map's second value + 1 | open ok, query ok; one file refused: InvalidLineMap; wrong bytes returned: 0 |
| s_length_plus1 | a record's length + 1 | open ok, query ok; outline/read_span refused for all 88 files: InvalidFileTable; wrong bytes returned: 0 |
| s_whole_flag_set | a rebuilt file's record marked kept whole (its recipe dropped) | open ok, query ok; outline/read_span refused for all 88 files: InvalidFileTable; wrong bytes returned: 0 |
| s_checksum | one source byte flipped, checksum not resealed | open ok, query ok; outline/read_span refused for all 88 files: ChecksumMismatch; wrong bytes returned: 0 |
| d_trailing_bound | one byte after the last record inside the bound section: header lengths unchanged, manifest length and both checksums resealed | open refused: InvalidDocumentSection |
| d_bound_doccount_m | document count raised past records bytes / 8, in the header and the manifest | open refused: DocumentCountMismatch |
| s_overlap_isolated | an overlap k > pos on a later chunk with the record's length lowered by k, so the residual total still adds up (only the k > pos rule refuses it in the walk) | open ok, query ok; outline/read_span refused for all 88 files: InvalidFileTable; wrong bytes returned: 0 |
