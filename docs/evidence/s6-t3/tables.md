## 1. Corpora

| Corpus | Files | Corpus bytes | Chunks | Distinct terms | Postings | Tokens |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| timing-1k | 1,000 | 916,353 | 2,071 | 24,057 | 128,157 | 139,929 |
| timing-10k | 10,000 | 7,269,199 | 19,959 | 24,057 | 1,023,806 | 1,135,768 |
| prose-1k | 1,000 | 1,676,925 | 1,819 | 3,115 | 217,469 | 310,043 |
| prose-10k | 10,000 | 17,244,024 | 18,766 | 3,115 | 2,238,541 | 3,186,965 |
| tamil-1k | 1,000 | 3,250,702 | 1,963 | 21,600 | 118,713 | 130,490 |
| tamil-10k | 10,000 | 27,708,457 | 19,946 | 21,600 | 1,019,062 | 1,138,558 |
| fixtures | 232 | 4,635,177 | 4,084 | 68,074 | 379,874 | 584,504 |
| family | 46 | 1,237,342 | 1,063 | 17,512 | 190,608 | 231,422 |

## 2. Index size against corpus size, one generation

| Corpus | Corpus bytes | Index bytes | Ratio | Index bytes with the file-name channel | Ratio |
| --- | ---: | ---: | ---: | ---: | ---: |
| timing-1k | 916,353 | 4,432,838 | 4.84 | 4,560,085 | 4.98 |
| timing-10k | 7,269,199 | 31,011,398 | 4.27 | 32,281,645 | 4.44 |
| prose-1k | 1,676,925 | 6,705,317 | 4.00 | 6,907,482 | 4.12 |
| prose-10k | 17,244,024 | 68,047,830 | 3.95 | 69,778,345 | 4.05 |
| tamil-1k | 3,250,702 | 9,394,513 | 2.89 | 9,521,760 | 2.93 |
| tamil-10k | 27,708,457 | 72,561,144 | 2.62 | 73,831,391 | 2.66 |
| fixtures | 4,635,177 | 17,466,159 | 3.77 | 17,499,412 | 3.78 |
| family | 1,237,342 | 5,615,029 | 4.54 | 5,621,585 | 4.54 |

## 3. Bytes per section file (file-name channel on)

| Corpus | documents | lexical | source | state | filenames | filename-lexical | MANIFEST | INDEX-STATE.json | Total |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| timing-1k | 1,124,313 | 2,191,940 | 1,018,756 | 97,159 | 78,036 | 49,091 | 696 | 94 | 4,560,085 |
| timing-10k | 9,273,775 | 12,487,753 | 8,279,041 | 970,159 | 780,036 | 490,091 | 696 | 94 | 32,281,645 |
| prose-1k | 1,949,560 | 2,841,458 | 1,804,792 | 108,837 | 102,992 | 99,053 | 696 | 94 | 6,907,482 |
| prose-10k | 20,071,912 | 28,358,524 | 18,529,034 | 1,087,690 | 1,031,098 | 699,297 | 696 | 94 | 69,778,345 |
| tamil-1k | 3,479,918 | 2,464,201 | 3,352,565 | 97,159 | 78,036 | 49,091 | 696 | 94 | 9,521,760 |
| tamil-10k | 30,037,019 | 12,835,061 | 28,718,235 | 970,159 | 780,036 | 490,091 | 696 | 94 | 73,831,391 |
| fixtures | 5,597,148 | 7,021,709 | 4,821,461 | 24,805 | 20,566 | 12,567 | 1,062 | 94 | 17,499,412 |
| family | 1,519,088 | 2,829,604 | 1,260,950 | 4,626 | 3,621 | 2,815 | 787 | 94 | 5,621,585 |

Shares of the index:

| Corpus | documents | lexical | source | state | filenames | filename-lexical |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| timing-1k | 24.7 % | 48.1 % | 22.3 % | 2.1 % | 1.7 % | 1.1 % |
| timing-10k | 28.7 % | 38.7 % | 25.6 % | 3.0 % | 2.4 % | 1.5 % |
| prose-1k | 28.2 % | 41.1 % | 26.1 % | 1.6 % | 1.5 % | 1.4 % |
| prose-10k | 28.8 % | 40.6 % | 26.6 % | 1.6 % | 1.5 % | 1.0 % |
| tamil-1k | 36.5 % | 25.9 % | 35.2 % | 1.0 % | 0.8 % | 0.5 % |
| tamil-10k | 40.7 % | 17.4 % | 38.9 % | 1.3 % | 1.1 % | 0.7 % |
| fixtures | 32.0 % | 40.1 % | 27.6 % | 0.1 % | 0.1 % | 0.1 % |
| family | 27.0 % | 50.3 % | 22.4 % | 0.1 % | 0.1 % | 0.1 % |

## 4. Inside each section (file-name channel on)

Every row's parts sum to the file's size (`index_size_budget.py budget` refuses otherwise).

### timing-1k

| File | Part | Bytes | Share of file | Share of index |
| --- | --- | ---: | ---: | ---: |
| documents-1.hybseg | header | 36 | 0.0 % | 0.00 % |
| documents-1.hybseg | record lengths (id, path, text, vector, labels, section path: 6 x u32) | 49,704 | 4.4 % | 1.09 % |
| documents-1.hybseg | record lines (start, end, heading: 3 x u32) | 24,852 | 2.2 % | 0.54 % |
| documents-1.hybseg | record chunker index and section depth (2 x u16) | 8,284 | 0.7 % | 0.18 % |
| documents-1.hybseg | record source_doc_index (u32) | 8,284 | 0.7 % | 0.18 % |
| documents-1.hybseg | chunk ids (20 hex) | 41,420 | 3.7 % | 0.91 % |
| documents-1.hybseg | paths | 43,491 | 3.9 % | 0.95 % |
| documents-1.hybseg | chunk text | 913,211 | 81.2 % | 20.03 % |
| documents-1.hybseg | required labels | 0 | 0.0 % | 0.00 % |
| documents-1.hybseg | vectors | 0 | 0.0 % | 0.00 % |
| documents-1.hybseg | section paths (heading texts) | 35,031 | 3.1 % | 0.77 % |
| documents-1.hybseg | **total** | **1,124,313** | 100 % | 24.66 % |
| lexical-1.hyblex | header | 80 | 0.0 % | 0.00 % |
| lexical-1.hyblex | 1 document lengths (u32 each) | 8,284 | 0.4 % | 0.18 % |
| lexical-1.hyblex | 2 dictionary: term length + df (2 x u32) | 192,456 | 8.8 % | 4.22 % |
| lexical-1.hyblex | 2 dictionary: posting start + count (2 x u64) | 384,912 | 17.6 % | 8.44 % |
| lexical-1.hyblex | 2 dictionary: term bytes | 152,881 | 7.0 % | 3.35 % |
| lexical-1.hyblex | 3 postings: document index (u32) | 512,628 | 23.4 % | 11.24 % |
| lexical-1.hyblex | 3 postings: term frequency (u32) | 512,628 | 23.4 % | 11.24 % |
| lexical-1.hyblex | 4 positions: first ordinal per posting (varint) | 128,157 | 5.8 % | 2.81 % |
| lexical-1.hyblex | 4 positions: later ordinal gaps (varints) | 11,772 | 0.5 % | 0.26 % |
| lexical-1.hyblex | 5 offsets: token count per document (u32) | 8,284 | 0.4 % | 0.18 % |
| lexical-1.hyblex | 5 offsets: start gap varints | 139,929 | 6.4 % | 3.07 % |
| lexical-1.hyblex | 5 offsets: length varints | 139,929 | 6.4 % | 3.07 % |
| lexical-1.hyblex | **total** | **2,191,940** | 100 % | 48.07 % |
| source-1.hybsrc | header | 48 | 0.0 % | 0.00 % |
| source-1.hybsrc | file table: offsets, lengths, line count (u32 + 3 x u64 + u32) | 32,000 | 3.1 % | 0.70 % |
| source-1.hybsrc | file table: sha256 (32 bytes) | 32,000 | 3.1 % | 0.70 % |
| source-1.hybsrc | file table: encoding + reserved (4 bytes) | 4,000 | 0.4 % | 0.09 % |
| source-1.hybsrc | file table: paths | 21,000 | 2.1 % | 0.46 % |
| source-1.hybsrc | line maps (varints) | 13,355 | 1.3 % | 0.29 % |
| source-1.hybsrc | text (original file bytes) | 916,353 | 89.9 % | 20.10 % |
| source-1.hybsrc | **total** | **1,018,756** | 100 % | 22.34 % |
| state-1.hybstate | header | 32 | 0.0 % | 0.00 % |
| state-1.hybstate | payload header | 40 | 0.0 % | 0.00 % |
| state-1.hybstate | string table | 63 | 0.1 % | 0.00 % |
| state-1.hybstate | roots (24 bytes each) | 24 | 0.0 % | 0.00 % |
| state-1.hybstate | file records: sha256 (32 bytes) | 32,000 | 32.9 % | 0.70 % |
| state-1.hybstate | file records: root, flags, size, mtime, chunks, chunker, labels, lengths (44 bytes) | 44,000 | 45.3 % | 0.96 % |
| state-1.hybstate | label references | 0 | 0.0 % | 0.00 % |
| state-1.hybstate | paths (and moved_from) | 21,000 | 21.6 % | 0.46 % |
| state-1.hybstate | **total** | **97,159** | 100 % | 2.13 % |
| filenames-1.hybseg | header | 36 | 0.0 % | 0.00 % |
| filenames-1.hybseg | record lengths (id, path, text, vector, labels: 5 x u32) | 20,000 | 25.6 % | 0.44 % |
| filenames-1.hybseg | record lines (start, end: 2 x u32) | 8,000 | 10.3 % | 0.18 % |
| filenames-1.hybseg | chunk ids (20 hex) | 20,000 | 25.6 % | 0.44 % |
| filenames-1.hybseg | paths | 21,000 | 26.9 % | 0.46 % |
| filenames-1.hybseg | chunk text | 9,000 | 11.5 % | 0.20 % |
| filenames-1.hybseg | required labels | 0 | 0.0 % | 0.00 % |
| filenames-1.hybseg | vectors | 0 | 0.0 % | 0.00 % |
| filenames-1.hybseg | section paths (heading texts) | 0 | 0.0 % | 0.00 % |
| filenames-1.hybseg | **total** | **78,036** | 100 % | 1.71 % |
| filename-lexical-1.hyblex | header | 64 | 0.1 % | 0.00 % |
| filename-lexical-1.hyblex | 1 document lengths (u32 each) | 4,000 | 8.1 % | 0.09 % |
| filename-lexical-1.hyblex | 2 dictionary: term length + df (2 x u32) | 8,008 | 16.3 % | 0.18 % |
| filename-lexical-1.hyblex | 2 dictionary: posting start + count (2 x u64) | 16,016 | 32.6 % | 0.35 % |
| filename-lexical-1.hyblex | 2 dictionary: term bytes | 5,003 | 10.2 % | 0.11 % |
| filename-lexical-1.hyblex | 3 postings: document index (u32) | 8,000 | 16.3 % | 0.18 % |
| filename-lexical-1.hyblex | 3 postings: term frequency (u32) | 8,000 | 16.3 % | 0.18 % |
| filename-lexical-1.hyblex | **total** | **49,091** | 100 % | 1.08 % |
| MANIFEST | whole file | 696 | 100.0 % | 0.02 % |
| MANIFEST | **total** | **696** | 100 % | 0.02 % |
| INDEX-STATE.json | whole file | 94 | 100.0 % | 0.00 % |
| INDEX-STATE.json | **total** | **94** | 100 % | 0.00 % |

