# Directory search audit and filename retrieval stages

Date: 2026-10-25 · [claim #15](https://github.com/ilamgumaran/search-simpli/issues/15)
Branch: `improve/local-directory-search` · Baseline: main `9c3265a`.

The owner asked for content and filename search to help an LLM inspect local
documents. Existing content indexing is implemented; filename retrieval is
[CAP-16 / FR-16](../requirements/cap-16-directory-filename-search.md), proposed.
This task does not finish unrelated recovery PR #11, SQ-02 or iOS app deployment.

## Current behavior, confirmed in source

| Area | Current behavior |
| --- | --- |
| Directory discovery | Supported UTF-8 text/source extensions; skips hidden/ignored directories. |
| Contents | Native Zig/Python body-token BM25; Unicode analyzer-v2, persisted postings, explicit incremental refresh. |
| Names | Paths appear in citations/list_sources; filename tokens are not indexed. |
| LLM use | Stored chunk id, path/line citations and body content; search/read/list/status tools. |
| Formats | Text/Markdown/source/config; HTML is read as source text, not DOM-aware extraction. PDF/Office/OCR need external extraction. |
| Query semantics | Token BM25, not exact quoted phrases, substrings, fuzzy matching or automatic semantic understanding. |

Code anchors: `zig/src/indexer.zig` tokenizes `document.text` / `span.text`;
`src/search_platform/core.py` builds terms from `_line_chunks(text)`; paths stay
separate. The existing engine already supplies an inverted index and BM25:
extend that design rather than adding a second mandatory database.

## Delivery split

| Stage | Owner/model | Concrete output and exit gate |
| --- | --- | --- |
| DS-00 audit | Sol 6.1 orchestration; Luna audit; Sol 6 verification | Run current native/Python suites and reproducible invented-directory probe; correct filename/phrase/format claims; publish this design. No new runtime behavior. |
| DS-01 format freeze | Sol 6.1 + independent reviewer, then named maintainer | Freeze CAP-16 manifest/catalog/import/wire schema constants, reader matrix and six filename cases with hashes, default-body golden outputs, and all acceptance oracles. Complete step-6b approval over final spec/format/fixture commits. No runtime build before this gate. |
| DS-02 index | Bounded execution model after approval | Separate filename catalog/postings, native full/incremental index, importer/reference parity, atomic generation, corruption and refresh tests. No body statistics or chunk ids changed. |
| DS-03 retrieve | Bounded execution model; Sol 6 independent tests | Implement opt-in fields, file-level BM25, combined RRF, anchor/origin semantics and pre-rank isolation across CLI/RPC/ABI. Freeze legacy output comparisons; run denial and hidden/absent plants. |
| DS-04 clients/builds | Execution + equipped Mac verifier | Update tool/gateway/Dart contracts and examples, rebuild all shipped libraries from integrated source including iOS, verify source stamp and platform checks. Preserve explicit unsupported combinations. |
| DS-05 acceptance | Sol 6 verification; Sol 6.1 review | Run full gates, measured 1,000-file cost comparison, independent source review, platform limitations and rollback. Only merge when ready; advance to Diagnostic, not real-folder Validated. |

Dependencies are sequential at the persistence/contract seam; do not have agents
edit indexer/query contracts concurrently before DS-01. No speculative "best"
algorithm claim: retain BM25 and current inverted postings; RRF is a proposed
inspectable baseline. ANN, SIMD/compression, WAND pruning, fuzzy trigrams,
embeddings, phrase positions and background watching require their own evidence.

## Resume and rollback

Fetch this branch, read CAP-16 and the requirements register, then review actual
evidence below. Content search is usable today. Do not advertise filename search
as shipped. DS-01 is the next design task; it can proceed before requesting final
maintainer approval. Later builds use a separate snapshot directory so the prior
binary and body-only snapshot remain recoverable together.

## DS-00 evidence

At baseline `9c3265a`, independent Linux validation with Zig 0.16.0 passed:
176/176 Zig tests, 16/16 C ABI checks, CLI build, 97 Python passes / 4 skips
(3 macOS-arm64 shipped-library checks and 1 Python Unicode-table-version check).
The 4-query dependency-free relevance mechanics smoke passed all four aggregate
metrics at 1.0; this is fixture correctness, not representative relevance.

Run the [directory diagnostic](../../scripts/diagnose_directory_search.py) from
the repository root after building `searchd`:

```sh
python3 scripts/diagnose_directory_search.py --searchd zig/zig-out/bin/searchd
```

The [recorded observations](../../benchmarks/directory-search-current-2026-10-25.json)
include invented fixture text/hashes, baseline source SHA, CLI binary SHA,
Python/platform stamp, process exits and cited results. The script validates all
returned spans against current source bytes, including stable chunk ids. The
final probe exits 0 with 27/27 successful processes. Missing binary exits 2;
`/bin/false` exits 1 with captured failure JSON. Filename and phrase outcomes
are observations, never assertions that would freeze today's missing features.

| Probe (both Python and native Zig) | Observed result |
| --- | --- |
| English body query | One cited result at `camp-notes.md:1–2` |
| Tamil body query | One cited result at the actual Tamil source span |
| English/Tamil filename-only queries | Zero results each |
| Reversed quoted terms | One result, proving no phrase-order enforcement |
| Absent/ignored-hidden queries | Zero results each |
| Changed source after explicit refresh | New passage found; old unique token absent |
| Deleted source after refresh | Its body terms absent |
| Renamed source after refresh | Same content cites new path, old path absent |

Independent Sol 6 validation also passes the requirements validator, 18/18
validator tests and relative Markdown link checks. Technical review identified
that existing Zig body BM25 uses global statistics; CAP-16 now explicitly
requires scoped statistics for its new combined mode, leaving legacy content
unchanged. This is a design correction, not a runtime fix or a claim that current
content scores are hidden/absent invariant. Independent review supplies no
maintainer approval; DS-01 and step 6b are still pending.
