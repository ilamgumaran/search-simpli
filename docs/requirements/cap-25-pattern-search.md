# CAP-25 — Pattern search: `scan`, exact strings and a small pattern language, line by line

Status: Implemented on `task/S6-T24` (S6-T24 Part 2), awaiting timing, verification and merge · accepted under the maintainer's direction of 22 and 23 Nov 2026; recorded for his review · designed in [ADR 0006](../decisions/0006-pattern-search.md), built by [S6-T24](../tasks/S6-T24.md) Part 2 (rulings after Part 1); the user document is [scan](../scan.md). Not Validated

**Numbering.** On `main` at `43a308d`, the highest ids are CAP-24, FR-36, NFR-18 and CFT-33. These come from the
register tables and the specification's proposed appendix. No open branch adds a record under
`docs/requirements/`. So this record takes **CAP-25**, **FR-37** to **FR-41**, **NFR-19**, **NFR-20** and
**CFT-34** to **CFT-36**.

## 1. Proposal

- **Problem.** An exact string cannot be searched today. `142.50` becomes the tokens `142` and `50`, and
  quotes are ignored outside `find`. A shape such as "a line that starts with a date" cannot be asked at all.
  There is no pattern code in `zig/src/` (ADR 0006 §1). The maintainer's direction of 22 Nov 2026 makes simple
  token and pattern matching ("like `sed`, `awk`") the base of text search.
- **Who it serves:**
  - a human user: a number, a code or a phrase exactly as written;
  - an agent user: an oracle that returns every line holding a string, with no ranking;
  - a contributor: one matcher, the same in the Python reference.
- **HIO tie:** organic. The person's own words, numbers and codes are found as they wrote them.
- **One-line success notion:** every line in scope that holds the string, or matches the pattern, comes back,
  and no other line does, in path then line order, in pages, inside a time budget.

## 2. Motivating use case(s)

- Primary: [`UC-001`](../use-cases/uc-001-personal-files.md), personal files (amounts, dates, reference codes,
  quoted phrases).
- Also:
  - [`UC-002`](../use-cases/uc-002-codebase-agent.md): an agent greps a codebase through the engine;
  - [`UC-004`](../use-cases/uc-004-mcp-external-agent.md): the MCP tool `scan`;
  - [`UC-007`](../use-cases/uc-007-family-folders-on-a-phone.md): exact words on a phone through `ss_scan` and Dart
    `scan`.

## 3. Functional requirements (new)