### timing-10k

| File | Part | Bytes | Share of file | Share of index |
| --- | --- | ---: | ---: | ---: |
| documents-1.hybseg | header | 36 | 0.0 % | 0.00 % |
| documents-1.hybseg | record lengths (id, path, text, vector, labels, section path: 6 x u32) | 479,016 | 5.2 % | 1.48 % |
| documents-1.hybseg | record lines (start, end, heading: 3 x u32) | 239,508 | 2.6 % | 0.74 % |
| documents-1.hybseg | record chunker index and section depth (2 x u16) | 79,836 | 0.9 % | 0.25 % |
| documents-1.hybseg | record source_doc_index (u32) | 79,836 | 0.9 % | 0.25 % |
| documents-1.hybseg | chunk ids (20 hex) | 399,180 | 4.3 % | 1.24 % |
| documents-1.hybseg | paths | 419,139 | 4.5 % | 1.30 % |
| documents-1.hybseg | chunk text | 7,239,281 | 78.1 % | 22.43 % |
| documents-1.hybseg | required labels | 0 | 0.0 % | 0.00 % |
| documents-1.hybseg | vectors | 0 | 0.0 % | 0.00 % |
| documents-1.hybseg | section paths (heading texts) | 337,943 | 3.6 % | 1.05 % |
| documents-1.hybseg | **total** | **9,273,775** | 100 % | 28.73 % |
| lexical-1.hyblex | header | 80 | 0.0 % | 0.00 % |
| lexical-1.hyblex | 1 document lengths (u32 each) | 79,836 | 0.6 % | 0.25 % |
| lexical-1.hyblex | 2 dictionary: term length + df (2 x u32) | 192,456 | 1.5 % | 0.60 % |
| lexical-1.hyblex | 2 dictionary: posting start + count (2 x u64) | 384,912 | 3.1 % | 1.19 % |
| lexical-1.hyblex | 2 dictionary: term bytes | 152,881 | 1.2 % | 0.47 % |
| lexical-1.hyblex | 3 postings: document index (u32) | 4,095,224 | 32.8 % | 12.69 % |
| lexical-1.hyblex | 3 postings: term frequency (u32) | 4,095,224 | 32.8 % | 12.69 % |
| lexical-1.hyblex | 4 positions: first ordinal per posting (varint) | 1,023,806 | 8.2 % | 3.17 % |
| lexical-1.hyblex | 4 positions: later ordinal gaps (varints) | 111,962 | 0.9 % | 0.35 % |
| lexical-1.hyblex | 5 offsets: token count per document (u32) | 79,836 | 0.6 % | 0.25 % |
| lexical-1.hyblex | 5 offsets: start gap varints | 1,135,768 | 9.1 % | 3.52 % |
| lexical-1.hyblex | 5 offsets: length varints | 1,135,768 | 9.1 % | 3.52 % |
| lexical-1.hyblex | **total** | **12,487,753** | 100 % | 38.68 % |
| source-1.hybsrc | header | 48 | 0.0 % | 0.00 % |
| source-1.hybsrc | file table: offsets, lengths, line count (u32 + 3 x u64 + u32) | 320,000 | 3.9 % | 0.99 % |
| source-1.hybsrc | file table: sha256 (32 bytes) | 320,000 | 3.9 % | 0.99 % |
| source-1.hybsrc | file table: encoding + reserved (4 bytes) | 40,000 | 0.5 % | 0.12 % |
| source-1.hybsrc | file table: paths | 210,000 | 2.5 % | 0.65 % |
| source-1.hybsrc | line maps (varints) | 119,794 | 1.4 % | 0.37 % |
| source-1.hybsrc | text (original file bytes) | 7,269,199 | 87.8 % | 22.52 % |
| source-1.hybsrc | **total** | **8,279,041** | 100 % | 25.65 % |
| state-1.hybstate | header | 32 | 0.0 % | 0.00 % |
| state-1.hybstate | payload header | 40 | 0.0 % | 0.00 % |
| state-1.hybstate | string table | 63 | 0.0 % | 0.00 % |
| state-1.hybstate | roots (24 bytes each) | 24 | 0.0 % | 0.00 % |
| state-1.hybstate | file records: sha256 (32 bytes) | 320,000 | 33.0 % | 0.99 % |
| state-1.hybstate | file records: root, flags, size, mtime, chunks, chunker, labels, lengths (44 bytes) | 440,000 | 45.4 % | 1.36 % |
| state-1.hybstate | label references | 0 | 0.0 % | 0.00 % |
| state-1.hybstate | paths (and moved_from) | 210,000 | 21.6 % | 0.65 % |
| state-1.hybstate | **total** | **970,159** | 100 % | 3.01 % |
| filenames-1.hybseg | header | 36 | 0.0 % | 0.00 % |
| filenames-1.hybseg | record lengths (id, path, text, vector, labels: 5 x u32) | 200,000 | 25.6 % | 0.62 % |
| filenames-1.hybseg | record lines (start, end: 2 x u32) | 80,000 | 10.3 % | 0.25 % |
| filenames-1.hybseg | chunk ids (20 hex) | 200,000 | 25.6 % | 0.62 % |
| filenames-1.hybseg | paths | 210,000 | 26.9 % | 0.65 % |
| filenames-1.hybseg | chunk text | 90,000 | 11.5 % | 0.28 % |
| filenames-1.hybseg | required labels | 0 | 0.0 % | 0.00 % |
| filenames-1.hybseg | vectors | 0 | 0.0 % | 0.00 % |
| filenames-1.hybseg | section paths (heading texts) | 0 | 0.0 % | 0.00 % |
| filenames-1.hybseg | **total** | **780,036** | 100 % | 2.42 % |
| filename-lexical-1.hyblex | header | 64 | 0.0 % | 0.00 % |
| filename-lexical-1.hyblex | 1 document lengths (u32 each) | 40,000 | 8.2 % | 0.12 % |
| filename-lexical-1.hyblex | 2 dictionary: term length + df (2 x u32) | 80,008 | 16.3 % | 0.25 % |
| filename-lexical-1.hyblex | 2 dictionary: posting start + count (2 x u64) | 160,016 | 32.7 % | 0.50 % |
| filename-lexical-1.hyblex | 2 dictionary: term bytes | 50,003 | 10.2 % | 0.15 % |
| filename-lexical-1.hyblex | 3 postings: document index (u32) | 80,000 | 16.3 % | 0.25 % |
| filename-lexical-1.hyblex | 3 postings: term frequency (u32) | 80,000 | 16.3 % | 0.25 % |
| filename-lexical-1.hyblex | **total** | **490,091** | 100 % | 1.52 % |
| MANIFEST | whole file | 696 | 100.0 % | 0.00 % |
| MANIFEST | **total** | **696** | 100 % | 0.00 % |
| INDEX-STATE.json | whole file | 94 | 100.0 % | 0.00 % |
| INDEX-STATE.json | **total** | **94** | 100 % | 0.00 % |

### prose-1k

