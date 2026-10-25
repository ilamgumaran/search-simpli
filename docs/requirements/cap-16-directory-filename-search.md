# CAP-16 — Directory filename retrieval alongside cited content search

Status: Proposed · Evidence: future option · Not build-ready (step 6b pending)

## 1. Proposal

The owner wants free-text search over a directory's documents and filenames so
an LLM can locate and inspect relevant sources. Existing native Zig and Python
indexers already retrieve body passages with citations, but only store paths as
metadata. A separate filename lexical channel addresses this observed gap.
Humans can remember names; agents can retrieve inspectable sources. This is the
HIO seam between human recall and machine evidence retrieval.

Success: find a supported nonempty document from filename-only terms without
changing default content results or treating a filename as factual support.
Central design claim: [issue #15](https://github.com/ilamgumaran/search-simpli/issues/15).
Baseline: main `9c3265a1ed6db6fc9f3771860b91623954c039c2`.

## 2. Motivating use cases

Primary: [UC-006](../use-cases/uc-006-directory-filename-search.md).
Also serves UC-001 personal files, UC-002 codebase agents and UC-003 authorized
knowledge. Existing content evidence remains authoritative for answer claims.

## 3. Functional requirements

| ID | Requirement (testable) | New / changes | Traces to |
| --- | --- | --- | --- |
| FR-16 | Opt-in filename and combined lexical retrieval over supported files with real indexed body spans; explicit match origin, pre-rank path/label isolation, deterministic file ranking, versioned channel availability and refresh/migration behavior; default content results unchanged. | New | UC-006 |

### Retrieval policy: proposed `filename-field-v1`

- Proposed request field `search_field` is `content` (default), `filename` or
  `both`. New fields/modes require `retrieval_mode=lexical`; vector/hybrid with
  filename/both returns a clear input error. Existing content/hybrid is unchanged.
- One filename record per root-relative POSIX path that has at least one indexed
  body chunk. Filename tokens come from the final basename with its final
  supported suffix removed. Use the snapshot's analyzer for both query and stem:
  NFC/simple fold for native analyzer-v2, not a new full-casefold policy.
  Punctuation and underscores follow that analyzer. CamelCase splitting,
  substring/fuzzy/phrase operators and parent-directory tokens are deferred.
- Filename BM25 uses file-level term frequency, document frequency and length.
  Never prepend names to body chunks, change body term counts, or re-embed body
  vectors for this channel. Keep exact path bytes as identity, including case.
- Filter by trusted labels and path prefix before forming filename candidates
  or visible statistics. All chunks associated with a filename record must
  agree on required labels; reject inconsistent imported records. A filename
  anchor must reference an authorized stored chunk from the same path.
- `filename` returns at most one result per file, sorted by descending BM25,
  then bytewise path and chunk id. Its anchor is the earliest stored body span,
  ordered by start line, end line, chunk id. This is navigation, not support.
- `both` forms a body channel by each file's highest-scoring body chunk and a
  filename channel by file BM25. Truncate each to `candidate_k`, union by path,
  then equal reciprocal-rank fusion with k=60. Ties use path then chunk id.
  For a file in the body candidates use its best body chunk (score ties by chunk
  id); otherwise use the filename anchor. Return at most `top_k` distinct files.
  `candidate_k >= top_k` remains required. Scores are rankings, not probabilities.
- For the **new** `both` mode, body BM25 statistics must be scoped too: visible
  body chunk count, their average token length, and each query term's document
  frequency among those chunks. Reusing the existing scorer's snapshot-global
  statistics would violate hidden/absent score parity. Start with an exact
  scoped-statistics reference pass over the authorized/path-filtered body set;
  derive term frequencies from existing postings. Include this work and its
  explicit caller-owned workspace in cost measurements. Legacy `content` uses
  its existing scorer and remains byte-for-byte unchanged. The global scorer
  cannot be substituted in `both` merely because forbidden hits are filtered.
- Each new-mode result reports `matched_in` (`content`, `filename`, or both),
  the matched basename, actual chunk id/citation/content, component scores/ranks
  and policy id. Its evidence policy explicitly requires reading the passage:
  a filename-only hit must not be represented as answering a content question.
  Legacy content-only response shape and order remain unchanged.

### Index, refresh and compatibility

Retain the dependency-free Zig inverted index and persisted BM25 engine. The
initial SQLite suggestion made before repository access is superseded by this
audit: another engine is unnecessary for the measured gap.

Propose an opt-in `--filename-index` build setting, recorded as channel/policy
identity. A versioned manifest revision binds a checksummed filename catalog and
lexical section to the same body generation. The catalog binds each path, labels
and anchor chunk id; loaders validate references, bounds and checksums. Exact
wire constants and schema revision are frozen in DS-01 before runtime work.
No unchecked mutable sidecar or scan of source files is allowed at query time.

New readers continue to open old body-only snapshots for content queries.
Filename/both against an old snapshot returns `FilenameIndexUnavailable` with
the rebuild option. Old readers reject the new manifest explicitly. Rebuild into
a separate output directory; retain the prior snapshot for rollback. Switching
the setting or analyzer requires a full rebuild, never silent incremental reuse.
Rename is remove/add; content change, deletion, relabeling and byte-budget carry
forward must update body and filename channels in one atomic generation.
Unsupported/empty files do not acquire fictitious content citations.

## 4. Non-functional impact

No new NFR id. Apply NFR-01 dependency-free base, NFR-02 explicit versioning,
NFR-03 determinism, NFR-04 bounded workspace, NFR-05 pre-rank isolation and
standing NFR-07/08 evidence discipline. Candidate union is bounded by twice
`candidate_k`; time/memory measurements precede further indexing machinery.

## 5. Contracts touched

CON-01 gains match-origin/policy information only in new-mode responses;
CON-02 specifies the opt-in request parameter; CON-03 gains optional versioned
filename-channel import data. Document the manifest revision and status capability
alongside these schemas. C ABI/Dart JSON options and contract version must evolve
together. No existing schemas or `CONTRACTS_VERSION` change in this design PR.

## 6. Invariant compliance

| Invariant | Compliance / boundary |
| --- | --- |
| INV-01 | Filename navigation is explicitly distinct from answering; no generation or confidence calibration added. |
| INV-02 | All returned hits reference actual stored chunks; empty/unsupported files remain outside passage retrieval. |
| INV-03 | Names, candidate statistics, warnings, reads and lists use trusted authorized/path-filtered views; hidden/absent parity required. |
| INV-04 | Body chunker/embeddings are unchanged; record filename analyzer/policy and reject incompatible incremental reuse. |
| INV-05 | Exact vector scan is untouched; new modes are lexical only. |
| INV-06 | Reuse current Zig/Python primitives; no packages, SQLite or required neural provider. |
| INV-07 | Versioned/checksummed atomically bound channel; explicit old/new reader matrix and rollback. |
| INV-08 | Fixed policy, sorted path/chunk ties, bounded candidate union. |
| INV-09 | Current filename-only misses motivate only one lexical field; measure cost before fuzzy, ANN, field weighting or watchers. |
| INV-10 | Current diagnostic and future acceptance are distinguished; native/device checks reported separately. |
| INV-11 | No adaptive ranking, truth inference or holdout-driven tuning; frozen default content oracle remains. |

## 7. Register updates

CAP-16/FR-16 added as proposed, traced through UC-006 and the specification's
proposed appendix. No NFR/CON ids added. CFT-17–19 record the new tensions.

## 8. Conflict check

Checked against all current register entries at the baseline above.

| CFT | Tension | Resolution | Status |
| --- | --- | --- | --- |
| CFT-17 | Filename ranking could rewrite body statistics or imply answer support (FR-03/06, INV-01/02). | Separate field, explicit navigation origin, real anchor, opt-in default; no body-term injection. | Resolved (design) |
| CFT-18 | Filename catalog/stats could reveal hidden paths or stale labels (INV-03, FR-08/09). | Shared trusted prefilter, reject conflicting labels, hidden/absent parity, atomic refresh. | Resolved (design) |
| CFT-19 | Additional channel could silently change snapshots/contracts (INV-04/07). | Versioned manifest/import capability, explicit unavailable error, separate-directory full rebuild, legacy content parity and rollback. | Resolved (design) |

These are proposed design resolutions for maintainer review, not implemented
compliance evidence or approval. Existing CFT-03/CFT-09 and E-01A/CAP-14 gates
remain unchanged; this work does not depend on those proposed capabilities.

## 8b. Dependencies

Implemented CAP-01/02/05/06/07/08/09/10. DS-01 must freeze exact schemas and
format compatibility before build. Named step-6b approval is pending. Native
library rollout needs an equipped Xcode Mac, pinned Zig/NDK and matching Dart
tests. PR #11 recovery integration and its S1-T21 numbering conflict remain
separate; do not merge it or substitute stale binaries to finish this task.

## 9. Acceptance gate

Diagnostic gates below compare the recorded body-only baseline to the candidate.
DS-01 commits the full fixture hashes and frozen expected results before DS-02;
no threshold tuning on those results. All specified cases must pass to ship.

1. Filename top-1 success: six invented cases (underscore, hyphen, mixed case,
   spaces, composed/decomposed Unicode, Tamil). Body text excludes the queried
   filename tokens. Baseline misses are recorded; candidate must hit all six.
2. Evidence: every new-mode result has a resolvable same-path stored chunk,
   exact source lines/content, and correct match origin. Zero fabricated spans.
3. Default parity: existing full Python/Zig tests and complete default-content
   golden ranking/citation outputs unchanged; match origins/policy are absent in
   legacy responses. All native ABI, CLI, RPC, gateway and Dart affected suites pass.
4. Combined determinism: hand-computed two-channel rank/fusion fixture, equal
   scores, candidate-depth boundary and duplicate paths exactly match the oracle.
5. Negatives: absent tokens, suffix-only terms, hidden/ignored files and unsupported
   or empty files return no new-mode results. Filename-only hits explicitly do
   not count as answer-support positives. No calibrated refusal claim is made.
6. Isolation: trusted principal/path views return byte-identical caller-visible
   results, scores, warnings and counts when hidden documents are absent versus
   present, holding visible generation/policy metadata fixed. New-mode response
   counts/statistics are scoped; omit global corpus counts from that response.
   Denied read/list and inconsistent imported-label tests must pass.
7. Freshness/migration: next explicit refresh handles change, rename, deletion,
   relabel and budget exhaustion consistently across both channels; publication
   fault injection cannot mix generations. Old/new reader matrix and corrupted
   channel/checksum/reference plants fail as specified; old body content works.
8. Cost: record baseline/candidate wall index time, snapshot bytes, open/steady
   query p50/p95, peak RSS and errors over one fixed 1,000-file synthetic corpus,
   pinned seed/analyzer/build, 3 fresh builds and 30 fixed queries. Required:
   zero errors, bounded candidate count and all correctness gates above. This
   measures cost, not a device latency guarantee or a justification for scale work.

Pending (not required for the bounded diagnostic release): representative human
folder relevance and handheld/desktop latency budgets, supplied/reviewed by the
owner before claiming validated/operational status. No private folder is needed
for synthetic correctness gates. Format freeze in DS-01 is a required prerequisite,
not a deferrable implementation detail.

## 10. Evidence plan

[Directory task split](../tasks/directory-search.md) assigns DS-01–DS-05, baseline,
tests, platform evidence and rollback. Append experiments, update PROJECT-STATE
and register status only as actual evidence warrants. This draft remains Proposed;
an independent technical review does not supply maintainer approval.

## 11. Open decisions

Maintainer: approve scope/policy and exact DS-01 schema revision before build.
Owner: supply real-folder and device budgets later. Performance data may justify
deferring combined ranking; it cannot silently enable fuzzy/semantic expansion.

## 12. Maintainer approval

Required by [step 6b](../capability-process.md#6b-maintainer-approval-gate).
Approve invariants (§6), CFT-17–19 (§8) and gates/pending scope (§9), plus final
DS-01 format freeze, against the reviewed commits before implementation.

- Approver: Pending named maintainer; the author cannot self-approve.
- Date: Pending.
- Commit: Pending final reviewed specification / DS-01 revision.
- Status: Pending approval; no runtime capability is authorized by this record.