| ID | Requirement (testable) | New / changes | Traces to |
|---|---|---|---|
| FR-37 | A read-only operation `scan` exists on every interface: `searchd scan <dir> "<pattern>"` over an index, `searchd scan --folder <folder> "<pattern>"` over a folder, `ss_scan(handle, request_json)`, the RPC method and MCP tool `scan` (read-only; not in `--baseline`), Dart `SearchSimpli.scan`, and the Python reference `scan` / `scan_folder`. The request is ADR 0006 §15.1, with an unknown field refused. The result is ADR 0006 §15.2 in `find`'s envelope (`request`, `generation`, `scope`, `warnings`), and its schemas are `contracts/tools/scan.{request,result}.schema.json`. A hit is a line: `root_id`, `path`, `line`, `text` (at most 512 bytes, cut at a code-point boundary; in regex mode cut where a 17th non-empty match starts), `text_truncated`, `matches_truncated` (true only for that cut, so a caller can tell it from the 512-byte one; S6-T24 rework 2, ruling 4), `match_offsets` (code-point pairs into `text`, non-empty matches only, at most 16 in regex mode), `before`, `after`. Order is `root_id` by bytes, then the root-relative path by bytes, then the line. `find`'s contract does not change. | new | UC-001, UC-002, UC-004, UC-007 |
| FR-38 | The pattern language and matching (ADR 0006 §2–§5, with the rulings after Part 1). `literal` is the default mode and has no special characters. `regex` is the subset of ADR 0006 §2, plus `\t`; everything outside it is refused with `invalid_argument` and the message `pattern not supported at byte <n>: <reason>`, as tabulated. Matching is per line. A line excludes its terminator and, for line 1, a leading BOM; lines are numbered as `read_span` numbers them. `case` is `sensitive`, `insensitive` (the analyser's simple fold per code point) or `smart` (insensitive unless a code point written in the pattern changes under the fold), and the answer names `case_applied`. `whole_word` requires no word code point before or after the match. `\w` and `\b` use the analyser's word code points (letters, digits, marks, ZWNJ, ZWJ; **not** `_`), `\d` is Unicode Nd and `\s` is the analyser's whitespace. No accent, mark or NFC folding. Offsets follow Python's `finditer`, empty matches dropped, and only matches starting within `text`. A pattern that can match the empty string gives the warning `pattern_matches_empty`. The Python reference accepts and refuses the same patterns with the same messages and returns the same hits. | new | UC-001, UC-002 |
| FR-39 | Two sources, one result. Over an index, the bytes come from the source section. Files that cannot be searched are counted by reason and make the answer `truncated` ("the corpus may be incomplete", `find`'s meaning): pending, `too_large`, `unreadable`, `budget_exhausted` and roots without retained source (`not_scanned`, `pending_files`). Over a folder, the walk applies the text rule (`text-sniff-v1`) and the read applies the size cap, the re-sniff and the UTF-8 check, through one function shared with `apply` (its pure part). Files not read are counted as `not_read`, as the walk reports them. Nothing is written anywhere, and `root_id` is `r-legacy`. The same request over a folder and over a `searchd index` of it returns identical hits. | new | UC-001, UC-007 |
| FR-40 | Paging. `page_size` is 1–100 (default 20) and `next_cursor` is the only paging signal. Over an index, a cursor names its generation. A cursor from another generation is refused with `invalid_argument` "stale cursor", as `find` does. A cursor from another request (pattern, mode, case, word, scope, glob, cap) is refused with "cursor does not belong to this request", and an unreadable one with "malformed cursor". The cursor's file is an ordinal among all the files the caller may see, before `path_prefix` and `name_glob`, which are tested on each path as the scan reaches it, inside the budget (rework 2, ruling 1). Over a folder, the cursor names the walk's sorted path list: an added, removed or renamed file makes it stale, and **an edit between pages is not detected** (ruling O-4). `max_hits_per_file` (1–1,000, default 50) caps a file's hit lines and counts the file in `files_capped`. Counts are attributed to the page where a file's scan finishes, so their sums over pages are the totals. | new | UC-001, UC-004 |
| FR-41 | Budget. `time_budget_ms` is 1–30,000, default 2,000, on a monotonic clock. A page that runs out ends with `stopped: "time"` and a `next_cursor` strictly after the request's cursor, and never presents a partial page as complete. A line that alone outlasts the budget, so that no position past the request's cursor was completed, is refused with `capacity` (`SS_ERR_CAPACITY`, an existing code): "line <n> of <root_id>/<path> outlasts time_budget_ms (<b>): raise it (at most 30000) or narrow the scope", or, when the budget went on reading the file before the line, "time_budget_ms (<b>) ran out reading <root_id>/<path>, and line <n> did not finish in the 10 ms after: …" (the first line of a page has 10 ms of grace; S6-T24 rework 1). A scan holds its caller for at most the budget plus 50 ms, compiling and the `path_prefix`/`name_glob` filter included, with three things excepted and stated: the folder walk, over an index the list of files the caller may see (with the scope's pending and skipped files tested against `path_prefix` and `name_glob`, one step per byte), and the read of the file in hand (`docs/scan.md`). Every unit of the budget's meter is a bounded amount of work (rework 2, ruling 2): a step on a class charges one unit per binary search it may do, and a class is normalised when compiled so that a test is at most five. So no cursor can be returned twice and no caller can loop forever (ruling O-7). There is no cancel; `stopped` is `"none"` or `"time"`. | new | UC-001, UC-004, UC-007 |

## 4. Non-functional impact

| ID | Requirement / impact | Target or constraint |
|---|---|---|
| NFR-19 | Matching costs time linear in the line: a Pike VM, at most one thread per instruction per code point. A program is capped at 8,192 instructions and a repeat bound at 255; compiling is capped at 8,192 steps of work, emitted or not, and a repeat of what can only match the empty string is kept once. Listing a line's matches is at most 17 passes plus one per code point of its text where an empty match starts (at most 16 non-empty matches a line in regex mode; empty ones neither count nor cut); the literal search is linear (Knuth-Morris-Pratt); a `name_glob` match reads each byte of the name once (shift-and over the glob's states). All of it is metered against the budget, and every unit of the meter is bounded work: at most 12 counted steps a unit, and at most 139,268 units between two reads of the clock (rework 2, ruling 2). Nothing is allocated per line after set-up, and no table grows with a file's lines. One file's bytes are in memory at a time. | Tests: `(a+)+b` over growing lines shows a growth ratio near 2 per doubling; a scan under a 64 MiB arena cap over a 10 MiB file (NFR-13's form); S6-T24 rework 1's listing and literal slopes and the page's peak over 10 MiB of line breaks; rework 2's counted tests: the compile of every fuzz pattern up to 1,024 bytes within 500,000 steps, the work per unit and per meter interval on the heaviest units and every fuzz pattern, and the glob's steps per byte. A test asserts a count or a ratio, never a wall-clock threshold; the times behind the stated constant are measured by scripts outside the default run (`scripts/prototypes/s6t24/rework2/`). |
| NFR-20 | Nothing existing changes. Ranked search, `find` and `evidence` answers are byte-identical to `main`'s on the three 10k corpora and on the judged set. The 181 judged questions, their judgments and digests are untouched. No index format changes. | Shown in the S6-T24 Report with `main`'s and the head's `searchd` on the same indexes; `tests/test_text_search_score.py` unchanged and passing. |
| NFR-13 | Bounded workspaces. | `scan` reads one file at a time; tested under the 64 MiB cap. |
| NFR-01 / INV-06 | No dependency. | Zig standard library; Python standard library (`re` used only behind the reference's own subset parser). |
| NFR-05 / INV-03 | Labels and roots filter before any file is read. A hidden file is never scanned and not counted. | Test: a hidden file's line never appears and its file is not counted. |

## 5. Contracts touched (CON)

- New schemas: `contracts/tools/scan.request.schema.json` and `contracts/tools/scan.result.schema.json`, beside
  the other tool schemas (CON-02's family). No existing schema changes.
- C ABI: one new function, `char *ss_scan(ss_handle *handle, const char *request_json)`, with the same memory
  and error conventions as `ss_find`. The header gains a "Contract 2.10.0" paragraph. No existing declaration
  changes, and no error code is added: the over-budget line uses `SS_ERR_CAPACITY`.
- No index format, manifest key or flag changes.
- **Version: contracts 2.9.0 → 2.10.0, Dart 0.11.0 → 0.12.0.** No written rule in the repository fixes the size
  of the step. `CONTRIBUTING.md` 144–147 and `search_simpli.h` 5–7 require a step and this document, but say
  neither minor nor major. The minor step follows the practice since 2.0.0 (ADR 0006 §12): every additive change
  since then has been a minor step, and CAP-21 proposed a minor step for a new method. **This is a question for
  the maintainer**, listed in §11.
- Backward compatibility: a caller that does not call `scan` sees no change. The Dart package accepts exactly its
  own contract version, so a 2.9.0 library is refused, as at every step. The MCP `tools/list` and `searchd`'s
  usage text gain one entry.

## 6. Invariant compliance (INV)

- INV-01 retrieval≠generation: complies; lines are returned as stored.
- INV-02 citations: complies; every hit names root, path and line, the same line `read_span` returns.
- INV-03 pre-rank authorization: complies; roots and labels filter before any byte is read.
- INV-04 chunker identity: N/A; `scan` reads source bytes, not chunks.
- INV-06 dependency-free base: complies.
- INV-07 versioned/checksummed formats: complies; no format change, and `fileBytes` checks every file's SHA-256.
- INV-08 deterministic ordering: complies; path and line order, no score.
- INV-09 complexity earned by measurement: complies; ADR 0006 §9 measured the plain scan before building and
  took no prefilter (ruling 6).
- INV-10: complies; each claim is marked shown or argued.
- INV-11: N/A.

## 7. Register updates (fill when consolidating — step 4)

- Capability catalog row (CAP-25): added.
- FR/NFR index rows added: FR-37 to FR-41, NFR-19, NFR-20, with their rows in the specification's
  proposed-requirements appendix.
- Contracts rows added: none (the tool schemas sit under CON-02's family, as `find`'s do).

## 8. Conflict check (step 5 — required)

Checked against the register on `main` at `43a308d`.

- **CFT-34, CAP-25 ↔ FR-25 / CAP-19 (empty is not proof).** An index holds source bytes only for retained roots;
  a host's `local` root keeps none by default (`apply.zig` 230–234). A scan of such a root would find nothing.
  Resolved: such files are counted in `not_scanned.not_retained`, the answer is `truncated`, and the user
  document says so.
- **CFT-35, CAP-25 ↔ CAP-13 / NFR-09 (MCP answers one request at a time).** A scan holds the MCP server for up to
  its budget plus 50 ms (30 s at most for the budget), and there is no cancel. Accepted with rationale: the budget bounds it, the default is
  2 s, and cancel is a later capability (a 03-next row).
- **CFT-36, CAP-25 ↔ the expectations `grep` sets.** `\w` without `_`, Unicode `\d`, and lines split by every
  `str.splitlines` terminator rather than LF alone. Resolved by ruling O-1: the user document states the
  difference with an example, and the `grep` agreement test records its exclusions.

Considered, not conflicts:
- CAP-20 / NFR-15: a folder scan writes nothing, as direct search does.
- CAP-24: the folder source reuses its walk and rule unchanged.
- NFR-13: one file at a time, tested.

## 8b. Dependencies

- Depends on: CAP-19 (the source section, scopes, `find`'s envelope and cursor form), CAP-24 (the walk's text
  rule), CAP-13 (the MCP adapter), and the judged folder of S6-T22 (the exact-string set's corpus).
- Is any acceptance criterion dependent on an unbuilt capability? No.

## 9. Acceptance gate (step 6 — decidable before building)

- **Primary metric:** the exact-string question set (`fixtures/text-search/exact-strings.json`, frozen with its
  own digests before the engine runs against it). Pass: for every question, over an index and over the folder,
  exactly the frozen line set; for literal questions also the frozen offsets. The Python reference agrees. Rule:
  any difference blocks.
- **Agreement with `grep`:** the same `(path, line)` set as `grep -rn` for every question marked comparable, with
  the exclusions recorded.
- **Unchanged answers (NFR-20):** byte-identical on the three 10k corpora and the judged set; the 181 untouched.
- **Linear time (NFR-19):** a growth-ratio test.
- **Budget (FR-41):** an injected clock shows `stopped: "time"` with progress, and the `capacity` refusal for a
  line that alone outlasts the budget.
- **Performance:** literal and regex scan times over the three 10k corpora and the judged folder, measured in
  ADR 0006 §9. The engine's open, query and find cells under the timing rule of 2026-11-17 are `pending` until the
  maintainer says the machine may be kept awake.
- **Security / isolation:** hidden files are not scanned; `principal_labels` comes only from a trusted caller.

## 10. Evidence plan (step 8)

- **Tests:**
  - the grammar table (every refusal and its message);
  - matches with offsets (empty matches, anchors, classes, the fold, Tamil, marks, `whole_word`);
  - the growth ratio;
  - paging exactly-once, stale and mismatched cursors;
  - the budget;
  - index and folder agreement;
  - every interface;
  - the reference against the engine on seeded generated patterns and lines;
  - the exact-string set and its digests.
- `PROJECT-STATE.md`: contracts 2.10.0, Dart 0.12.0, `scan`.
- How status advances: Implemented on `task/S6-T24`, verified by the S6-T24 verifier; Validated is not claimed.

## 11. Open decisions

- **For the maintainer:** the size of the version step. No written rule fixes it; minor (2.10.0) follows the
  practice since 2.0.0.
- `ss_scan_folder` (a folder scan for Dart and the app): not in this task; a 03-next row.
- Cancel: a later capability; a 03-next row.
- A folder cursor that also detects edits: not taken (ruling O-4).
- A required-literal prefilter for regex, or a postings prefilter: not taken. Measured first; the plain scan meets
  the budget on the 10k corpora (ADR 0006 §9).

## 12. Maintainer approval (step 6b — required before build)

- Approver: accepted by the orchestrator under the maintainer's direction of 22 and 23 Nov 2026, recorded for his
  review; the maintainer may overrule.
- Date: 2026-11-23.
- Commit: the S6-T24 rulings after Part 1, on `task/S6-T24` (the commit that adds this record).
- Status: Accepted (orchestrator, under the maintainer's direction); not Validated.