| File | Part | Bytes | Share of file | Share of index |
| --- | --- | ---: | ---: | ---: |
| documents-1.hybseg | header | 36 | 0.0 % | 0.00 % |
| documents-1.hybseg | record lengths (id, path, text, vector, labels, section path: 6 x u32) | 43,656 | 2.2 % | 0.63 % |
| documents-1.hybseg | record lines (start, end, heading: 3 x u32) | 21,828 | 1.1 % | 0.32 % |
| documents-1.hybseg | record chunker index and section depth (2 x u16) | 7,276 | 0.4 % | 0.11 % |
| documents-1.hybseg | record source_doc_index (u32) | 7,276 | 0.4 % | 0.11 % |
| documents-1.hybseg | chunk ids (20 hex) | 36,380 | 1.9 % | 0.53 % |
| documents-1.hybseg | paths | 59,369 | 3.0 % | 0.86 % |
| documents-1.hybseg | chunk text | 1,732,149 | 88.8 % | 25.08 % |
| documents-1.hybseg | required labels | 0 | 0.0 % | 0.00 % |
| documents-1.hybseg | vectors | 0 | 0.0 % | 0.00 % |
| documents-1.hybseg | section paths (heading texts) | 41,590 | 2.1 % | 0.60 % |
| documents-1.hybseg | **total** | **1,949,560** | 100 % | 28.22 % |
| lexical-1.hyblex | header | 80 | 0.0 % | 0.00 % |
| lexical-1.hyblex | 1 document lengths (u32 each) | 7,276 | 0.3 % | 0.11 % |
| lexical-1.hyblex | 2 dictionary: term length + df (2 x u32) | 24,920 | 0.9 % | 0.36 % |
| lexical-1.hyblex | 2 dictionary: posting start + count (2 x u64) | 49,840 | 1.8 % | 0.72 % |
| lexical-1.hyblex | 2 dictionary: term bytes | 19,973 | 0.7 % | 0.29 % |
| lexical-1.hyblex | 3 postings: document index (u32) | 869,876 | 30.6 % | 12.59 % |
| lexical-1.hyblex | 3 postings: term frequency (u32) | 869,876 | 30.6 % | 12.59 % |
| lexical-1.hyblex | 4 positions: first ordinal per posting (varint) | 274,844 | 9.7 % | 3.98 % |
| lexical-1.hyblex | 4 positions: later ordinal gaps (varints) | 97,411 | 3.4 % | 1.41 % |
| lexical-1.hyblex | 5 offsets: token count per document (u32) | 7,276 | 0.3 % | 0.11 % |
| lexical-1.hyblex | 5 offsets: start gap varints | 310,043 | 10.9 % | 4.49 % |
| lexical-1.hyblex | 5 offsets: length varints | 310,043 | 10.9 % | 4.49 % |
| lexical-1.hyblex | **total** | **2,841,458** | 100 % | 41.14 % |
| source-1.hybsrc | header | 48 | 0.0 % | 0.00 % |
| source-1.hybsrc | file table: offsets, lengths, line count (u32 + 3 x u64 + u32) | 32,000 | 1.8 % | 0.46 % |
| source-1.hybsrc | file table: sha256 (32 bytes) | 32,000 | 1.8 % | 0.46 % |
| source-1.hybsrc | file table: encoding + reserved (4 bytes) | 4,000 | 0.2 % | 0.06 % |
| source-1.hybsrc | file table: paths | 32,678 | 1.8 % | 0.47 % |
| source-1.hybsrc | line maps (varints) | 27,141 | 1.5 % | 0.39 % |
| source-1.hybsrc | text (original file bytes) | 1,676,925 | 92.9 % | 24.28 % |
| source-1.hybsrc | **total** | **1,804,792** | 100 % | 26.13 % |
| state-1.hybstate | header | 32 | 0.0 % | 0.00 % |
| state-1.hybstate | payload header | 40 | 0.0 % | 0.00 % |
| state-1.hybstate | string table | 63 | 0.1 % | 0.00 % |
| state-1.hybstate | roots (24 bytes each) | 24 | 0.0 % | 0.00 % |
| state-1.hybstate | file records: sha256 (32 bytes) | 32,000 | 29.4 % | 0.46 % |
| state-1.hybstate | file records: root, flags, size, mtime, chunks, chunker, labels, lengths (44 bytes) | 44,000 | 40.4 % | 0.64 % |
| state-1.hybstate | label references | 0 | 0.0 % | 0.00 % |
| state-1.hybstate | paths (and moved_from) | 32,678 | 30.0 % | 0.47 % |
| state-1.hybstate | **total** | **108,837** | 100 % | 1.58 % |
| filenames-1.hybseg | header | 36 | 0.0 % | 0.00 % |
| filenames-1.hybseg | record lengths (id, path, text, vector, labels: 5 x u32) | 20,000 | 19.4 % | 0.29 % |
| filenames-1.hybseg | record lines (start, end: 2 x u32) | 8,000 | 7.8 % | 0.12 % |
| filenames-1.hybseg | chunk ids (20 hex) | 20,000 | 19.4 % | 0.29 % |
| filenames-1.hybseg | paths | 32,678 | 31.7 % | 0.47 % |
| filenames-1.hybseg | chunk text | 22,278 | 21.6 % | 0.32 % |
| filenames-1.hybseg | required labels | 0 | 0.0 % | 0.00 % |
| filenames-1.hybseg | vectors | 0 | 0.0 % | 0.00 % |
| filenames-1.hybseg | section paths (heading texts) | 0 | 0.0 % | 0.00 % |
| filenames-1.hybseg | **total** | **102,992** | 100 % | 1.49 % |
| filename-lexical-1.hyblex | header | 64 | 0.1 % | 0.00 % |
| filename-lexical-1.hyblex | 1 document lengths (u32 each) | 4,000 | 4.0 % | 0.06 % |
| filename-lexical-1.hyblex | 2 dictionary: term length + df (2 x u32) | 18,048 | 18.2 % | 0.26 % |
| filename-lexical-1.hyblex | 2 dictionary: posting start + count (2 x u64) | 36,096 | 36.4 % | 0.52 % |
| filename-lexical-1.hyblex | 2 dictionary: term bytes | 12,845 | 13.0 % | 0.19 % |
| filename-lexical-1.hyblex | 3 postings: document index (u32) | 14,000 | 14.1 % | 0.20 % |
| filename-lexical-1.hyblex | 3 postings: term frequency (u32) | 14,000 | 14.1 % | 0.20 % |
| filename-lexical-1.hyblex | **total** | **99,053** | 100 % | 1.43 % |
| MANIFEST | whole file | 696 | 100.0 % | 0.01 % |
| MANIFEST | **total** | **696** | 100 % | 0.01 % |
| INDEX-STATE.json | whole file | 94 | 100.0 % | 0.00 % |
| INDEX-STATE.json | **total** | **94** | 100 % | 0.00 % |

### prose-10k

