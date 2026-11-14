# Search review and implementation TODOs — 2026-11-11

Reviewed main: `f2d6f6c6b71f276737fd01d08a72d433da6bccbe`.
Documentation review claim: [#24](https://github.com/ilamgumaran/search-simpli/issues/24).

These are **recommendations and implementation outlines**, not accepted tasks,
capability approvals or implemented behavior. R01–R12 identify items in this
review only; they do not allocate S-series, CAP or requirement identifiers.
The existing [live queue](../journey/03-next.md) and task owners remain authoritative.

## What already works

Main supports text/source folder indexing, incremental updates, scoped retrieval,
filename/content/combined search, separate filename and passage citations, retained
source reads, and the native MCP interface. Content search includes title terms,
misspelling expansion, fold groups and the newly merged verb forms: contracts
2.6.0, Dart 0.7.0, `fold-groups-v2`. These are not missing features to reimplement.

`find` remains exact by contract. PDF/Office/OCR require extraction outside the
native folder crawler. A filename match locates a file; cited passages must still
support an answer. Hybrid/embedding experiments remain separate from the default
lexical path. See [current usage](../../README.md#search-filenames-and-document-contents)
and [current state](../../PROJECT-STATE.md).

## Recommended order

P0 means establish trustworthy validation first; P1 means the next practical
implementation work; P2 means a design or evidence dependency remains. Sizes are
relative planning estimates, not measured implementation times.

| ID | Priority | TODO | Size | Relation to existing work |
| --- | --- | --- | --- | --- |
| R01 | P0 | Run Unicode golden freshness in CI without skips | S–M | New CI proposal; known skip condition |
| R02 | P0 | Gate the complete J2 pack through native ReleaseSmall `searchd` | M | Existing unscheduled native-J2 row |
| R03 | P1 | Align Python content-mode prefix BM25 statistics with Zig | M | Existing reference-prefix row |
| R04 | P1 | Decide and close `FolderIndex.search` reference drift | M | Existing lifecycle-reference row |
| R05 | P1 | Test cross-word verb forms before tightening expansion | M | Existing S5-T5 follow-up |
| R06 | P1 | Reduce irrelevant hits from stop words and near spellings | M–L | Existing stop-word/fuzzy-floor rows; judgment dependency |
| R07 | P1 | Remove avoidable `both` query work and profile frequent groups | M | Existing two performance rows |
| R08 | P1 | Create a fresh multi-root filename index in one apply operation | M | Existing fresh-apply row |
| R09 | P2 | Finish chunker identity across interchange/import | M–L | Existing CFT-09; contract/migration decision |
| R10 | P2 | Define truthful citations for host-extracted PDF/Office text | L | New capability proposal; host integration |
| R11 | P1 | Validate an actual agent using the cited MCP workflow | M | Existing CAP-13/I-01 validation gap |
| R12 | P1 | Reconcile stale backlog and continuation guidance | S | Documentation coordination with existing owners |

Start R01/R02 and the bounded R03 parity fix. Use those gates before changing
ranking in R05/R06. R07 and R08 can be separate tickets. R09/R10 need their
contract decisions first. R11 provides a user-facing check of whether the tool
actually helps an agent answer from files. Do not begin ANN, a new service,
index-wide normalization or adaptive ranking without a named failing target.

## R01 — Make Unicode golden freshness a real CI check

**Landed by [S5-T6](../tasks/S5-T6.md)** (12 Nov 2026, branch `task/S5-T6`; the job in
`73fba35`, the header normalisation in `b4f9da5`; verified and merged to `main` 12 Nov 2026 as
the `--no-ff` merge of `task/S5-T6`, Verdict in the task): CI's `unicode-13-goldens` job, Python 3.9, nine checks counted by name, a skip fails.

**Evidence:** [.github/workflows/checks.yml](../../.github/workflows/checks.yml)
uses Python 3.11. [test_goldens_fresh.py](../../tests/test_goldens_fresh.py)
skips regeneration when the interpreter's Unicode differs from the pinned
13.0.0 tables. Related guards exist in `test_analyzer_v3.py` and `test_tokenize.py`.
This review's Python 3.12.14 uses Unicode 15.0.0. Some regeneration guards skip;
this does not mean the entire analyzer or golden-comparison suite is skipped.

**Implementation:**

1. Add a dedicated job with a verified Unicode-13-compatible interpreter, or a
   deterministic pinned-UCD provider. Choose the approach before coding; keep
   normal supported-Python behavioral coverage.
2. Run the existing analyzer/table and title/BM25/fuzzy/verb golden generators.
   Assert the actual Unicode version and fail if the required checks skip.
3. Compare regenerated files byte for byte. Do not migrate the analyzer's Unicode
   version or refresh expected files merely to make this job green.

**Exit:** deliberately stale each generated fixture and prove the job fails;
restore it and prove every required check executes and passes. No native ranking,
index format or shipped library change is needed for a CI-only solution.

## R02 — Run the native J2 relevance gate in CI

**Landed by [S5-T6](../tasks/S5-T6.md)** (12 Nov 2026, branch `task/S5-T6`; the steps in
`d37c91e` and `633f9a5`; verified and merged to `main` 12 Nov 2026 as the `--no-ff` merge of
`task/S5-T6`, Verdict in the task): `native-linux-release`
runs J2 through its `ReleaseSmall` `searchd` and the gate; x86_64 equals the macOS arm64 baseline.

**Evidence:** CI runs the J2 command through the Python reference. Native jobs
run engine, ABI and Python/process tests, but do not directly run the complete
[j2_run.py](../../scripts/j2_run.py) harness and
[j2_gate.py](../../scripts/j2_gate.py) against ReleaseSmall `searchd`.
This is already an unscheduled item in the live queue; it is not an absence of
all native relevance testing.

**Implementation:**

1. Reuse the Linux release job's freshly built executable. Run J2 in `content`
   and `both`, checking expected case counts and rejecting a fallback or skip.
2. Compare against the existing frozen gate. Investigate the documented native
   f32/tie cases, including `m13`, before proposing any platform-specific baseline.
   A new baseline requires explained, reproducible differences and review.
3. Store per-query reports on failure and test a deliberately bad candidate
   against the same gate. Keep [test_j2_gate.py](../../tests/test_j2_gate.py)
   and the current allow-list meaningful.

**Exit:** native and reference reports identify their executable/source and
policy versions; both modes execute fully; a planted ranking regression fails.
Do not overwrite the baseline or enlarge the allow-list to conceal a regression.

## R03 — Fix content-mode reference scoring under a path prefix

**Landed (S5-T7, [task](../tasks/S5-T7.md), commit `127b84a` on `task/S5-T7`; verified and
merged to `main` 12 Nov 2026 at `da7ddf2`):**
the reference's `content` body scoring takes its statistics from the visible
chunks and narrows only the candidates by the prefix; grouped terms' df included.
`tests/test_prefix_statistics.py` holds the plain and grouped fixtures (inside the
prefix, outside it but visible, a hidden label) and compares raw scores and ranks
with `searchd`; `filename`/`both` are unchanged guards. The engine did not change.
The section below is the review as written.

**Evidence:** in [core.search](../../src/search_platform/core.py), around lines
1628–1641, Python narrows chunks by prefix before `_bm25_scores`. Zig
[Engine.queryTraced](../../zig/src/engine.zig), around lines 257–273, deliberately
keeps BM25 statistics over visible roots/labels and narrows candidate membership
only. The existing queue records differing scores even where the tested ranks
agree. Title scoring in Python already uses the wider visible set. This is the
`content` path: native `filename_field.scoreQuery` and Python
`_search_filename_fields` deliberately use a separate prefix-scoped statistics
path for `filename`/`both`. Do not widen those statistics as part of this fix.

**Implementation:**

1. Pass authorized statistics separately from prefix-filtered candidate chunks
   into Python's `content` body scoring; include grouped terms' df and average length.
2. Preserve roots/labels as the statistics boundary. A path prefix is a candidate
   filter, not permission to include unauthorized terms in either calculation.
3. Extend plain and grouped `content` conformance fixtures with inside-prefix,
   outside-prefix-but-visible, and hidden-label files. Compare raw lexical
   scores and final ranks using the established numeric tolerance. Keep
   `filename`/`both` fixtures as unchanged guards against their own native policy.

**Exit:** content scores and ordering agree with native content policy under each
scope; removing the prefix filter or including a hidden file fails a test.
Filename/`both` results remain unchanged. Harmonizing the native policies, if
desired, is a separate design decision; this ticket does not retune the ranker.

## R04 — Resolve the lifecycle reference's older ranking

**Landed (S5-T9, [task](../tasks/S5-T9.md), commit `a17c7f2` on `task/S5-T9`; verified and
merged to `main` 12 Nov 2026 at `937da55`, the `--no-ff` merge of `task/S5-T9`):** the helper models current retrieval (step 2). `FolderIndex.search`
hands its authorized snapshot (the visible chunks of the roots named, and those
roots' ids) to `core.search` (lexical), so the title field, fuzzy-v1 and the fold
groups reach it and no second copy of the ranking remains. `roots`,
`principal_labels`, `conjunctive`, `top_k` and the result fields are kept; `score`
is the chunk's `ranking.lexical.score`; no path-prefix parameter; `core.py` is
unchanged. `tests/test_folder_ranking.py` compares the helper with `core.search`
and with `searchd` through an update, a rename and a delete on title, typo,
verb-form, plural and scope cases. No caller depended on the old ranking: the
lifecycle pack's `find` steps check hit sets under `conjunctive` and did not move.
The section below is the review as written.

**Evidence:** [FolderIndex.search](../../src/search_platform/folders.py), around
lines 643–666, explicitly retains pre-title-field BM25. It does not perform the
current title/fold/fuzzy path in `core.search`. This is documented legacy behavior,
not a newly discovered native regression.

**Implementation:**

1. Decide whether this public helper should model current retrieval or remain a
   lifecycle-only diagnostic. Inventory its callers and tests before changing it.
2. If current behavior is intended, adapt the authorized folder snapshot to the
   shared reference ranker rather than maintaining another copy. Preserve the
   actual `roots`, `principal_labels`, `conjunctive` and `top_k` API, root/file
   metadata and result fields. Do not introduce a path-prefix parameter silently.
3. If legacy behavior is intentional, name/document that boundary and route
   current-behavior evaluations through `core.search` instead.

**Exit:** lifecycle update/rename/delete fixtures cannot silently select an old
ranker when evaluating current search. Add comparative title, typo, verb-form and
scope cases; preserve explicit legacy expectations if that mode is retained.

## R05 — Measure cross-word verb matches before changing R

**S5-T8 ([task](../tasks/S5-T8.md); re-ruled 13 Nov 2026 before its merge,
this rule still ships; verified and merged at `e43b0b2`):** steps 1–3. `verbform-cross` (six rows, hop/hope, evening/even,
tap/tape, answers in six files) was judged and recorded before any rule; a
narrow eligibility rule, [fold-groups-v3](../fold-groups-v3.md), was prototyped
in Python beside the cap and the membership rule and ported to Zig (golden
equal). `verbform-cross` 0.667 → 1.000 success@1 under `content` and `both`,
`c22` and every control row at rank 1, contracts 2.7.0; with the rule removed
(a plant) `x02` and `x05` fall back to ranks 3 and 2. `evening` → `even` and the
doubled held remainders (`shedding`, `canned`) stay as named residuals.

**Evidence:** S5-T5 is shipped and improves its judged verb-form slice. A direct
probe of [verb_forms.forms](../../src/search_platform/verb_forms.py) finds
`hopping` can generate `hopes`/`hoped`, and `evening` can generate `even`.
The three-letter query `hop` itself generates no forms: the helper's length guard
matters. [fold-groups-v2](../fold-groups-v2.md) reports no current J2 group taking
these cross-word forms. Relevance harm is a **hypothesis**, not a measured result.

**Implementation:**

1. Add opposing hop/hope and evening/even documents and judge queries before
   changing rules. Spread relevant answers across files so file-level `both`
   merging does not hide differences visible in `content`.
2. Freeze those judgments and controls, then prototype a narrow eligibility or
   ambiguity rule in Python. Test it alongside the existing frequency cap and
   scope membership rule; do not disable the successful verb-form feature.
3. Port only a justified candidate to Zig. Compare groups, warnings, rankings,
   J2 and held-out results; retain `c22`, source-byte stability and memory checks.

**Exit:** any proposed precision improvement has a judged before/after result
without an unexplained control regression. Decide policy/contract versioning and
approval before shipping changed matching semantics; keep a rollback comparison.

## R06 — Treat unanswerable queries as a precision target

**S5-T8, re-ruled before its merge, then verified and merged at `e43b0b2` ([task](../tasks/S5-T8.md), 13 Nov
2026):** steps 1–3 on invented content (no real-user examples). Two
negative sets of 17 (tuning, and a held-out set no candidate ran before every
candidate was declared), `negatives-short` and a `precision-control` slice;
"misleading" defined in `fixtures/j2/README.md` before any candidate ran (after
two exploratory runs of the engine as it was, a stated limit). Stop words in the
title part (W) did not move the measure and do not ship; out of the body (Wb)
they cost two `mixed` rank-1 answers and do not ship. A fuzzy floor (Fp2,
fuzzy-v2) was chosen by a rule fixed in advance on a short-typo slice the
builder wrote, then withdrawn: of 16 typos the verifier wrote, two edits from a
6 or 7 letter word with an edit in the second letter, 13 found the meant file
at rank 1 under fuzzy-v1 and none under Fp2 (kept as a rejected candidate in
[the prototype record](../tasks/S5-T8-prototype.md)). Those typos and 9
first-letter ones are now J2's `misspelling-opening` slice, the bar for any
later floor. What ships is [fold-groups-v3](../fold-groups-v3.md) alone, with
fuzzy-v1 unchanged: `negatives-heldout`'s misleading-first share 0.588 → 0.529,
mean top-5 hits 3.176 → 2.941 (`content`); against `main` only `verbform-cross`
moves (0.667 → 1.000). `find` and the `filename` field are unchanged. No score
threshold, no answer-confidence value and no abstention default was
introduced.

**Evidence:** the live queue records `on2` (`painting the fence`) returning ten
hits; S5-T5 now reaches a model file through `paint`. It also records near-word
examples such as `skating` reaching unrelated terms. These are named local cases,
not a measured production false-answer rate. E-01/E-02 and the earlier
[negative-evaluation design](../tasks/search-quality-follow-ups.md) remain relevant.

**Implementation:**

1. Expand independently judged negative/control coverage, including real-user
   examples when available. Separate tuning data from the frozen holdout. Specify
   what constitutes misleading support before choosing a cutoff.
2. Prototype query stop-word handling for title scoring first. Separately test a
   fuzzy-candidate eligibility floor. Change one policy at a time so its effect
   is attributable. Preserve exact `find` phrase semantics and filename behavior;
   do not silently introduce a new quote grammar for token-based search.
3. Compare `content` and `both` across negative, title, multilingual, typo and
   control slices. Retain the successful typo and morphology cases.

**Exit:** satisfy predeclared per-query/per-slice gates; report irrelevant matches
and any separately judged unsupported answers explicitly. There is no justified
universal score threshold yet. Do not
turn retrieval scores into an answer-confidence probability or invent a default
abstention threshold before the negative corpus and capability gates exist.

## R07 — Reduce measured `both` overhead

**S5-T12 ([task](../tasks/S5-T12.md); landed, part 1 only: verified and merged to `main` 14 Nov 2026 as `5a101b4`):** steps 1
and 3 (measured on `main` first: the walk `both` discarded is the cost), and the overhead R07 names.
`scope.visibleCollection` no longer walks when no record carries a label and the mask allows every root of every
document (`RootMask.allowsEvery`), which is every `both` query on a folder without labels with every root asked
for: −0.030 to −0.033 ms on the 10k timing corpus, beyond the noise band of two placement controls in both of the
verifier's runs. Under a scope that hides something nothing changes. The lazy view of step 2 (part 2) failed the
noise rule fixed before it was measured, did not ship, and is a 03-next row; `filename_field.zig`'s profile stays open on the S5-T4 row.
Groups, warnings, scores, ties and visibility are byte-identical (29,376 `searchd` requests, J2, goldens).

**Evidence:** [Engine.bothGroups](../../zig/src/engine.zig), around lines
397–408, builds `scope.visibleCollection` before knowing whether expansion needs
it. The queue records a no-trigger `bazecha` cost of roughly 0.053–0.059 →
0.085–0.090 ms. It separately records grouped `system` missing the previous
`both` increment bound (+0.065 ms versus +0.03 ms). These are prior whole-query
measurements, not new timings from this review. The eager view is source-observed;
its contribution to the regression remains a hypothesis until profiling.

**Implementation:**

1. Re-measure the named workload on current main and profile allocation and
   body/title traversal separately. If the overhead no longer reproduces, record
   that before changing code. Add a membership-only preflight if it can establish
   that no scoped df view is needed.
2. Build the visible collection lazily and at most once when grouping needs it.
   Then profile [filename_field.zig](../../zig/src/filename_field.zig)'s touched-
   chunk scoring for frequent groups; do not mix both optimizations into one
   unexplained result.
3. Compare `bazecha`, `system`, `hashing` and both query-term orders on the existing
   10k corpus with interleaved before/after runs and retained raw measurements.

**Exit:** groups, warnings, scores, ties and visibility behavior remain identical;
the named overhead improves under the existing methodology. Use growth-ratio
regression tests under CPU load, not a new single wall-clock test. Phone/Tamil
map compaction needs its own measured target before adding cache machinery.

## R08 — One operation for a fresh multi-root filename index

**S5-T11 ([task](../tasks/S5-T11.md); landed: verified and merged to `main` 13 Nov 2026 as `1fde599`):** steps 1–3.
`searchd apply <dir> --changes <file> --filename-index` is the CLI spelling of
the core's existing `filename_index` (no request, wire or contract field): a
directory with no index gets exactly the requested roots at its first
generation with the channel on; an index with the channel takes the flag as a
no-op; one without it is refused (exit 2, nothing written, no migration). No
placeholder root. Process and Zig tests cover empty roots, labels, a repeat,
the flag twice and both crash points of a first write. `scripts/j2_run.py`
builds its index in one step; every J2 cell is unchanged and the gate is clean
without a re-recorded baseline. Within CAP-16's approval (CAP-16 §14).

**Evidence:** [cli.zig](../../zig/src/cli.zig)'s `apply` parser has no
`--filename-index` option. [j2_run.py](../../scripts/j2_run.py), around lines
156–168, creates an empty `r-legacy` index before adding its intended roots.
Fresh native multi-root filename indexing is an existing usability TODO.

**Implementation:**

1. Specify a fresh-index creation option on `apply`/its request boundary, including
   omission and conflict behavior when the directory already has a manifest.
2. Thread it through CLI → operation → apply initialization. Reuse current
   publication and filename-index formats; do not create a hidden placeholder root.
3. Update process tests and the J2 setup to create the intended roots in one call.
   Test empty roots, labels, repeat apply, conflicting options and crash recovery.

**Exit:** one fresh operation publishes exactly the requested roots/generation;
filename/content/both work immediately. Existing indexes keep their capability
unless an explicitly supported migration says otherwise. Confirm any additive
CLI/wire requirement through the capability process before implementation.

## R09 — Finish chunker provenance through interchange

**Evidence:** CFT-09 is still blocked, but its short queue wording is stale:
manifest v2/status already carry chunker information. The missing link is the
interchange/import path, clarified in the [requirements register](../requirements/README.md).
[interchange.py](../../src/search_platform/interchange.py),
[snapshot-interchange.schema.json](../../contracts/snapshot-interchange.schema.json)
and [importer.zig](../../zig/src/importer.zig) need the joint contract design.

**Implementation:**

1. Specify versioned document/payload chunker identity and validation, including
   old payloads with no identity, unknown versions and mixed-chunker input.
2. Decide backward compatibility and migration before modifying schema or native
   import. Preserve identity through import, publication, status and source reads.
3. Add Python→Zig round trips and mismatch/old-format tests; update the register,
   conflict disposition and requirements validator together.

**Exit:** a maintainer resolves CFT-09 from evidence; do not declare native CAP-15
support merely because a manifest already has a field. Native/contract changes
must carry rebuilt packages and an accurate source digest.

## R10 — Honest PDF/Office extraction and citations

**Evidence:** [indexer.zig](../../zig/src/indexer.zig) discovers supported UTF-8
text/source formats. [apply.zig](../../zig/src/apply.zig) hashes and retains the
UTF-8 bytes supplied by a host; existing line citations address those bytes.
Feeding extracted text under an `invoice.pdf` name would not make those lines
original PDF page coordinates. [UC-007](../use-cases/uc-007-family-folders-on-a-phone.md)
already assigns extraction to the host app.

**Implementation:**

1. Draft the extraction/citation capability: original identity, original-content
   digest, extracted-text digest, extractor version and coordinate space. Decide
   whether citations map to pages/paragraphs or explicitly identify normalized text.
2. Prototype a host adapter using existing apply operations. Preserve authorization,
   edits/rename/delete behavior and source provenance; choose extraction tooling
   separately. A new native PDF/Office parser is not a prerequisite.
3. Add small multi-page/table fixtures and test filename discovery → passage read
   → supported citation, then an original edit and extractor-version change.

**Exit:** a reader can locate the cited content in the declared source space;
freshness distinguishes original and extracted bytes. Unsupported/unmapped
citations are explicit. Capability, contract and migration approval precede code.

## R11 — Validate the real agent workflow

**Evidence:** the live queue classifies CAP-13/I-01 as implemented/diagnostic;
validated status still requires a real agent on a judged snapshot. Transport and
schema tests alone do not establish answer support. See
[mcp.zig](../../zig/src/mcp.zig), [ops.zig](../../zig/src/ops.zig),
[tool schemas](../../contracts/tools/) and [folder-knowledge skill](../../skills/folder-knowledge/SKILL.md).

**Implementation:**

1. Freeze a reproducible corpus and tasks: filename recall, cited content,
   combined matches, no answer, scoped hidden files, refresh and renamed sources.
2. Run an actual consumer/agent through MCP. Check search → `read_span`/chunk
   evidence → answer citation, with filename-only matches used to locate files.
3. Capture tool transcripts and source/generation/policy identifiers. Record any
   consumer pin/contract changes separately, including 2.6.0/0.7.0 adoption if
   that consumer has not adopted them. Do not assume it is already updated.

**Exit:** apply CAP-13's declared validation criteria and report unsupported
answers, wrong sources, negative cases and scope failures. Retrieval policy IDs
already exist; JSON-RPC not forwarding expansion warnings is current documented
behavior, not a reason to claim all result explanations are absent.

**Measured (S5-T10, 12 Nov 2026; verified and merged 12 Nov 2026 at `2cbdb1d`, [Verdict](../tasks/S5-T10.md)):**
[S5-T10](../tasks/S5-T10.md) froze 30 questions over the J2 snapshot covering:
- filename recall;
- cited content;
- name with content;
- no answer;
- an answer only in a hidden root;
- after a refresh with edits, moves and deletes.

Ten Claude Sonnet 5.5 sessions answered the set twice, each through a command-line MCP client that starts
`searchd mcp --roots school,home`. The transcripts, the source, binary and policy identifiers, and the generations are
kept under `docs/evidence/s5-t10/`.

Scope: the server returned no hidden content in any of the 154 calls (0 scope failures). One agent answer holds five
words that also stand in a hidden file: an agent-text coincidence, explained (the orchestrator's ruling 1; its condition
checked by the verifier from the transcript). Both runs, read: supported 19 and 19 by evidence, 19 and 17 by the skill's
read-before-quoting rule (both stated, neither called the result); 0 wrong source; 11 negatives handled. Machine:
- 0 hidden-root markers in the server's results;
- 154 of 154 tool calls equal to `searchd serve` (reproduced by the verifier on its own `ReleaseSmall` build).

Isolation was by instruction: the agents had a shell. A run with the server as the agent's only tool is a 03-next row
and what a maintainer should ask for before *Validated*. Not measured here: performance, and the parity line on the
judged query set; the replay used the agents' own requests. There was no consumer, so no pin or contract
adoption. CAP-13 stays *Diagnostic*; the Report states what a maintainer would need to decide.

## R12 — Keep the queue and entry points truthful

**Evidence:** the active DS-00 section of [IMPROVEMENT-BOARD.md](../../IMPROVEMENT-BOARD.md)
still describes body-only retrieval and unclaimed filename implementation;
the live system and newer S-series records show it shipped. The CFT-09 queue
summary also overstates what is missing. Older dated queue sections preserve
past next-step instructions, making it easy to repeat completed work.

**Implementation:**

1. Have the relevant board/orchestration owner reconcile current statuses against
   verified task records and open claims such as #17/#20. Do not edit another
   orchestrator's board or close claims solely from this review.
2. Keep a short current entry point linking historical reports; mark outdated
   guidance historical and refine CFT-09 to the interchange gap.
3. Add lightweight link/status consistency checks only for genuinely machine-
   decidable relationships; do not infer capability validation from a PR being merged.

**Exit:** a new session can identify shipped behavior, the active task and remaining
blockers without reading contradictory "unclaimed" instructions. No historical
failed result, judgment or source provenance is erased.

## Delivery discipline and task split

Each implementation ticket should name one builder, an independent verifier,
its before snapshot and acceptance rule. The orchestrator cuts/coordinates
tickets; narrow implementation can use a smaller model; independent verification
must reproduce the claim and any planted regression. Model roles do not replace
named-maintainer approval where the capability process requires it.

For runtime changes, follow [ROLES](../process/ROLES.md): Debug and ReleaseSmall
native/ABI suites, fresh native-backed Python where relevant, and the judged
gate on both surfaces. Unset `SEARCH_SIMPLI_LIBRARY_PATH` so tests do not load a
consumer's stale pin. Rebuild digest-covered native inputs with the documented
toolchain and supported platform packaging; do not resolve native/stamp conflicts
by choosing a side. No index rebuild is presumed just because query code changes.

For each ranking/performance candidate, retain before/after results, failed
attempts, source identities, scope checks and a rollback comparison. Use the
existing requirements/capability process for new observable behavior, wire
fields, formats or changed matching policies. Pending criteria stay pending;
this review neither invents acceptance thresholds nor approves exceptions.

## Evidence from this review

- Requirements register validation passes.
- Fresh dependency-free Python baseline: **318 tests run, OK with 49 skips**;
  native execution was disabled deliberately. No native/FFI/Dart rebuild or
  platform validation is claimed for this documentation review.
- The small verb-form helper probes above were executed, not a judged search
  comparison. The first scratch import failed because the root compatibility
  package shadowed `src`; it was corrected to the repository tests' import setup.
- Independent source reviews checked retrieval and lifecycle/CI paths. Prior
  timing/J2 numbers cited above come from existing task reports and the live
  queue, not new benchmark runs.

[Machine-readable scope, probe results and log hashes](2026-11-11-search-review-evidence.json).
Runtime, native artifacts, contracts and frozen benchmark baselines are unchanged.
