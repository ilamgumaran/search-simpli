# Filename/content retrieval implementation and handoff

Updated 2026-10-28 · Branch `feature/directory-filename-search`
· [draft PR #18](https://github.com/ilamgumaran/search-simpli/pull/18)
· [implementation claim #17](https://github.com/ilamgumaran/search-simpli/issues/17)

Owner authorization: “Pls implement and push to remote” after the reviewed
CAP-16 design, followed by the request for separate filename/content match
sections. Source checkpoint `39cd19c` includes the sectioned responses. This is
a tested source implementation, not a completed packaged-native release.

## What works

- Opt-in native Zig and Python filename indexes, separate from body postings.
- `content` (legacy default), `filename` and `both` lexical query fields.
- File BM25, scoped body statistics and deterministic per-file combined RRF.
- Real body anchors; atomic four-section generations, validated versioned
  manifest/catalog/postings, incremental updates and explicit migration errors.
- CLI, JSON-RPC, C ABI, Python tool/gateway and typed Dart integration.
- File name and Content sections with actual normalized matching terms, text
  and separate citations. Both sections remain present for unmatched context.

`matched_in` explains retained ranking channels. `match_sections.*.matched` and
`matched_terms` describe terms actually present in that displayed source, even
when that channel was not requested or was truncated. Filename terms exclude
the extension. A filename hit locates a source; it does not prove its body
answers a question. Filename citations have no fictitious line numbers.

Example for `annual observation`:

```text
1. Annual_Budget_2026.md
   File name: MATCH
     matched terms: annual
     citation: Annual_Budget_2026.md (filename)
   Content: MATCH
     matched terms: observation
     citation: Annual_Budget_2026.md:1-1
     text: This file stores numbered observation 1.
```

Machine results retain `chunk_id`, `citation`, `content`, ranking and match-origin
fields, and add `match_sections.filename` / `.content`. Legacy content-only
JSON remains unchanged. Human `query` displays sections; `query --json` and
`evidence` emit structured JSON. The [format contract](../filename-field-format-v1.md)
and [CAP-16](../requirements/cap-16-directory-filename-search.md) define details.

## Try it from source

With Zig 0.16.0 on PATH, build from the repository root:

```sh
cd zig
zig build -Doptimize=ReleaseSafe
cd ..
./zig/zig-out/bin/searchd index ./my-notes --out .search/filename-v1 --filename-index
./zig/zig-out/bin/searchd query .search/filename-v1 "annual budget" --search-field both
./zig/zig-out/bin/searchd evidence .search/filename-v1 "annual budget" --search-field both
./zig/zig-out/bin/searchd index ./my-notes --out .search/filename-v1 --update --filename-index
```

For Python use `search.py index ... --filename-index`, then
`search.py context ... --mode lexical --search-field both`. For tools, send
`search_field: "both"` with `retrieval_mode: "lexical"`. Old body-only snapshots
still open, but cannot answer filename requests. Build the additional channel
in a separate output location. The setting must be repeated on refresh; mode
and analyzer checks run under the writer lease before publication.

Path prefixes retain literal-prefix semantics on search/read/list; `public/`
means that directory, while `public` also matches `public-secret/`. Trusted
labels remain the access boundary and filter both channels/statistics. Native
filename analysis uses the stored analyzer; the Python filename field uses NFC
and simple fold while preserving existing full-fold body behavior. Native and
Python Unicode table versions can still differ beyond the tested cases.

## Verification and preserved failures

[Recorded validation](../../benchmarks/filename-field-validation-2026-10-28.json)
binds the source checkpoint, results, fresh Linux ABI artifact and source digest.

| Check | Outcome |
| --- | --- |
| Zig engine | 192/192 pass, exit 0 |
| C ABI harness | 16/16 pass, exit 0 |
| Full Python including native CLI | 126 run: 121 pass, 1 failure, 4 skips; exit 1 |
| Full Dart against fresh Linux 1.3.0 library | 68/68 pass, exit 0 |
| Independent source and public-process review | No unresolved source finding |

At source head `39cd19c`, both required hosted jobs also failed in
[run 40630561798](https://github.com/ilamgumaran/search-simpli/actions/runs/40630561798).
The local passing source/API checks do not replace those required CI gates.

The Python failure is the unchanged native-freshness gate: packaged libraries and
their `SOURCE-SHA256` still describe the older source. Three macOS-arm64 checks
and one Python Unicode-table-version check skip on this Linux host. No test was
weakened or bypassed to hide the package mismatch. The first final rerun also
caught a literal home-cache path in new documentation; that path was redacted
and privacy checks were rerun without changing the gate. Dart static analysis could not
initialize its UUID cache under read-only `<user-home>/.dartServer`, including
with an explicit writable `--cache`; full test compilation/execution succeeded.

Tests cover all six frozen filename cases, exact legacy content bytes/goldens,
real spans and origins, separate citations, term normalization/order/dedup,
context-only sections, RPC parsing and invalid modes, Python v2 import, trusted
scope/hidden-absent comparisons, stale/renamed/deleted files, corruption and
atomic-failure cases. Review caught and fixed compacted-catalog scoring, passage
selection, a missing RPC colon, migration races and inconsistent prefix semantics.

## Measured cost, not a device promise

The [reproducible cost script](../../scripts/benchmark_filename_field.py) and
[raw report](../../benchmarks/filename-field-cost-2026-10-28.json) compare Debug
builds of baseline `4b12ce7` and candidate `39cd19c` on 1,000 invented files.
Three fresh-output builds each completed without errors. Baseline indexing took
66.6–69.3 ms versus 83.0–84.5 ms with filenames. Snapshot totals (including state)
were 334,494 versus 467,744 bytes. No OS-cache reset was attempted.

Thirty sequential RPC queries per field verified the designated top file. Body
p95 was 0.209 ms baseline / 0.272 ms with the channel enabled; filename p95 was
76.2 ms and combined p95 92.2 ms. Startup-to-status was 11.9 ms baseline versus
28.3–31.8 ms candidate. Observed process peak RSS was 8,832 KiB baseline versus
10,892–11,052 KiB candidate. These include process/RPC/serialization effects and
are synthetic Debug measurements, not capacity or real-folder relevance claims.

New-field queries currently decode filename sections per request and resolve
anchors against body records. The measured cost justifies considering a cached
validated catalog/anchor lookup next, before fuzzy/ANN or other search machinery.
No optimization is claimed here, and device budgets remain owner-supplied.

## Package integration remains blocked on an equipped Mac

Source contract/Dart pin is 1.3.0. Committed macOS/Android/iOS libraries remain
the previous build. Linux source and a separately built 1.3.0 Linux ABI were
tested; that is not verification of the bundled files. The source stamp was
not changed by hand. This PR must remain draft and unmerged until packaging
and the required full gate pass.

On a Mac with Xcode, Zig 0.16.0 and the pinned NDK:

1. Fetch this branch, review the source diff and build the **integrated** source.
2. Run `tool/build_native.sh` in `bindings/dart/search_simpli/` with `SS_ANDROID_NDK`
   set, producing all packaged libraries and the page-aligned iOS framework;
   update the Android example copy and generated source stamp through that tool.
3. Run `tool/check_native.sh`, Python native freshness/full suites, Zig/ABI tests,
   Dart analysis/full tests and affected platform checks. Record actual outcomes.
4. Push the genuine artifacts, obtain independent review and green CI, then
   consider merge. Recovery PR #11 is a separate integration; do not merge it
   merely because this filename branch exists.

No PDF/Office/OCR extraction, exact phrase/fuzzy search, representative user-folder
relevance, physical mobile testing or production release is asserted by this work.