| File | Part | Bytes | Share of file | Share of index |
| --- | --- | ---: | ---: | ---: |
| documents-1.hybseg | header | 36 | 0.0 % | 0.00 % |
| documents-1.hybseg | record lengths (id, path, text, vector, labels, section path: 6 x u32) | 450,384 | 2.2 % | 0.65 % |
| documents-1.hybseg | record lines (start, end, heading: 3 x u32) | 225,192 | 1.1 % | 0.32 % |
| documents-1.hybseg | record chunker index and section depth (2 x u16) | 75,064 | 0.4 % | 0.11 % |
| documents-1.hybseg | record source_doc_index (u32) | 75,064 | 0.4 % | 0.11 % |
| documents-1.hybseg | chunk ids (20 hex) | 375,320 | 1.9 % | 0.54 % |
| documents-1.hybseg | paths | 615,294 | 3.1 % | 0.88 % |
| documents-1.hybseg | chunk text | 17,818,611 | 88.8 % | 25.54 % |
| documents-1.hybseg | required labels | 0 | 0.0 % | 0.00 % |
| documents-1.hybseg | vectors | 0 | 0.0 % | 0.00 % |
| documents-1.hybseg | section paths (heading texts) | 436,947 | 2.2 % | 0.63 % |
| documents-1.hybseg | **total** | **20,071,912** | 100 % | 28.77 % |
| lexical-1.hyblex | header | 80 | 0.0 % | 0.00 % |
| lexical-1.hyblex | 1 document lengths (u32 each) | 75,064 | 0.3 % | 0.11 % |
| lexical-1.hyblex | 2 dictionary: term length + df (2 x u32) | 24,920 | 0.1 % | 0.04 % |
| lexical-1.hyblex | 2 dictionary: posting start + count (2 x u64) | 49,840 | 0.2 % | 0.07 % |
| lexical-1.hyblex | 2 dictionary: term bytes | 19,973 | 0.1 % | 0.03 % |
| lexical-1.hyblex | 3 postings: document index (u32) | 8,954,164 | 31.6 % | 12.83 % |
| lexical-1.hyblex | 3 postings: term frequency (u32) | 8,954,164 | 31.6 % | 12.83 % |
| lexical-1.hyblex | 4 positions: first ordinal per posting (varint) | 2,833,310 | 10.0 % | 4.06 % |
| lexical-1.hyblex | 4 positions: later ordinal gaps (varints) | 998,015 | 3.5 % | 1.43 % |
| lexical-1.hyblex | 5 offsets: token count per document (u32) | 75,064 | 0.3 % | 0.11 % |
| lexical-1.hyblex | 5 offsets: start gap varints | 3,186,965 | 11.2 % | 4.57 % |
| lexical-1.hyblex | 5 offsets: length varints | 3,186,965 | 11.2 % | 4.57 % |
| lexical-1.hyblex | **total** | **28,358,524** | 100 % | 40.64 % |
| source-1.hybsrc | header | 48 | 0.0 % | 0.00 % |
| source-1.hybsrc | file table: offsets, lengths, line count (u32 + 3 x u64 + u32) | 320,000 | 1.7 % | 0.46 % |
| source-1.hybsrc | file table: sha256 (32 bytes) | 320,000 | 1.7 % | 0.46 % |
| source-1.hybsrc | file table: encoding + reserved (4 bytes) | 40,000 | 0.2 % | 0.06 % |
| source-1.hybsrc | file table: paths | 327,531 | 1.8 % | 0.47 % |
| source-1.hybsrc | line maps (varints) | 277,431 | 1.5 % | 0.40 % |
| source-1.hybsrc | text (original file bytes) | 17,244,024 | 93.1 % | 24.71 % |
| source-1.hybsrc | **total** | **18,529,034** | 100 % | 26.55 % |
| state-1.hybstate | header | 32 | 0.0 % | 0.00 % |
| state-1.hybstate | payload header | 40 | 0.0 % | 0.00 % |
| state-1.hybstate | string table | 63 | 0.0 % | 0.00 % |
| state-1.hybstate | roots (24 bytes each) | 24 | 0.0 % | 0.00 % |
| state-1.hybstate | file records: sha256 (32 bytes) | 320,000 | 29.4 % | 0.46 % |
| state-1.hybstate | file records: root, flags, size, mtime, chunks, chunker, labels, lengths (44 bytes) | 440,000 | 40.5 % | 0.63 % |
| state-1.hybstate | label references | 0 | 0.0 % | 0.00 % |
| state-1.hybstate | paths (and moved_from) | 327,531 | 30.1 % | 0.47 % |
| state-1.hybstate | **total** | **1,087,690** | 100 % | 1.56 % |
| filenames-1.hybseg | header | 36 | 0.0 % | 0.00 % |
| filenames-1.hybseg | record lengths (id, path, text, vector, labels: 5 x u32) | 200,000 | 19.4 % | 0.29 % |
| filenames-1.hybseg | record lines (start, end: 2 x u32) | 80,000 | 7.8 % | 0.11 % |
| filenames-1.hybseg | chunk ids (20 hex) | 200,000 | 19.4 % | 0.29 % |
| filenames-1.hybseg | paths | 327,531 | 31.8 % | 0.47 % |
| filenames-1.hybseg | chunk text | 223,531 | 21.7 % | 0.32 % |
| filenames-1.hybseg | required labels | 0 | 0.0 % | 0.00 % |
| filenames-1.hybseg | vectors | 0 | 0.0 % | 0.00 % |
| filenames-1.hybseg | section paths (heading texts) | 0 | 0.0 % | 0.00 % |
| filenames-1.hybseg | **total** | **1,031,098** | 100 % | 1.48 % |
| filename-lexical-1.hyblex | header | 64 | 0.0 % | 0.00 % |
| filename-lexical-1.hyblex | 1 document lengths (u32 each) | 40,000 | 5.7 % | 0.06 % |
| filename-lexical-1.hyblex | 2 dictionary: term length + df (2 x u32) | 103,304 | 14.8 % | 0.15 % |
| filename-lexical-1.hyblex | 2 dictionary: posting start + count (2 x u64) | 206,608 | 29.5 % | 0.30 % |
| filename-lexical-1.hyblex | 2 dictionary: term bytes | 68,793 | 9.8 % | 0.10 % |
| filename-lexical-1.hyblex | 3 postings: document index (u32) | 140,264 | 20.1 % | 0.20 % |
| filename-lexical-1.hyblex | 3 postings: term frequency (u32) | 140,264 | 20.1 % | 0.20 % |
| filename-lexical-1.hyblex | **total** | **699,297** | 100 % | 1.00 % |
| MANIFEST | whole file | 696 | 100.0 % | 0.00 % |
| MANIFEST | **total** | **696** | 100 % | 0.00 % |
| INDEX-STATE.json | whole file | 94 | 100.0 % | 0.00 % |
| INDEX-STATE.json | **total** | **94** | 100 % | 0.00 % |

### tamil-1k

| File | Part | Bytes | Share of file | Share of index |
| --- | --- | ---: | ---: | ---: |
| documents-1.hybseg | header | 36 | 0.0 % | 0.00 % |
| documents-1.hybseg | record lengths (id, path, text, vector, labels, section path: 6 x u32) | 47,112 | 1.4 % | 0.49 % |
| documents-1.hybseg | record lines (start, end, heading: 3 x u32) | 23,556 | 0.7 % | 0.25 % |
| documents-1.hybseg | record chunker index and section depth (2 x u16) | 7,852 | 0.2 % | 0.08 % |
| documents-1.hybseg | record source_doc_index (u32) | 7,852 | 0.2 % | 0.08 % |
| documents-1.hybseg | chunk ids (20 hex) | 39,260 | 1.1 % | 0.41 % |
| documents-1.hybseg | paths | 41,223 | 1.2 % | 0.43 % |
| documents-1.hybseg | chunk text | 3,247,776 | 93.3 % | 34.11 % |
| documents-1.hybseg | required labels | 0 | 0.0 % | 0.00 % |
| documents-1.hybseg | vectors | 0 | 0.0 % | 0.00 % |
| documents-1.hybseg | section paths (heading texts) | 65,251 | 1.9 % | 0.69 % |
| documents-1.hybseg | **total** | **3,479,918** | 100 % | 36.55 % |
| lexical-1.hyblex | header | 80 | 0.0 % | 0.00 % |
| lexical-1.hyblex | 1 document lengths (u32 each) | 7,852 | 0.3 % | 0.08 % |
| lexical-1.hyblex | 2 dictionary: term length + df (2 x u32) | 172,800 | 7.0 % | 1.81 % |
| lexical-1.hyblex | 2 dictionary: posting start + count (2 x u64) | 345,600 | 14.0 % | 3.63 % |
| lexical-1.hyblex | 2 dictionary: term bytes | 588,843 | 23.9 % | 6.18 % |
| lexical-1.hyblex | 3 postings: document index (u32) | 474,852 | 19.3 % | 4.99 % |
| lexical-1.hyblex | 3 postings: term frequency (u32) | 474,852 | 19.3 % | 4.99 % |
| lexical-1.hyblex | 4 positions: first ordinal per posting (varint) | 118,713 | 4.8 % | 1.25 % |
| lexical-1.hyblex | 4 positions: later ordinal gaps (varints) | 11,777 | 0.5 % | 0.12 % |
| lexical-1.hyblex | 5 offsets: token count per document (u32) | 7,852 | 0.3 % | 0.08 % |
| lexical-1.hyblex | 5 offsets: start gap varints | 130,490 | 5.3 % | 1.37 % |
| lexical-1.hyblex | 5 offsets: length varints | 130,490 | 5.3 % | 1.37 % |
| lexical-1.hyblex | **total** | **2,464,201** | 100 % | 25.88 % |
| source-1.hybsrc | header | 48 | 0.0 % | 0.00 % |
| source-1.hybsrc | file table: offsets, lengths, line count (u32 + 3 x u64 + u32) | 32,000 | 1.0 % | 0.34 % |
| source-1.hybsrc | file table: sha256 (32 bytes) | 32,000 | 1.0 % | 0.34 % |
| source-1.hybsrc | file table: encoding + reserved (4 bytes) | 4,000 | 0.1 % | 0.04 % |
| source-1.hybsrc | file table: paths | 21,000 | 0.6 % | 0.22 % |
| source-1.hybsrc | line maps (varints) | 12,815 | 0.4 % | 0.13 % |
| source-1.hybsrc | text (original file bytes) | 3,250,702 | 97.0 % | 34.14 % |
| source-1.hybsrc | **total** | **3,352,565** | 100 % | 35.21 % |
| state-1.hybstate | header | 32 | 0.0 % | 0.00 % |
| state-1.hybstate | payload header | 40 | 0.0 % | 0.00 % |
| state-1.hybstate | string table | 63 | 0.1 % | 0.00 % |
| state-1.hybstate | roots (24 bytes each) | 24 | 0.0 % | 0.00 % |
| state-1.hybstate | file records: sha256 (32 bytes) | 32,000 | 32.9 % | 0.34 % |
| state-1.hybstate | file records: root, flags, size, mtime, chunks, chunker, labels, lengths (44 bytes) | 44,000 | 45.3 % | 0.46 % |
| state-1.hybstate | label references | 0 | 0.0 % | 0.00 % |
| state-1.hybstate | paths (and moved_from) | 21,000 | 21.6 % | 0.22 % |
| state-1.hybstate | **total** | **97,159** | 100 % | 1.02 % |
| filenames-1.hybseg | header | 36 | 0.0 % | 0.00 % |
| filenames-1.hybseg | record lengths (id, path, text, vector, labels: 5 x u32) | 20,000 | 25.6 % | 0.21 % |
| filenames-1.hybseg | record lines (start, end: 2 x u32) | 8,000 | 10.3 % | 0.08 % |
| filenames-1.hybseg | chunk ids (20 hex) | 20,000 | 25.6 % | 0.21 % |
| filenames-1.hybseg | paths | 21,000 | 26.9 % | 0.22 % |
| filenames-1.hybseg | chunk text | 9,000 | 11.5 % | 0.09 % |
| filenames-1.hybseg | required labels | 0 | 0.0 % | 0.00 % |
| filenames-1.hybseg | vectors | 0 | 0.0 % | 0.00 % |
| filenames-1.hybseg | section paths (heading texts) | 0 | 0.0 % | 0.00 % |
| filenames-1.hybseg | **total** | **78,036** | 100 % | 0.82 % |
| filename-lexical-1.hyblex | header | 64 | 0.1 % | 0.00 % |
| filename-lexical-1.hyblex | 1 document lengths (u32 each) | 4,000 | 8.1 % | 0.04 % |
| filename-lexical-1.hyblex | 2 dictionary: term length + df (2 x u32) | 8,008 | 16.3 % | 0.08 % |
| filename-lexical-1.hyblex | 2 dictionary: posting start + count (2 x u64) | 16,016 | 32.6 % | 0.17 % |
| filename-lexical-1.hyblex | 2 dictionary: term bytes | 5,003 | 10.2 % | 0.05 % |
| filename-lexical-1.hyblex | 3 postings: document index (u32) | 8,000 | 16.3 % | 0.08 % |
| filename-lexical-1.hyblex | 3 postings: term frequency (u32) | 8,000 | 16.3 % | 0.08 % |
| filename-lexical-1.hyblex | **total** | **49,091** | 100 % | 0.52 % |
| MANIFEST | whole file | 696 | 100.0 % | 0.01 % |
| MANIFEST | **total** | **696** | 100 % | 0.01 % |
| INDEX-STATE.json | whole file | 94 | 100.0 % | 0.00 % |
| INDEX-STATE.json | **total** | **94** | 100 % | 0.00 % |

