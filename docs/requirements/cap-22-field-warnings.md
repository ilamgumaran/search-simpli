# CAP-22 — Query warnings under every search field

Status: Implemented (S6-T5), awaiting verification · built by [S6-T5](../tasks/S6-T5.md) (objective 3, item G of the [objective plan](../plans/2026-11-16-objective-plan.md)). Not Validated

The number: CAP-21 is free on `main` at `1c15b19`, but the unmerged S6-T6
draft (`task/S6-T6`) claims it, with the next four functional requirement
numbers and the next non-functional one, so this record takes CAP-22 and
FR-31.

## 1. Proposal

- **Problem / what should be possible:** `ss_query`'s `warnings` say why a list
  is empty or poor: a word no file in scope holds (`query_term_unmatched`), a
  misspelling also searched as near words (`query_term_expanded`, fuzzy-v1), a
  word also searched as its other forms (`query_term_grouped`, fold groups).
  Before S6-T5 they were computed under `search_field` `content` only; under
  `both` and `filename` the array was always empty (`filename_response.zig`
  since PR #21), although `both` searches the same groups `content` does. A
  caller of `both` could not tell that a word was missing or that other words
  were searched for it. The schema, the C header and the policy documents
  describe the warnings with no field exception.
- **Who it serves:** agent user (an LLM caller needs to know a word was
  expanded or unmatched, whatever the field: the plan's decision for item G) ·
  human user (an app shows the same hint under every field).
- **HIO tie:** the seam — the report says what the engine did with the words
  the person typed.
- **One-line success notion:** under `both` the warnings are `content`'s, except
  that a word a visible file name holds is not unmatched; under `filename` a
  word no visible file name holds is unmatched; and a word only hidden files
  hold is reported exactly as an absent word.

## 2. Motivating use case(s)

- Primary use case: [`UC-006`](../use-cases/uc-006-directory-filename-search.md)
  (directory content and filename search: `filename` and `both` are its fields).
- Other affected use cases: [`UC-007`](../use-cases/uc-007-family-folders-on-a-phone.md)
  (an app on the phone, through the Dart binding over `ss_query`),
  [`UC-002`](../use-cases/uc-002-codebase-agent.md) (an agent reading the report).

## 3. Functional requirements (new or changed)

| ID | Requirement (testable) | New / changes | Traces to |
|---|---|---|---|
| FR-31 | `ss_query` computes `warnings` under `search_field` `both` and `filename`. Under `both` they are the warnings `content` gives for the same request (codes, order, messages, `expansions` and `members`), except that a word is `query_term_unmatched` only when neither a chunk in scope nor a visible file name holds it; its `query_term_expanded` and `query_term_grouped` report exactly the groups `both` searched. Under `filename` the only term warning is `query_term_unmatched`, for a word no visible file name holds. A word only hidden files or names hold gets warnings identical, byte for byte, to an absent word's. `content` answers are unchanged on every surface; no request field, warning code or result field is added. | new | UC-006, UC-007, UC-002 |

**The rule, in full.**

- *The terms* are `content`'s: each distinct analysed query term once, at its
  first occurrence, in query order, spelled as the query analyses it
  (lowercased under `ascii-alnum-v1`, NFC and case-folded under
  `analyzer-v2`), never as the index spells it.
- *A visible file name* is a file's name as the file-name channel searches it
  (the stem, `filename-field-v1`), for a file in scope: the request's roots,
  path prefix and labels, the same test the channel applies before it ranks.
  A word only a file's **folder** names hold is not a file name: under `both`
  it stays unmatched, as it is under `content` (open decision, §11).
- *`both`.* Unmatched: no chunk in scope holds the word (the test `content`
  makes) and no visible file name holds it. Expanded and grouped: the fuzzy-v1
  and fold groups `both` built for its body and title parts, which are
  `content`'s groups for the same request (`Engine.bothGroups`). An expanded
  word is always unmatched: fuzzy-v1 expands only a word no chunk in scope and
  no visible title holds, so no visible file name holds it.
- *`filename`.* The file-name channel searches each word as typed and nothing
  else: it is never expanded (fuzzy-v1 runs on the body and title parts only,
  `docs/fuzzy-v1.md`) and never grouped (the fold groups apply to the lexical
  channel under `content` and `both`, `docs/fold-groups-v1.md`). So **no
  `query_term_expanded` and no `query_term_grouped` can appear under
  `filename`**: reporting one would name words that were not searched.
- *The other codes.* `query_empty_after_analysis` (a query with no searchable
  term) and `vector_ignored` (a vector passed to a lexical request; `both` and
  `filename` are lexical only) follow the same state as under `content`.
  `candidate_depth_cut` cannot occur (lexical, and `ss_query` refuses
  `candidate_k < top_k`).
- *Order and wording* are `report.zig`'s, written by the same code as under
  `content`.

## 4. Non-functional impact

| ID | Requirement / impact | Target or constraint |
|---|---|---|
| NFR-05 / INV-03 | The warnings cross the label wall exactly as `content`'s: a word only a hidden chunk, file or file name holds gives an absent word's bytes. | `zig/src/field_warnings_test.zig` compares hidden and absent pairs (labels, roots, path prefix) under `both` and `filename`. |
| NFR-03 | Deterministic: the order is the query's. | Same writer as `content`. |
| Latency | `both` and `filename` pay for the terms' lookups and the warning objects; `content` pays nothing. | Stated in advance and measured by S6-T4's five-run rule ([S6-T5](../tasks/S6-T5.md) Report). No threshold as a test (ROLES). |
| NFR-01 / INV-06 | No dependency added. | Zig standard library only. |

## 5. Contracts touched (CON)

- New or changed schemas under `contracts/`: none. CON-01's `warnings` text
  and the C header's describe the warnings with no field exception, so both are
  untouched (S6-T5 ruling 5); this record, the Dart CHANGELOG and the policy
  documents carry the 2.8.0 note. The header has no "Contract 2.8.0"
  paragraph, unlike 2.2.0 to 2.7.0: whether to add one (comments only) is an
  open question in the S6-T5 Report.
- Backward-compatibility plan: contracts 2.7.0 → **2.8.0** and Dart 0.8.0 →
  **0.9.0**, the rule of every earlier observable change of `ss_query`'s output
  (S5-T2 to S5-T8): a minor contract version, and a minor Dart version because
  the package accepts exactly its own contract version. Additive: a caller that
  ignored an empty array under `both`/`filename` sees entries it already knows
  how to read (no new code). No index format change and no rebuild.

## 6. Invariant compliance (INV)

- INV-01 retrieval≠generation: complies; the warnings describe the retrieval.
- INV-03 pre-rank authorization: complies; hidden and absent are identical
  (the label-wall test), and visibility is the channel's own pre-rank test.
- INV-06 dependency-free base: complies.
- INV-07 versioned/checksummed formats: complies; nothing stored.
- INV-08 deterministic ordering: complies; query order.
- INV-09 complexity earned by measurement: complies; the trace exists already
  and is filled only for `ss_query`; the cost is measured.
- INV-11: N/A.

## 7. Register updates (fill when consolidating — step 4)

- Capability catalog row (CAP-22): added.
- FR/NFR index rows added: FR-31 (and its row in the specification's
  proposed-requirements appendix). No NFR row.
- Contracts rows added: none.

## 8. Conflict check (step 5 — required)

No conflicts found against the current register as of `1c15b19` (S6-T5 base).
The tension considered: a warning computed from file names could tell a caller
that a hidden file's name holds a word (INV-03, CFT-18); visibility is decided
by the same roots, prefix and labels test the channel ranks with, and a test
holds hidden and absent words to identical bytes, so it is not a conflict.

## 8b. Dependencies

- Capabilities/datasets this one depends on: CAP-16 (the file-name channel),
  the title field (S5-T2), fuzzy-v1 (S5-T3), the fold groups (S5-T4 to S5-T8),
  the query report (S2-T4).
- Is any acceptance criterion dependent on an unbuilt capability? No.

## 9. Acceptance gate (step 6 — decidable before building)

- Primary metric: the tests of FR-31 (`zig/src/field_warnings_test.zig`, the
  Dart `contract 2.8.0` group) · baseline `main` `1c15b19` (always `[]`) ·
  tolerance zero.
- Citation-support behavior: unchanged.
- Unanswerable / negative behavior: an absent word is `query_term_unmatched`
  under both fields; a hidden word is reported identically.
- Freshness target: N/A (per request).
- Performance / scale target: S6-T4's five-run rule on the three 10k corpora
  under `content`, `both` and `filename`; a `both`/`filename` cell may exceed
  it only by a cost predicted before measuring; a `content` cell may not.
- Security / isolation tests: the hidden/absent pairs.
- Judged fixture / benchmark artifact: `content` answers byte-identical on the
  captured-answers comparison (`scripts/capture_query_outputs.py`) and J2
  clean without re-recording.
- `pending` criteria: none.

## 10. Evidence plan (step 8)

- Tests to add: `zig/src/field_warnings_test.zig` (6 tests), a Dart group of 2
  tests, four plants (S6-T5 Report).
- `EXPERIMENTS.md` entry planned: none; the cost is in the S6-T5 Report.
- `PROJECT-STATE.md` update: contracts 2.8.0, Dart 0.9.0.
- How status advances: Implemented on fixtures; verified by the S6-T5
  verifier; Validated is not claimed.

## 11. Open decisions

- Decision: whether a word only a visible file's folder names hold (the title
  field, not the file-name channel) should count as held under `both`. Today
  it is unmatched under `content` and stays so under `both`.
- Owner: the maintainer.
- Evidence needed: a J2 row where a folder name answers the query.
- Decision: the Python reference gives no warnings in any field; whether it
  should.
- Owner: the maintainer.
- Evidence needed: a consumer of the reference's report.

## 12. Maintainer approval (step 6b — required before build)

- Approver: approved by the orchestrator under the maintainer's instruction of
  16 Nov 2026 (see the [plan](../plans/2026-11-16-objective-plan.md)); the
  maintainer may overrule.
- Date: 2026-11-16.
- Commit: S6-T5 task file on `main` at `1c15b19`.
- Status: Approved (orchestrator, under instruction); not Validated.
