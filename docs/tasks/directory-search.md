# Directory search audit and filename retrieval stages

Date: 2026-10-25 · [claim #15](https://github.com/ilamgumaran/search-simpli/issues/15)
Audit branch: `improve/local-directory-search` · Baseline: main `9c3265a`.
Current source branch: `feature/directory-filename-search`.

The owner asked for content and filename search to help an LLM inspect local
documents. Filename/content retrieval is now a diagnostic source implementation
of [CAP-16 / FR-16](../requirements/cap-16-directory-filename-search.md). The
[current implementation handoff](directory-filename-implementation.md) supersedes
the audit-era status below and records the outstanding bundled-native gate.
This task does not finish unrelated recovery PR #11, SQ-02 or iOS app deployment.

## Historical audit behavior at `9c3265a`

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

## Original delivery split and current outcome

| Stage | Owner/model | Concrete output and exit gate |
| --- | --- | --- |
| DS-00 audit | Sol 6.1 orchestration; Luna audit; Sol 6 verification | Run current native/Python suites and reproducible invented-directory probe; correct filename/phrase/format claims; publish this design. No new runtime behavior. |
| DS-01 format freeze | Sol 6.1 + independent reviewer, then named maintainer | Freeze CAP-16 manifest/catalog/import/wire schema constants, reader matrix and six filename cases with hashes, default-body golden outputs, and all acceptance oracles. Complete step-6b approval over final spec/format/fixture commits. No runtime build before this gate. |
| DS-02 index | Bounded execution model after approval | Separate filename catalog/postings, native full/incremental index, importer/reference parity, atomic generation, corruption and refresh tests. No body statistics or chunk ids changed. |
| DS-03 retrieve | Bounded execution model; Sol 6 independent tests | Implement opt-in fields, file-level BM25, combined RRF, anchor/origin semantics and pre-rank isolation across CLI/RPC/ABI. Freeze legacy output comparisons; run denial and hidden/absent plants. |
| DS-04 clients/builds | Execution + equipped Mac verifier | Update tool/gateway/Dart contracts and examples, rebuild all shipped libraries from integrated source including iOS, verify source stamp and platform checks. Preserve explicit unsupported combinations. |
| DS-05 acceptance | Sol 6 verification; Sol 6.1 review | Run full gates, measured 1,000-file cost comparison, independent source review, platform limitations and rollback. Only merge when ready; advance to Diagnostic, not real-folder Validated. |

Current outcome: DS-00/DS-01 audit, authorization, format and fixture freeze are
complete. DS-02/DS-03 are implemented in source; DS-04 client source and fresh
Linux ABI/Dart tests pass, while packaged-native rebuild remains pending.
DS-05 has recorded source verification and cost evidence, but the full Python
freshness gate remains failed and platform release acceptance is incomplete.

Dependencies are sequential at the persistence/contract seam; do not have agents
edit indexer/query contracts concurrently before DS-01. No speculative "best"
algorithm claim: retain BM25 and current inverted postings; RRF is a proposed
inspectable baseline. ANN, SIMD/compression, WAND pruning, fuzzy trigrams,
embeddings, phrase positions and background watching require their own evidence.

## Resume and rollback

Fetch `feature/directory-filename-search` and read the
[implementation handoff](directory-filename-implementation.md). Filename and
combined queries work on opt-in source-built snapshots. New-mode responses have
File name/Content sections; legacy content JSON stays unchanged. Full settings
migration uses a separate output directory, preserving the prior binary/snapshot.
The next release step is the actual packaged-library rebuild and verification on
an equipped Mac; do not call that complete from Linux source tests.

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
maintainer approval. That audit-time approval was pending; the later owner
implementation request and DS-01 freeze are recorded in the current handoff.