### tamil-10k

| File | Part | Bytes | Share of file | Share of index |
| --- | --- | ---: | ---: | ---: |
| documents-1.hybseg | header | 36 | 0.0 % | 0.00 % |
| documents-1.hybseg | record lengths (id, path, text, vector, labels, section path: 6 x u32) | 478,704 | 1.6 % | 0.65 % |
| documents-1.hybseg | record lines (start, end, heading: 3 x u32) | 239,352 | 0.8 % | 0.32 % |
| documents-1.hybseg | record chunker index and section depth (2 x u16) | 79,784 | 0.3 % | 0.11 % |
| documents-1.hybseg | record source_doc_index (u32) | 79,784 | 0.3 % | 0.11 % |
| documents-1.hybseg | chunk ids (20 hex) | 398,920 | 1.3 % | 0.54 % |
| documents-1.hybseg | paths | 418,866 | 1.4 % | 0.57 % |
| documents-1.hybseg | chunk text | 27,678,565 | 92.1 % | 37.49 % |
| documents-1.hybseg | required labels | 0 | 0.0 % | 0.00 % |
| documents-1.hybseg | vectors | 0 | 0.0 % | 0.00 % |
| documents-1.hybseg | section paths (heading texts) | 663,008 | 2.2 % | 0.90 % |
| documents-1.hybseg | **total** | **30,037,019** | 100 % | 40.68 % |
| lexical-1.hyblex | header | 80 | 0.0 % | 0.00 % |
| lexical-1.hyblex | 1 document lengths (u32 each) | 79,784 | 0.6 % | 0.11 % |
| lexical-1.hyblex | 2 dictionary: term length + df (2 x u32) | 172,800 | 1.3 % | 0.23 % |
| lexical-1.hyblex | 2 dictionary: posting start + count (2 x u64) | 345,600 | 2.7 % | 0.47 % |
| lexical-1.hyblex | 2 dictionary: term bytes | 588,843 | 4.6 % | 0.80 % |
| lexical-1.hyblex | 3 postings: document index (u32) | 4,076,248 | 31.8 % | 5.52 % |
| lexical-1.hyblex | 3 postings: term frequency (u32) | 4,076,248 | 31.8 % | 5.52 % |
| lexical-1.hyblex | 4 positions: first ordinal per posting (varint) | 1,019,062 | 7.9 % | 1.38 % |
| lexical-1.hyblex | 4 positions: later ordinal gaps (varints) | 119,496 | 0.9 % | 0.16 % |
| lexical-1.hyblex | 5 offsets: token count per document (u32) | 79,784 | 0.6 % | 0.11 % |
| lexical-1.hyblex | 5 offsets: start gap varints | 1,138,558 | 8.9 % | 1.54 % |
| lexical-1.hyblex | 5 offsets: length varints | 1,138,558 | 8.9 % | 1.54 % |
| lexical-1.hyblex | **total** | **12,835,061** | 100 % | 17.38 % |
| source-1.hybsrc | header | 48 | 0.0 % | 0.00 % |
| source-1.hybsrc | file table: offsets, lengths, line count (u32 + 3 x u64 + u32) | 320,000 | 1.1 % | 0.43 % |
| source-1.hybsrc | file table: sha256 (32 bytes) | 320,000 | 1.1 % | 0.43 % |
| source-1.hybsrc | file table: encoding + reserved (4 bytes) | 40,000 | 0.1 % | 0.05 % |
| source-1.hybsrc | file table: paths | 210,000 | 0.7 % | 0.28 % |
| source-1.hybsrc | line maps (varints) | 119,730 | 0.4 % | 0.16 % |
| source-1.hybsrc | text (original file bytes) | 27,708,457 | 96.5 % | 37.53 % |
| source-1.hybsrc | **total** | **28,718,235** | 100 % | 38.90 % |
| state-1.hybstate | header | 32 | 0.0 % | 0.00 % |
| state-1.hybstate | payload header | 40 | 0.0 % | 0.00 % |
| state-1.hybstate | string table | 63 | 0.0 % | 0.00 % |
| state-1.hybstate | roots (24 bytes each) | 24 | 0.0 % | 0.00 % |
| state-1.hybstate | file records: sha256 (32 bytes) | 320,000 | 33.0 % | 0.43 % |
| state-1.hybstate | file records: root, flags, size, mtime, chunks, chunker, labels, lengths (44 bytes) | 440,000 | 45.4 % | 0.60 % |
| state-1.hybstate | label references | 0 | 0.0 % | 0.00 % |
| state-1.hybstate | paths (and moved_from) | 210,000 | 21.6 % | 0.28 % |
| state-1.hybstate | **total** | **970,159** | 100 % | 1.31 % |
| filenames-1.hybseg | header | 36 | 0.0 % | 0.00 % |
| filenames-1.hybseg | record lengths (id, path, text, vector, labels: 5 x u32) | 200,000 | 25.6 % | 0.27 % |
| filenames-1.hybseg | record lines (start, end: 2 x u32) | 80,000 | 10.3 % | 0.11 % |
| filenames-1.hybseg | chunk ids (20 hex) | 200,000 | 25.6 % | 0.27 % |
| filenames-1.hybseg | paths | 210,000 | 26.9 % | 0.28 % |
| filenames-1.hybseg | chunk text | 90,000 | 11.5 % | 0.12 % |
| filenames-1.hybseg | required labels | 0 | 0.0 % | 0.00 % |
| filenames-1.hybseg | vectors | 0 | 0.0 % | 0.00 % |
| filenames-1.hybseg | section paths (heading texts) | 0 | 0.0 % | 0.00 % |
| filenames-1.hybseg | **total** | **780,036** | 100 % | 1.06 % |
| filename-lexical-1.hyblex | header | 64 | 0.0 % | 0.00 % |
| filename-lexical-1.hyblex | 1 document lengths (u32 each) | 40,000 | 8.2 % | 0.05 % |
| filename-lexical-1.hyblex | 2 dictionary: term length + df (2 x u32) | 80,008 | 16.3 % | 0.11 % |
| filename-lexical-1.hyblex | 2 dictionary: posting start + count (2 x u64) | 160,016 | 32.7 % | 0.22 % |
| filename-lexical-1.hyblex | 2 dictionary: term bytes | 50,003 | 10.2 % | 0.07 % |
| filename-lexical-1.hyblex | 3 postings: document index (u32) | 80,000 | 16.3 % | 0.11 % |
| filename-lexical-1.hyblex | 3 postings: term frequency (u32) | 80,000 | 16.3 % | 0.11 % |
| filename-lexical-1.hyblex | **total** | **490,091** | 100 % | 0.66 % |
| MANIFEST | whole file | 696 | 100.0 % | 0.00 % |
| MANIFEST | **total** | **696** | 100 % | 0.00 % |
| INDEX-STATE.json | whole file | 94 | 100.0 % | 0.00 % |
| INDEX-STATE.json | **total** | **94** | 100 % | 0.00 % |

### fixtures

