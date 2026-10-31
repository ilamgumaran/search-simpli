# Folder knowledge design review — 2026-10-31

Reviewed branch: `design/folder-knowledge`, base commit `ccbdd2311a9c2868de7a9a025b73bbe79e2e4725`.
Scope: CAP-19, UC-007, S3 plan, requirements process/register, CAP-13, authorization documentation and current native chunker/indexer/scoring sources. This is a design review; no engine feature or performance result is claimed.

## Findings and amendments

| Priority | Finding and evidence | Amendment |
|---|---|---|
| High | CAP-19's FR/NFR ranges appeared only in its catalog row; register FR/NFR tables and specification omitted them. The validator extracts individual IDs, not inclusive ranges. | Enumerate all nine FRs and five NFRs in all three sources of truth. |
| High | `zig/src/chunker.zig` joins lines with LF and strips whitespace; Markdown additionally drops front matter. Its chunks cannot reconstruct exact source bytes. | Retain original source and line-byte mappings in a versioned, checksummed generation; legacy exact reads fail explicitly until rebuild. |
| High | `docs/authorization.md` already documents native pre-rank labels and global-statistics/timing limits. Per-root statistics cannot isolate mixed labels within one root. | Correct current-state claims; require trusted scope on every surface, visible statistics/vocabulary/counts and hidden/absent tests. Timing isolation is not claimed. |
| High | CAP-13 explicitly requires four read tools, no new powers and semantic parity. CAP-19 claimed nine tools and byte equality as its realization. | Preserve the baseline; define CAP-19 as an opt-in extension with separately authorized writes, MCP lifecycle tests and semantic payload parity. |
| High | A zero-hit result, especially an empty page or incomplete/pending corpus, does not establish that the folders lack an answer. | Scope empty/coverage/exact-match metadata; use retrieval-limited wording; do not claim CAP-14 answerability. |
| High | Host-fed bytes in JSON, path trust, duplicate operations, crash publication and pending/stale content had no decidable rules. Current `indexer.zig` publishes segments before saving incremental state. | Freeze bounded base64 UTF-8 payloads and mutation semantics before T3; require atomic generation consistency, validated hashes/paths, stale-generation rejection and recovery tests. |
| Medium | Character offsets alone do not define token adjacency. Prefix expansion does not itself require positions. Words behavior conflicted with UC-007's both-word query. | Specify token ordinals plus original-text offsets, conjunctive find words, final-token prefix matching and explicit highlighting requirements. |
| Medium | Fixture came after design-dependent tasks; phrase recall and paging lacked boundary/dedup rules. Performance targets lacked a pinned profile. | Freeze judgments first, enumerate boundary/Unicode cases, exhaust pages for exact retrieval metrics and mark benchmark-profile evidence pending. |

## Remaining decisions before build

Exact source-section/schema formats, Markdown front-matter subset and malformed-input fallback, stale/pending read policy, ambiguous rename pairing, benchmark profile and pinned MCP revision must be frozen in task acceptance artifacts. Chunker identity includes per-file algorithm and parameters; CFT-09 is not closed by merely proposing a manifest field. Strong tenant isolation still requires its own deployment controls.

CAP-19 remains Proposed. The maintainer approval block stays pending. This review updates the requested design branch without starting implementation or approving its own design.

## Validation

Run the branch requirements validator and its existing negative-fixture unit suite against this amendment. Review relative links and confirm that no implemented status or approval was invented. These checks validate design consistency, not native feature behavior or performance.

Observed validation: `python3 scripts/check_requirements.py` passed; `python3 -m unittest discover -s tests -p test_requirements_validator.py` passed all 18 tests. Executed in an isolated workspace containing the branch validation inputs and amended documents; the existing working checkout was left unchanged because shell Git networking was unavailable. Branch publication uses the connected GitHub API.

## Orchestrator's response (2026-10-31, later the same day)

All eight amendments are accepted as written; they make the design decidable. Three refinements, recorded in CAP-19 §11 and in `docs/folder-knowledge-implementation.md`:

1. **Source retention is per root, not unconditional.** Byte-exact `read_span` needs the original bytes, but a desktop root the engine may re-open does not need a second copy; `retain_source` defaults to true for host-fed and iCloud roots and false for local desktop roots, with a hash check against the file at read time and an explicit `stale` error. The cost is measured in S3-T1 and reported separately (§4, §13).
2. **Relation to CAP-16 (directory filename retrieval, PR #16).** `list_files` is a scoped listing with a prefix, not a ranked filename search; CAP-16's `search_field` channel stays the way to find a file by name and inherits roots and visible scope when both land (§8). No duplicate channel.
3. **The MCP protocol revision is pinned in code** and recorded in S3-T6's Report; the baseline mode (`--baseline`) lists exactly CAP-13's four tools (§11).

Added to the branch for implementation: `docs/folder-knowledge-implementation.md` (formats: manifest v2, document records v4, `HYBLEX02` positions, `HYBSRC01` retained source, INDEX-STATE v2; the `apply_changes` request and report with every rule decided; scope and visible-scope statistics; the JSON shapes of `find`, `outline`, `read_span`, `list_files`, `evidence`, `index_status`; the C ABI additions; tool schemas and the skill; the MCP server; the fixture inventory; the benchmark profile) and the task files `docs/tasks/S3-T1.md` … `S3-T8.md` in the S1/S2 shape, each citing the sections it implements and naming its tests and measurements. Everything stays proposed until the owner approves CAP-19 (step 6b).
