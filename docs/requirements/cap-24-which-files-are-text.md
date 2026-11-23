# CAP-24 — Which files are text: a walk reads a file when its bytes are text

Status: Accepted under the maintainer's direction of 22 Nov 2026 (text first; plan step H2); recorded for his review · designed in [ADR 0005](../decisions/0005-which-files-are-text.md), built by [S6-T23](../tasks/S6-T23.md) Part 2 (rulings after Part 1). Not Validated

The number: on `main` at `8ffc41c` the highest capability is CAP-23, the
highest functional requirement FR-33, the highest non-functional requirement
NFR-17 and the highest conflict CFT-30 (register tables and the
specification's proposed appendix; a search of every tracked file finds no
higher id but the validator test's invented `CAP-77`). No open branch adds a
record under `docs/requirements/`. So this record takes **CAP-24**,
**FR-34**, **FR-35**, **FR-36**, **NFR-18** and **CFT-31** to **CFT-33**.

## 1. Proposal

- **Problem / what should be possible:** the engine's walk reads 19 file
  extensions (`zig/src/core/indexer.zig:39`, mirrored by
  `src/search_platform/core.py:42`) and skips every other file without
  counting it. On the judged set's folder ([S6-T22](../tasks/S6-T22.md)) 24
  of 270 files are never read (12 logs, 4 CSV, 2 TSV, a shell script, an XML
  sitemap, `TODO`, `NOTES`, `Makefile`, `README`), so 31 questions name a file
  the engine cannot see and the 23 whose answers sit only there cannot be
  answered. The usage scenarios of 22 Nov 2026 found the same from outside
  (I02, I10). A file that is never read cannot be found.
- **Who it serves:** human user (a person searching their notes, exports,
  logs and tables) · agent user (a model told how many files were not read,
  and of what kind) · contributor (one rule in one place, the same in the
  Python reference).
- **HIO tie:** organic — the person's own files, whatever they named them,
  are what the engine reads.
- **One-line success notion:** every file of a folder whose bytes are text is
  read, with any extension or none; known non-text kinds are skipped without
  opening them; what is not read is counted by kind.

## 2. Motivating use case(s)

- Primary use case: [`UC-001`](../use-cases/uc-001-personal-files.md)
  (personal files: notes, exports, logs, tables).
- Other affected use cases: [`UC-007`](../use-cases/uc-007-family-folders-on-a-phone.md)
  (an app indexing whole family folders through `ss_index_folder`),
  [`UC-006`](../use-cases/uc-006-directory-filename-search.md) (file names of
  newly read files join the file-name channel),
  [`UC-002`](../use-cases/uc-002-codebase-agent.md) (shell scripts, `Makefile`,
  `.rb`, `.swift` and other source the 19 extensions leave out).

## 3. Functional requirements (new or changed)

| ID | Requirement (testable) | New / changes | Traces to |
|---|---|---|---|
| FR-34 | The engine's walk (`searchd index`, `index --update`, `searchd search`, `ss_index_folder`) reads a regular file under `text-sniff-v1`: (1) a path that is not a valid record path (a carriage return, line feed or NUL in it, not UTF-8, or too long) is not read, kind `bad_name`, and never fails the walk; (2) a path with a component starting with `.` or naming an ignored directory is not walked, as before, and not counted; (3) a lowercased last extension on the skip list is not opened, its kind one of `image`, `audio`, `video`, `archive`, `document`, `font`, `program`, `database`; (4) otherwise the first 8,192 bytes decide: empty is text; a UTF-16 or UTF-32 byte order mark is text in another encoding (`unreadable`, path listed); a NUL byte, or more than 1 % control bytes (0x01–0x08, 0x0E–0x1A, 0x1C–0x1F, 0x7F), is kind `binary`; not UTF-8 (a final sequence cut by the 8,192nd byte allowed) is `unreadable`; else text; (5) a text file is read whole as before (`too_large` over `max_file_bytes`, `unreadable` when not UTF-8 anywhere). `.md` and `.markdown` choose `md-section-v1`, every other file `line-window-v1`, as before. A host's `apply_changes` batch is unchanged: the engine reads what the host names. The Python reference walk (`_iter_text_files`) applies the same rule. | changes FR-01 | UC-001, UC-007, UC-002 |
| FR-35 | A walk's report counts the files it did not read, by kind, without paths: `not_read`, an object of the kinds of FR-34 with a non-zero count, keys in byte order, `{}` when none, on the `index --update` JSON and the `ss_index_folder` JSON (both forms); the `searchd index` line ends ` not_read=N` (the total); the `searchd search` stderr line counts them in its total and as `not_read=N`. Not-read files are not in the manifest's `skipped` list and do not make a scope `truncated`. The Dart `IndexFolderReport` gains `notRead` (`{}` when the field is absent). | new | UC-001, UC-007, UC-002 |
| FR-36 | Every generation a walk publishes records the rule in the manifest meta: `"readable":{"id":"text-sniff-v1","head_bytes":8192,"control_share_max":0.01}`. A generation published by a host batch or by import carries no `readable` key, nor does one published before contract 2.9.0. Readers that do not know the key ignore it (no format version, header or flag changes); the engine opens every older index unchanged. An index built before 2.9.0 takes the newly readable files at its next `--update` as `added`, with no rebuild; a file of a known extension the rule now calls `binary` is `removed`. | new | UC-001, UC-007 |

## 4. Non-functional impact

| ID | Requirement / impact | Target or constraint |
|---|---|---|
| NFR-18 | The rule's cost: a file whose name today's 19 extensions read pays only the head checks on bytes already read (no extra open); a file of any other name not on the skip list pays one read of at most 8,192 bytes before its whole read; a file on the skip list is not opened. On the three 10k corpora (every file `.md` and text) the answers are byte-identical to `main`'s and the index folders differ only in `MANIFEST` (the `readable` key and the checksum over it). | Measured in ADR 0005 §2 and §8 (0.34 to 0.45 % of index time on the 10k corpora by a standalone benchmark); restated from the built engine in the S6-T23 Report; the open, query and find cells under the timing rule of 2026-11-17. No threshold as a test (ROLES). |
| NFR-02 / INV-07 | The manifest meta gains one key, additive. | Older readers ignore it (`manifest.zig` parses meta with `ignore_unknown_fields`); a test parses a meta with the key through the reader. |
| NFR-05 / INV-03 | Unchanged: newly read files carry their root's labels like any other; nothing is read across the label wall. | Existing label tests. |
| NFR-01 / INV-06 | No dependency added. | Zig standard library; Python standard library. |
| Privacy | Dot-files and dot-folders (`.env`, `.ssh/`, `.git/`) stay unwalked and uncounted. | Test: a dot-file with a sniffable name is not read. |

## 5. Contracts touched (CON)

- New or changed schemas under `contracts/`: none. No request field, no
  signature, no tool schema under `contracts/tools/` changes;
  `apply_changes` (CON-02's tool) is untouched. `contracts/CONTRACTS_VERSION`
  becomes `2.9.0`.
- The C header gains a "Contract 2.9.0" comment paragraph, the `ss_version`
  example "2.9.0", and the `not_read` field in `ss_index_folder`'s documented
  result: comments only, no declaration changes.
- Backward-compatibility plan: contracts 2.8.0 → **2.9.0** (a minor step: a
  policy of which files a walk reads, as 2.7.0 changed a policy, plus one
  additive result field), and the Dart package's minor step under its
  versioning rule (it accepts exactly its own contract version). A caller
  that ignores unknown result fields sees more files indexed and one more
  field. An existing index needs no rebuild (FR-36).

## 6. Invariant compliance (INV)

- INV-01 retrieval≠generation: complies; more evidence is read, nothing is
  generated.
- INV-02 citations: complies; newly read files are chunked and cited as any
  other.
- INV-03 pre-rank authorization: complies; labels apply to every file the
  walk reads.
- INV-04 chunker identity as index data: complies; chunker choice unchanged
  and recorded per file; the readable-set rule is recorded too (FR-36).
- INV-06 dependency-free base: complies.
- INV-07 versioned/checksummed formats: complies; one additive meta key
  inside the checksummed manifest; no version change (CFT-32).
- INV-08 deterministic ordering: complies; the walk's order and tie-breaks
  are unchanged.
- INV-09 complexity earned by measurement: complies; ADR 0005 measured the
  gain on the judged set (complete answers 100 → 109 typed and 109 → 127
  with the query words, `both`) and the cost before building.
- INV-10: complies; each claim is marked shown, measured or argued.
- INV-11: N/A.

## 7. Register updates (fill when consolidating — step 4)

- Capability catalog row (CAP-24): added.
- FR/NFR index rows added: FR-34, FR-35, FR-36, NFR-18 (and their rows in the
  specification's proposed-requirements appendix). FR-01's text in the
  specification gains the change when the build lands.
- Contracts rows added: none.

## 8. Conflict check (step 5 — required)

Checked against the register on `main` at `8ffc41c`.

- **CFT-31, CAP-24 ↔ FR-01 / CAP-09 (the Python reference's candidate set).**
  The Zig walk mirrors the Python reference's list on purpose, and the chunk
  goldens are generated from the Python walk. Resolved: the Python reference
  takes the same rule (FR-34); every repository fixture folder is read in
  full today and its files are text (ADR 0005 §6, shown by survey), so the
  goldens do not move.
- **CFT-32, CAP-24 ↔ INV-07 / NFR-02 (format backward compatibility).** A new
  meta key in every walk-built manifest. Resolved: additive; older readers
  ignore unknown meta keys (`manifest.zig:957`), shown by a test that parses
  a meta with the key; no format version, header or flag changes. Consequence,
  recorded: an older engine updating a newer index drops the newly read files
  again (`removed`); two engine versions sharing one index directory would
  alternate. Not a one-way step.
- **CFT-33, CAP-24 ↔ FR-12 / CAP-11 (the judged set's readable-now
  questions).** Reading more files changes the ranking of the questions whose
  answers were readable before: on the prototype, typed file@1 over the 146
  readable-now questions 94 → 90 and `content` complete-within-4,096-bytes
  with the query words 100 → 91. Accepted with rationale: the causes are
  ranking (a short README holding common words, shifted BM25 statistics) and
  the ten-result cut with repetitive logs, which plan steps H5 and H6 own;
  ranking is not tuned here (ruling 5), and each worsened question is listed
  in the S6-T23 Report with its cause and owner.

Considered, not conflicts: INV-03 (labels apply to every walked file);
CAP-20 / NFR-15 (direct search still writes nothing); CAP-16 (newly read
files' stems join the file-name channel through the same documents).

## 8b. Dependencies

- Capabilities/datasets this one depends on: CAP-01 (the walk and reading),
  CAP-19 (the manifest v2 meta, `apply_changes`' walk batch), CAP-20 (direct
  search's report line), the judged set of S6-T22 (the acceptance measure).
- Is any acceptance criterion dependent on an unbuilt capability? No.

## 9. Acceptance gate (step 6 — decidable before building)

- Primary metric: the judged set's full totals with
  `scripts/text_search_score.py` as merged, `both` and `content`, typed and
  query words · baseline `docs/evidence/s6-t22/baseline-rework-2.json`
  (`main`'s engine) · fixture the 270-file judged folder, its digests and
  `readable_now` list unchanged · pass: every full total rises or holds where
  the prototype measured it to (complete answers at least 109 / 127 with
  `both` and 120 / 137 with `content`, 31 → 0 questions naming an unread
  file), stated from the built engine · rule: a shortfall against the
  prototype is explained or blocks.
- Readable-now changes: reported question by question with cause and owning
  plan step; not a failure of this capability (CFT-33).
- Citation-support behavior: unchanged.
- Unanswerable / negative behavior: no-answer questions' returned counts
  reported before and after.
- Freshness target: an index built before 2.9.0 takes the newly readable
  files at its next update, without a rebuild (test).
- Performance / scale target: answers on the three 10k corpora byte-identical
  to `main`'s; index folders identical apart from `MANIFEST`; open, query and
  find cells under the timing rule of 2026-11-17 (five gated runs, controls
  matched to the code delta).
- Security / isolation tests: a dot-file and a file in a dot-folder with
  sniffable names are not read; a name with a carriage return neither fails
  the walk nor is read.
- Judged fixture / benchmark artifact: the after-H2 baseline beside the first
  in `docs/text-search-score.md`.
- `pending` criteria: the timing cells, taken when the orchestrator says the
  machine is awake.

## 10. Evidence plan (step 8)

- Tests to add: the sniff's verdicts (Zig and Python on the same bytes), the
  walk's kinds and counts, the name check (index and search with `a\r.md` and
  `Icon\r` present), the `not_read` field on every surface, the manifest key
  (written by a walk, absent from a host batch, ignored by the reader), the
  update of an older index, the Dart report's `notRead`.
- `EXPERIMENTS.md` entry planned: none; the measures are in ADR 0005 and the
  S6-T23 Report.
- `PROJECT-STATE.md` update: contracts 2.9.0, the Dart version, the rule.
- How status advances: Implemented on fixtures and the judged set; verified
  by the S6-T23 verifier; Validated is not claimed.

## 11. Open decisions

- Decoding UTF-16 and Latin-1 text: not in H2 (counted `unreadable`).
- Splitting a line longer than the window (minified files come back whole):
  a new chunker identity, plan step H5.
- Common question words ranking a short README first, and repetitive logs
  filling the ten results: plan steps H6 and H5.
- A request option to read a skipped kind through the walk: not added; a host
  includes it through `apply_changes`.

## 12. Maintainer approval (step 6b — required before build)

- Approver: accepted by the orchestrator under the maintainer's direction of
  22 Nov 2026 (text first; plan step H2), recorded for his review; the
  maintainer may overrule.
- Date: 2026-11-22.
- Commit: the S6-T23 rulings after Part 1, on `task/S6-T23` (the commit that
  adds this record).
- Status: Accepted (orchestrator, under the maintainer's direction); not
  Validated.