| File | Part | Bytes | Share of file | Share of index |
| --- | --- | ---: | ---: | ---: |
| documents-1.hybseg | header | 36 | 0.0 % | 0.00 % |
| documents-1.hybseg | record lengths (id, path, text, vector, labels, section path: 6 x u32) | 98,016 | 1.8 % | 0.56 % |
| documents-1.hybseg | record lines (start, end, heading: 3 x u32) | 49,008 | 0.9 % | 0.28 % |
| documents-1.hybseg | record chunker index and section depth (2 x u16) | 16,336 | 0.3 % | 0.09 % |
| documents-1.hybseg | record source_doc_index (u32) | 16,336 | 0.3 % | 0.09 % |
| documents-1.hybseg | chunk ids (20 hex) | 81,680 | 1.5 % | 0.47 % |
| documents-1.hybseg | paths | 96,926 | 1.7 % | 0.55 % |
| documents-1.hybseg | chunk text | 5,225,049 | 93.4 % | 29.86 % |
| documents-1.hybseg | required labels | 0 | 0.0 % | 0.00 % |
| documents-1.hybseg | vectors | 0 | 0.0 % | 0.00 % |
| documents-1.hybseg | section paths (heading texts) | 13,761 | 0.2 % | 0.08 % |
| documents-1.hybseg | **total** | **5,597,148** | 100 % | 31.98 % |
| lexical-1.hyblex | header | 80 | 0.0 % | 0.00 % |
| lexical-1.hyblex | 1 document lengths (u32 each) | 16,336 | 0.2 % | 0.09 % |
| lexical-1.hyblex | 2 dictionary: term length + df (2 x u32) | 544,592 | 7.8 % | 3.11 % |
| lexical-1.hyblex | 2 dictionary: posting start + count (2 x u64) | 1,089,184 | 15.5 % | 6.22 % |
| lexical-1.hyblex | 2 dictionary: term bytes | 452,466 | 6.4 % | 2.59 % |
| lexical-1.hyblex | 3 postings: document index (u32) | 1,519,496 | 21.6 % | 8.68 % |
| lexical-1.hyblex | 3 postings: term frequency (u32) | 1,519,496 | 21.6 % | 8.68 % |
| lexical-1.hyblex | 4 positions: first ordinal per posting (varint) | 480,780 | 6.8 % | 2.75 % |
| lexical-1.hyblex | 4 positions: later ordinal gaps (varints) | 213,928 | 3.0 % | 1.22 % |
| lexical-1.hyblex | 5 offsets: token count per document (u32) | 16,336 | 0.2 % | 0.09 % |
| lexical-1.hyblex | 5 offsets: start gap varints | 584,511 | 8.3 % | 3.34 % |
| lexical-1.hyblex | 5 offsets: length varints | 584,504 | 8.3 % | 3.34 % |
| lexical-1.hyblex | **total** | **7,021,709** | 100 % | 40.13 % |
| source-1.hybsrc | header | 48 | 0.0 % | 0.00 % |
| source-1.hybsrc | file table: offsets, lengths, line count (u32 + 3 x u64 + u32) | 7,424 | 0.2 % | 0.04 % |
| source-1.hybsrc | file table: sha256 (32 bytes) | 7,424 | 0.2 % | 0.04 % |
| source-1.hybsrc | file table: encoding + reserved (4 bytes) | 928 | 0.0 % | 0.01 % |
| source-1.hybsrc | file table: paths | 6,996 | 0.1 % | 0.04 % |
| source-1.hybsrc | line maps (varints) | 163,464 | 3.4 % | 0.93 % |
| source-1.hybsrc | text (original file bytes) | 4,635,177 | 96.1 % | 26.49 % |
| source-1.hybsrc | **total** | **4,821,461** | 100 % | 27.55 % |
| state-1.hybstate | header | 32 | 0.1 % | 0.00 % |
| state-1.hybstate | payload header | 40 | 0.2 % | 0.00 % |
| state-1.hybstate | string table | 81 | 0.3 % | 0.00 % |
| state-1.hybstate | roots (24 bytes each) | 24 | 0.1 % | 0.00 % |
| state-1.hybstate | file records: sha256 (32 bytes) | 7,424 | 29.9 % | 0.04 % |
| state-1.hybstate | file records: root, flags, size, mtime, chunks, chunker, labels, lengths (44 bytes) | 10,208 | 41.2 % | 0.06 % |
| state-1.hybstate | label references | 0 | 0.0 % | 0.00 % |
| state-1.hybstate | paths (and moved_from) | 6,996 | 28.2 % | 0.04 % |
| state-1.hybstate | **total** | **24,805** | 100 % | 0.14 % |
| filenames-1.hybseg | header | 36 | 0.2 % | 0.00 % |
| filenames-1.hybseg | record lengths (id, path, text, vector, labels: 5 x u32) | 4,560 | 22.2 % | 0.03 % |
| filenames-1.hybseg | record lines (start, end: 2 x u32) | 1,824 | 8.9 % | 0.01 % |
| filenames-1.hybseg | chunk ids (20 hex) | 4,560 | 22.2 % | 0.03 % |
| filenames-1.hybseg | paths | 6,897 | 33.5 % | 0.04 % |
| filenames-1.hybseg | chunk text | 2,689 | 13.1 % | 0.02 % |
| filenames-1.hybseg | required labels | 0 | 0.0 % | 0.00 % |
| filenames-1.hybseg | vectors | 0 | 0.0 % | 0.00 % |
| filenames-1.hybseg | section paths (heading texts) | 0 | 0.0 % | 0.00 % |
| filenames-1.hybseg | **total** | **20,566** | 100 % | 0.12 % |
| filename-lexical-1.hyblex | header | 64 | 0.5 % | 0.00 % |
| filename-lexical-1.hyblex | 1 document lengths (u32 each) | 912 | 7.3 % | 0.01 % |
| filename-lexical-1.hyblex | 2 dictionary: term length + df (2 x u32) | 2,192 | 17.4 % | 0.01 % |
| filename-lexical-1.hyblex | 2 dictionary: posting start + count (2 x u64) | 4,384 | 34.9 % | 0.03 % |
| filename-lexical-1.hyblex | 2 dictionary: term bytes | 1,623 | 12.9 % | 0.01 % |
| filename-lexical-1.hyblex | 3 postings: document index (u32) | 1,696 | 13.5 % | 0.01 % |
| filename-lexical-1.hyblex | 3 postings: term frequency (u32) | 1,696 | 13.5 % | 0.01 % |
| filename-lexical-1.hyblex | **total** | **12,567** | 100 % | 0.07 % |
| MANIFEST | whole file | 1,062 | 100.0 % | 0.01 % |
| MANIFEST | **total** | **1,062** | 100 % | 0.01 % |
| INDEX-STATE.json | whole file | 94 | 100.0 % | 0.00 % |
| INDEX-STATE.json | **total** | **94** | 100 % | 0.00 % |

### family

| File | Part | Bytes | Share of file | Share of index |
| --- | --- | ---: | ---: | ---: |
| documents-1.hybseg | header | 36 | 0.0 % | 0.00 % |
| documents-1.hybseg | record lengths (id, path, text, vector, labels, section path: 6 x u32) | 25,512 | 1.7 % | 0.45 % |
| documents-1.hybseg | record lines (start, end, heading: 3 x u32) | 12,756 | 0.8 % | 0.23 % |
| documents-1.hybseg | record chunker index and section depth (2 x u16) | 4,252 | 0.3 % | 0.08 % |
| documents-1.hybseg | record source_doc_index (u32) | 4,252 | 0.3 % | 0.08 % |
| documents-1.hybseg | chunk ids (20 hex) | 21,260 | 1.4 % | 0.38 % |
| documents-1.hybseg | paths | 19,305 | 1.3 % | 0.34 % |
| documents-1.hybseg | chunk text | 1,427,521 | 94.0 % | 25.39 % |
| documents-1.hybseg | required labels | 0 | 0.0 % | 0.00 % |
| documents-1.hybseg | vectors | 0 | 0.0 % | 0.00 % |
| documents-1.hybseg | section paths (heading texts) | 4,194 | 0.3 % | 0.07 % |
| documents-1.hybseg | **total** | **1,519,088** | 100 % | 27.02 % |
| lexical-1.hyblex | header | 80 | 0.0 % | 0.00 % |
| lexical-1.hyblex | 1 document lengths (u32 each) | 4,252 | 0.2 % | 0.08 % |
| lexical-1.hyblex | 2 dictionary: term length + df (2 x u32) | 140,096 | 5.0 % | 2.49 % |
| lexical-1.hyblex | 2 dictionary: posting start + count (2 x u64) | 280,192 | 9.9 % | 4.98 % |
| lexical-1.hyblex | 2 dictionary: term bytes | 88,994 | 3.1 % | 1.58 % |
| lexical-1.hyblex | 3 postings: document index (u32) | 762,432 | 26.9 % | 13.56 % |
| lexical-1.hyblex | 3 postings: term frequency (u32) | 762,432 | 26.9 % | 13.56 % |
| lexical-1.hyblex | 4 positions: first ordinal per posting (varint) | 275,317 | 9.7 % | 4.90 % |
| lexical-1.hyblex | 4 positions: later ordinal gaps (varints) | 48,713 | 1.7 % | 0.87 % |
| lexical-1.hyblex | 5 offsets: token count per document (u32) | 4,252 | 0.2 % | 0.08 % |
| lexical-1.hyblex | 5 offsets: start gap varints | 231,422 | 8.2 % | 4.12 % |
| lexical-1.hyblex | 5 offsets: length varints | 231,422 | 8.2 % | 4.12 % |
| lexical-1.hyblex | **total** | **2,829,604** | 100 % | 50.33 % |
| source-1.hybsrc | header | 48 | 0.0 % | 0.00 % |
| source-1.hybsrc | file table: offsets, lengths, line count (u32 + 3 x u64 + u32) | 1,472 | 0.1 % | 0.03 % |
| source-1.hybsrc | file table: sha256 (32 bytes) | 1,472 | 0.1 % | 0.03 % |
| source-1.hybsrc | file table: encoding + reserved (4 bytes) | 184 | 0.0 % | 0.00 % |
| source-1.hybsrc | file table: paths | 953 | 0.1 % | 0.02 % |
| source-1.hybsrc | line maps (varints) | 19,479 | 1.5 % | 0.35 % |
| source-1.hybsrc | text (original file bytes) | 1,237,342 | 98.1 % | 22.01 % |
| source-1.hybsrc | **total** | **1,260,950** | 100 % | 22.43 % |
| state-1.hybstate | header | 32 | 0.7 % | 0.00 % |
| state-1.hybstate | payload header | 40 | 0.9 % | 0.00 % |
| state-1.hybstate | string table | 81 | 1.8 % | 0.00 % |
| state-1.hybstate | roots (24 bytes each) | 24 | 0.5 % | 0.00 % |
| state-1.hybstate | file records: sha256 (32 bytes) | 1,472 | 31.8 % | 0.03 % |
| state-1.hybstate | file records: root, flags, size, mtime, chunks, chunker, labels, lengths (44 bytes) | 2,024 | 43.8 % | 0.04 % |
| state-1.hybstate | label references | 0 | 0.0 % | 0.00 % |
| state-1.hybstate | paths (and moved_from) | 953 | 20.6 % | 0.02 % |
| state-1.hybstate | **total** | **4,626** | 100 % | 0.08 % |
| filenames-1.hybseg | header | 36 | 1.0 % | 0.00 % |
| filenames-1.hybseg | record lengths (id, path, text, vector, labels: 5 x u32) | 900 | 24.9 % | 0.02 % |
| filenames-1.hybseg | record lines (start, end: 2 x u32) | 360 | 9.9 % | 0.01 % |
| filenames-1.hybseg | chunk ids (20 hex) | 900 | 24.9 % | 0.02 % |
| filenames-1.hybseg | paths | 939 | 25.9 % | 0.02 % |
| filenames-1.hybseg | chunk text | 486 | 13.4 % | 0.01 % |
| filenames-1.hybseg | required labels | 0 | 0.0 % | 0.00 % |
| filenames-1.hybseg | vectors | 0 | 0.0 % | 0.00 % |
| filenames-1.hybseg | section paths (heading texts) | 0 | 0.0 % | 0.00 % |
| filenames-1.hybseg | **total** | **3,621** | 100 % | 0.06 % |
| filename-lexical-1.hyblex | header | 64 | 2.3 % | 0.00 % |
| filename-lexical-1.hyblex | 1 document lengths (u32 each) | 180 | 6.4 % | 0.00 % |
| filename-lexical-1.hyblex | 2 dictionary: term length + df (2 x u32) | 520 | 18.5 % | 0.01 % |
| filename-lexical-1.hyblex | 2 dictionary: posting start + count (2 x u64) | 1,040 | 36.9 % | 0.02 % |
| filename-lexical-1.hyblex | 2 dictionary: term bytes | 395 | 14.0 % | 0.01 % |
| filename-lexical-1.hyblex | 3 postings: document index (u32) | 308 | 10.9 % | 0.01 % |
| filename-lexical-1.hyblex | 3 postings: term frequency (u32) | 308 | 10.9 % | 0.01 % |
| filename-lexical-1.hyblex | **total** | **2,815** | 100 % | 0.05 % |
| MANIFEST | whole file | 787 | 100.0 % | 0.01 % |
| MANIFEST | **total** | **787** | 100 % | 0.01 % |
| INDEX-STATE.json | whole file | 94 | 100.0 % | 0.00 % |
| INDEX-STATE.json | **total** | **94** | 100 % | 0.00 % |

## 5. Text stored more than once (measured)

| Corpus | Corpus bytes | Chunk text | Source text | Chunks found as exact source spans | Chunk bytes not found | Chunk overlap bytes | Source bytes in no chunk |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| timing-1k | 916,353 | 913,211 | 916,353 | 2,071 of 2,071 | 0 | 0 | 3,142 |
| timing-10k | 7,269,199 | 7,239,281 | 7,269,199 | 19,959 of 19,959 | 0 | 0 | 29,918 |
| prose-1k | 1,676,925 | 1,732,149 | 1,676,925 | 1,819 of 1,819 | 0 | 70,984 | 15,760 |
| prose-10k | 17,244,024 | 17,818,611 | 17,244,024 | 18,766 of 18,766 | 0 | 725,252 | 150,665 |
| tamil-1k | 3,250,702 | 3,247,776 | 3,250,702 | 1,963 of 1,963 | 0 | 0 | 2,926 |
| tamil-10k | 27,708,457 | 27,678,565 | 27,708,457 | 19,946 of 19,946 | 0 | 0 | 29,892 |
| fixtures | 4,635,177 | 5,225,049 | 4,635,177 | 4,071 of 4,084 | 773 | 592,572 | 3,473 |
| family | 1,237,342 | 1,427,521 | 1,237,342 | 1,060 of 1,063 | 114 | 191,106 | 1,041 |

Other fields held by more than one section (file-name channel on):

| Corpus | Paths in documents (per chunk) | Paths in source table | Paths in state | Paths in file-name catalog | sha256 in state and source (each) | Chunk ids copied into the catalog | Stems in the catalog | Dictionary count + start (derivable) | Section paths |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| timing-1k | 43,491 | 21,000 | 21,000 | 21,000 | 32,000 | 20,000 | 9,000 | 384,912 | 35,031 |
| timing-10k | 419,139 | 210,000 | 210,000 | 210,000 | 320,000 | 200,000 | 90,000 | 384,912 | 337,943 |
| prose-1k | 59,369 | 32,678 | 32,678 | 32,678 | 32,000 | 20,000 | 22,278 | 49,840 | 41,590 |
| prose-10k | 615,294 | 327,531 | 327,531 | 327,531 | 320,000 | 200,000 | 223,531 | 49,840 | 436,947 |
| tamil-1k | 41,223 | 21,000 | 21,000 | 21,000 | 32,000 | 20,000 | 9,000 | 345,600 | 65,251 |
| tamil-10k | 418,866 | 210,000 | 210,000 | 210,000 | 320,000 | 200,000 | 90,000 | 345,600 | 663,008 |
| fixtures | 96,926 | 6,996 | 6,996 | 6,897 | 7,424 | 4,560 | 2,689 | 1,089,184 | 13,761 |
| family | 19,305 | 953 | 953 | 939 | 1,472 | 900 | 486 | 280,192 | 4,194 |

## 6. Candidates: bytes saved, measured on prototype re-encodings (file-name channel on)

| Corpus | A1 text as spans | A1-A4 records | A' source residual | A' record coding | B source deflate 64 KiB | C1 dictionary | C2b postings | C3 lengths | C5 offsets out | C5b offsets one byte per token | C6 positions + offsets out | D state | F catalog | F2 file-name lexical |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| timing-1k | 904,927 | 1,036,674 | 904,927 | 126,605 | 555,672 | 628,711 | 804,675 | 6,213 | 288,142 | 146,142 | 428,071 | 61,000 | 29,000 | 40,972 |
| timing-10k | 7,159,445 | 8,427,136 | 7,159,445 | 1,217,773 | 4,395,222 | 628,699 | 6,427,690 | 59,877 | 2,351,372 | 1,195,645 | 3,487,140 | 610,000 | 290,000 | 407,165 |
| prose-1k | 1,724,873 | 1,861,767 | 1,653,889 | 132,263 | 994,018 | 78,555 | 1,458,294 | 4,217 | 627,362 | 314,182 | 999,617 | 72,678 | 42,278 | 72,639 |
| prose-10k | 17,743,547 | 19,156,072 | 17,018,295 | 1,365,133 | 10,232,334 | 75,889 | 15,004,251 | 43,618 | 6,448,994 | 3,229,866 | 10,280,319 | 727,531 | 423,531 | 523,420 |
| tamil-1k | 3,239,924 | 3,364,850 | 3,239,924 | 120,000 | 2,673,279 | 847,019 | 745,830 | 5,889 | 268,832 | 136,379 | 399,322 | 61,000 | 29,000 | 40,972 |
| tamil-10k | 27,598,781 | 28,865,636 | 27,598,781 | 1,216,963 | 22,755,090 | 847,019 | 6,395,179 | 59,838 | 2,356,900 | 1,198,396 | 3,495,458 | 610,000 | 290,000 | 407,165 |
| fixtures | 5,207,940 | 5,472,761 | 4,615,388 | 259,908 | 3,605,509 | 1,738,601 | 2,450,240 | 10,273 | 1,185,351 | 474,077 | 1,880,059 | 16,276 | 7,249 | 9,249 |
| family | 1,423,155 | 1,486,569 | 1,232,046 | 62,116 | 784,698 | 432,647 | 1,284,800 | 2,283 | 467,096 | 232,364 | 791,126 | 2,793 | 1,386 | 2,050 |

Source text area under each codec (bytes after, block table included):

| Corpus | Text | deflate 16 KiB L6 | deflate 64 KiB L1 | deflate 64 KiB L6 | deflate 64 KiB L9 | deflate 256 KiB L6 | deflate per file L6 | deflate file-aligned 16 KiB L6 | deflate file-aligned 64 KiB L6 | LZ4-style 64 KiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| timing-1k | 916,353 | 383,911 | 411,334 | 360,681 | 358,576 | 350,460 | 472,252 | 385,369 | 361,318 | 595,677 |
| timing-10k | 7,269,199 | 3,076,706 | 3,322,968 | 2,873,977 | 2,852,742 | 2,782,394 | 3,922,392 | 3,082,385 | 2,875,169 | 4,662,645 |
| prose-1k | 1,676,925 | 756,426 | 783,564 | 682,907 | 681,758 | 653,548 | 897,422 | 762,775 | 684,322 | 1,059,264 |
| prose-10k | 17,244,024 | 7,768,512 | 8,044,669 | 7,011,690 | 7,000,515 | 6,703,775 | 9,176,370 | 7,843,760 | 7,023,577 | 10,877,519 |
| tamil-1k | 3,250,702 | 631,442 | 910,246 | 577,423 | 546,861 | 561,190 | 798,331 | 638,025 | 577,738 | 1,320,917 |
| tamil-10k | 27,708,457 | 5,413,562 | 7,783,675 | 4,953,367 | 4,668,009 | 4,813,034 | 6,943,563 | 5,460,187 | 4,955,060 | 11,427,400 |
| fixtures | 4,635,177 | 1,117,245 | 1,165,633 | 1,029,668 | 1,021,256 | 996,904 | 1,005,837 | 1,115,287 | 1,028,143 | 1,619,863 |
| family | 1,237,342 | 488,402 | 492,319 | 452,644 | 452,722 | 437,345 | 437,922 | 487,838 | 452,164 | 677,843 |

## 7. Projection: text once in the source, chunks as spans (A), then compressed (B)

Each step's saving is its measured re-encoding above; the steps touch different bytes, so they add.
Ratio = index bytes / corpus bytes.

| Corpus | Today | 1. lexical coding (C1, C2b, C3) | 2. + chunk spans (A1-A4) | 3. + offsets one byte per token (C5b) | 4. + state, catalog (D, F, F2) | 5. + source deflate 64 KiB (B) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| timing-1k (channel off) | 4,432,838 (4.84) | 2,993,239 (3.27) | 1,956,565 (2.14) | 1,810,423 (1.98) | 1,749,423 (1.91) | 1,193,751 (1.30) |
| timing-10k (channel off) | 31,011,398 (4.27) | 23,895,132 (3.29) | 15,467,996 (2.13) | 14,272,351 (1.96) | 13,662,351 (1.88) | 9,267,129 (1.27) |
| prose-1k (channel off) | 6,705,317 (4.00) | 5,164,251 (3.08) | 3,302,484 (1.97) | 2,988,302 (1.78) | 2,915,624 (1.74) | 1,921,606 (1.15) |
| prose-10k (channel off) | 68,047,830 (3.95) | 52,924,072 (3.07) | 33,768,000 (1.96) | 30,538,134 (1.77) | 29,810,603 (1.73) | 19,578,269 (1.14) |
| tamil-1k (channel off) | 9,394,513 (2.89) | 7,795,775 (2.40) | 4,430,925 (1.36) | 4,294,546 (1.32) | 4,233,546 (1.30) | 1,560,267 (0.48) |
| tamil-10k (channel off) | 72,561,144 (2.62) | 65,259,108 (2.36) | 36,393,472 (1.31) | 35,195,076 (1.27) | 34,585,076 (1.25) | 11,829,986 (0.43) |
| fixtures (channel off) | 17,466,159 (3.77) | 13,267,045 (2.86) | 7,794,284 (1.68) | 7,320,207 (1.58) | 7,303,931 (1.58) | 3,698,422 (0.80) |
| family (channel off) | 5,615,029 (4.54) | 3,895,299 (3.15) | 2,408,730 (1.95) | 2,176,366 (1.76) | 2,173,573 (1.76) | 1,388,875 (1.12) |
| timing-1k (channel on) | 4,560,085 (4.98) | 3,120,486 (3.41) | 2,083,812 (2.27) | 1,937,670 (2.11) | 1,806,698 (1.97) | 1,251,026 (1.37) |
| timing-10k (channel on) | 32,281,645 (4.44) | 25,165,379 (3.46) | 16,738,243 (2.30) | 15,542,598 (2.14) | 14,235,433 (1.96) | 9,840,211 (1.35) |
| prose-1k (channel on) | 6,907,482 (4.12) | 5,366,416 (3.20) | 3,504,649 (2.09) | 3,190,467 (1.90) | 3,002,872 (1.79) | 2,008,854 (1.20) |
| prose-10k (channel on) | 69,778,345 (4.05) | 54,654,587 (3.17) | 35,498,515 (2.06) | 32,268,649 (1.87) | 30,594,167 (1.77) | 20,361,833 (1.18) |
| tamil-1k (channel on) | 9,521,760 (2.93) | 7,923,022 (2.44) | 4,558,172 (1.40) | 4,421,793 (1.36) | 4,290,821 (1.32) | 1,617,542 (0.50) |
| tamil-10k (channel on) | 73,831,391 (2.66) | 66,529,355 (2.40) | 37,663,719 (1.36) | 36,465,323 (1.32) | 35,158,158 (1.27) | 12,403,068 (0.45) |
| fixtures (channel on) | 17,499,412 (3.78) | 13,300,298 (2.87) | 7,827,537 (1.69) | 7,353,460 (1.59) | 7,320,686 (1.58) | 3,715,177 (0.80) |
| family (channel on) | 5,621,585 (4.54) | 3,901,855 (3.15) | 2,415,286 (1.95) | 2,182,922 (1.76) | 2,176,693 (1.76) | 1,391,995 (1.12) |

## 8. Projection, the other order: text stays in the chunks, the source keeps the rest (A')

| Corpus | Today | 1. lexical coding (C1, C2b, C3) | 2. + source residual and record coding (A') | 3. + offsets one byte per token (C5b) | 4. + state, catalog (D, F, F2) | 4 with the offsets left out instead (C5) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| timing-1k (channel off) | 4,432,838 (4.84) | 2,993,239 (3.27) | 1,961,707 (2.14) | 1,815,565 (1.98) | 1,754,565 (1.91) | 1,612,565 (1.76) |
| timing-10k (channel off) | 31,011,398 (4.27) | 23,895,132 (3.29) | 15,517,914 (2.13) | 14,322,269 (1.97) | 13,712,269 (1.89) | 12,556,542 (1.73) |
| prose-1k (channel off) | 6,705,317 (4.00) | 5,164,251 (3.08) | 3,378,099 (2.01) | 3,063,917 (1.83) | 2,991,239 (1.78) | 2,678,059 (1.60) |
| prose-10k (channel off) | 68,047,830 (3.95) | 52,924,072 (3.07) | 34,540,644 (2.00) | 31,310,778 (1.82) | 30,583,247 (1.77) | 27,364,119 (1.59) |
| tamil-1k (channel off) | 9,394,513 (2.89) | 7,795,775 (2.40) | 4,435,851 (1.36) | 4,299,472 (1.32) | 4,238,472 (1.30) | 4,106,019 (1.26) |
| tamil-10k (channel off) | 72,561,144 (2.62) | 65,259,108 (2.36) | 36,443,364 (1.32) | 35,244,968 (1.27) | 34,634,968 (1.25) | 33,476,464 (1.21) |
| fixtures (channel off) | 17,466,159 (3.77) | 13,267,045 (2.86) | 8,391,749 (1.81) | 7,917,672 (1.71) | 7,901,396 (1.70) | 7,190,122 (1.55) |
| family (channel off) | 5,615,029 (4.54) | 3,895,299 (3.15) | 2,601,137 (2.10) | 2,368,773 (1.91) | 2,365,980 (1.91) | 2,131,248 (1.72) |
| timing-1k (channel on) | 4,560,085 (4.98) | 3,120,486 (3.41) | 2,088,954 (2.28) | 1,942,812 (2.12) | 1,811,840 (1.98) | 1,669,840 (1.82) |
| timing-10k (channel on) | 32,281,645 (4.44) | 25,165,379 (3.46) | 16,788,161 (2.31) | 15,592,516 (2.15) | 14,285,351 (1.97) | 13,129,624 (1.81) |
| prose-1k (channel on) | 6,907,482 (4.12) | 5,366,416 (3.20) | 3,580,264 (2.14) | 3,266,082 (1.95) | 3,078,487 (1.84) | 2,765,307 (1.65) |
| prose-10k (channel on) | 69,778,345 (4.05) | 54,654,587 (3.17) | 36,271,159 (2.10) | 33,041,293 (1.92) | 31,366,811 (1.82) | 28,147,683 (1.63) |
| tamil-1k (channel on) | 9,521,760 (2.93) | 7,923,022 (2.44) | 4,563,098 (1.40) | 4,426,719 (1.36) | 4,295,747 (1.32) | 4,163,294 (1.28) |
| tamil-10k (channel on) | 73,831,391 (2.66) | 66,529,355 (2.40) | 37,713,611 (1.36) | 36,515,215 (1.32) | 35,208,050 (1.27) | 34,049,546 (1.23) |
| fixtures (channel on) | 17,499,412 (3.78) | 13,300,298 (2.87) | 8,425,002 (1.82) | 7,950,925 (1.72) | 7,918,151 (1.71) | 7,206,877 (1.55) |
| family (channel on) | 5,621,585 (4.54) | 3,901,855 (3.15) | 2,607,693 (2.11) | 2,375,329 (1.92) | 2,369,100 (1.91) | 2,134,368 (1.72) |
