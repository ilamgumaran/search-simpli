# Review of PR #21 `improve/recovery-and-filename` (head 54f667d)

**Reviewer:** Claude Opus 5.5 (local, read-only), 2026-11-01. **Base of the PR:** e9d97b0 (11 commits, 85 files, +5171/−505). **Main at review time:** f45c06d (S4-T1 merged).
**Machine:** this Mac (Apple silicon, macOS 26.6, Xcode 27.0, pinned Zig 0.16.0, NDK 28.2.13676358). Every shell: `SEARCH_SIMPLI_LIBRARY_PATH` unset, pinned Zig on `PATH`. Nothing ran on a phone. Every number below is from my own runs unless it is labelled as quoted from the PR.
**Method:** a detached scratch worktree at 54f667d (the branch's own suites, a local native rebuild, cost measurements) and a second scratch worktree where I ran `git merge --no-commit origin/main` and resolved the conflicts as little as needed to compile and measure. I committed nothing, pushed nothing, and removed both worktrees at the end.

## Verdict in one paragraph

The design is sound and fits S3. The filename channel is opt-in. It is filtered by the trusted scope before any statistic or rank. The scoped-writer rules tighten RPC/MCP. Recovery bound to the commit point is the right idea. The branch is green on its own base. **It must not be merged as it stands, and it cannot simply be rebased.** Three things in it undo S4-T1's measured gains, and the scratch merge shows it:

- (1) `meta.recovery_state` copies the whole of INDEX-STATE into the manifest. That is not opt-in: every new generation gets it. At 10k files the manifest grows from about 540 B to 2.48 MB, and the open parses it with a dynamic JSON parser. In the merged tree, **the NFR-13 10k test fails** (OOM inside `parseMeta` under the 64 MiB cap; peak 144.0 MB at a 1 GiB cap against main's 53.6 MB). `ss_open` goes from 1.6 ms to 32–34 ms, and one changed file through `ss_apply_changes` goes from 63 ms to 131 ms.
- (2) The filename sections are read in full and validated by a complete rebuild at every open: +15 to +18 ms at 10k.
- (3) The filename query is quadratic: 2.8 ms at 1k files, 22.8 ms at 3k and 276 ms at 10k (ReleaseSmall).

A small regression in confined file reads and the contract-version collision come on top. **Recommendation: (b), integrate through `task/S4-T2`, with the rulings at the end.** They fix (1)–(3) as part of the integration, not as follow-ups.

---

## 1. Design fit

### 1.1 Filename channel (CAP-16, `filename-field-v1`)

- **Fits the S3 model.** One catalog record per root-relative path, anchored at the earliest real body chunk (`zig/src/filename_field.zig:74-97`). Labels must agree across a file's chunks, or the build fails with `InconsistentLabels` (`:86`). The open revalidates the catalog against the body documents (`:107-126`), so a filename hit always cites a stored, readable span. `read_span`/`outline`/`find` are untouched.
- **Trusted scope filters both channels before ranking: yes.**
  - Filename candidates, `df`, `N` and the average length are computed only over in-scope catalog records (`filename_field.zig:160-193`, `scopedAvg` `:243-251`). In-scope uses `hybrid.inScope`: root mask, `path_prefix` and `principal_labels` (`hybrid.zig:61-65`).
  - The `both` body channel recomputes `df`, `N` and the average over visible chunks only (`:165-202`).
  - The root mask comes from `folder.allowedRoots(parsed.scope)` with the caller's configured scope (`ops.zig:801-811`, `abi.zig` `queryImpl`).
  - The test "filename and both scope scores ignore hidden earlier files and zero-score candidates" (`filename_field_test.zig:81-108`) asserts score equality with and without a hidden file (hidden/absent parity, CFT-18).
  - `pending_files`/`truncated` in filename results count only visible entries (`filename_response.zig:381-387`).
  - **I found nothing that weakens privacy or labels in the query path.**
- **Default behaviour unchanged.** `search_field` defaults to `content`. Filename/both need an explicit `retrieval_mode: lexical`, and `profile` is refused (`ops.zig` `parseSearch`, `abi.zig:259-262`). `test_default_content_bytes_and_frozen_golden_on_both_snapshots` passes.
- **Where it does not fit the engine's rules:**
  - NFR-04/NFR-13 (bounded, caller-owned workspaces). Each filename query decodes the whole catalog and filename lexical section into fresh allocations (`filename_field.zig:149-157`).
  - The algorithm is O(postings × catalog × body). `findAnchor` is a linear scan over every body chunk (`:252-255`). It is called per catalog record (`:160`), per posting (`:189-193`) and inside `scopedAvg`, and `scopedAvg` is itself called **per posting** (`:193`). `termIndex` is a linear scan (`:128-131`).
  - The PR's own benchmark shows this: 71.8 ms filename p50 against 0.10 ms content at 1k files (Debug, Linux; `benchmarks/filename-field-cost-2026-10-28.json`). Mine are in 3.4.
- Response detail: filename results write `"index":{"version":2}` even for a v3 manifest (`filename_response.zig:57-58`). Minor.

### 1.2 Recovery bound to the committed manifest ("manifest v3")

- **The idea is right.** A generation's mutation state (own labels, hashes, sizes, mtimes, moves) should be immutable data bound by the commit point, not a mutable cache. The fallback for old generations is fail-closed: effective labels are kept as own labels (`apply.zig:1339`), which can only be more restrictive.
- **The placement is wrong for this engine.** `buildGeneration` splices `incremental_state.encode(...)` into the meta JSON (`apply.zig:1861-1862`). The meta is a manifest payload string. Every open reads it, checksums it and parses it with `std.json.Value` (`manifest.zig` `parseMeta`, called in `snapshot_open.openScoped`). Measured in 3.4:
  - The manifest grows to the size of INDEX-STATE: 2,480,755 B against 540 B on main, at 10k one-line files.
  - The parse alone is about 72 MB of live memory at 10k.
  - It applies whether or not filename indexing is on, so it is **not opt-in**.
  - It contradicts S4-T1 ruling 1 (open validates what `index_status` needs; everything else loads at first use) and NFR-13.
- Writers already read INDEX-STATE. The integrity goal is met just as well by a separate bound section that only writers read (ruling R3).

### 1.3 Scoped writers and file reads

- **Fits `docs/authorization.md`'s model** (the trusted host is the authority; a model request cannot mint grants).
  - RPC/MCP servers configured with `--roots`/`--labels` now refuse root declarations (`apply.zig:678`).
  - They refuse `file` changes, which would be filesystem reads (`:687`), changes outside the configured roots or labels, label-policy changes, moves and removals touching hidden files, and `remove_root` over hidden files (`:676-702`). Test: `apply_test.zig` "restricted writers cannot change root policy, hidden files or labels".
  - Trusted C/Dart callers (the consumer app) are unaffected.
  - An RPC/MCP host that used `--roots` together with root declarations or `file` changes now gets `invalid_argument`. `docs/zig-rpc-service.md` and `docs/tool-protocol.md` say so; **`docs/authorization.md` and `docs/mcp-server.md` are not updated.**
- **A read the engine should still do, now refused.** `openConfined` walks from `/` and opens every component with `follow_symlinks = false` (`apply.zig:1209-1223`). That includes the components *above* the root. The confinement rule (`confineFile`, "no symlink below the root") only covered components below it.
  - On macOS, `/tmp`, `/var` and `/etc` are symlinks. Measured with `ss_apply_changes`: a `local` root declared under `/tmp/...` with one `file` change and `allow_file_reads: true` gives main `added 1`; the PR's dylib gives `added 0, unreadable_paths [note.md]`, silently. Through the real path both work.
  - Any host that passes paths under `/var` (the macOS temporary directory, some container paths) loses file reads.
  - Fix: open the root directory once, following links in the prefix, then go no-follow below it (R5).

### 1.4 Other rules

- The `checks` CI is green at 54f667d. The requirements check passes, but CAP-16 reads "Diagnostic" in its capability file and "Proposed · future" in the register (`docs/requirements/README.md:106`) and the specification (FR-16 "Proposed"). `check_requirements.py` does not compare that status.
- CLI and `ss_index_folder` updates of a filename-enabled directory **fail without restating the flag**: `searchd index --update` gives `error: FilenameSettingMismatch`, measured. `indexer.Caps.filename_index` is a `bool` passed as a non-null option (`indexer.zig:200,250`; `abi.zig:704`). The task doc says "updates retain it", and only `ss_apply_changes` does.

## 2. Collision with S4-T1

### 2.1 Contracts

- Both sides say **2.1.0** for different contracts.
  - Main's 2.1.0 adds the **required** `index_status.source`.
  - The PR's 2.1.0 adds `search_field`, `filename_index`, filename result fields, the optional `index_status.filename_policy_id` and interchange `format_version: 2`.
- The Dart check is an exact match, so a library reporting "2.1.0" from either line would satisfy a package expecting the other.
- **The merged contract must be 2.2.0.** The surfaces that change:
  - `contracts/CONTRACTS_VERSION`, which also feeds `ss_version()` through `build.zig` and the native digest.
  - `zig/src/abi.zig:1197` (test), `zig/tests/abi_test.c:168` (and the status golden comment at `:187-201`), `zig/include/search_simpli.h:114` (`ss_version` doc). Add a "since 2.2.0" note for `search_field`/`filename_index`.
  - `contracts/tools/index_status.result.schema.json`: both properties; `source` stays required and `filename_policy_id` optional. This is the conflicted file, and the union is mechanical.
  - Dart: `contracts_version.dart` `'2.2.0'`; `pubspec.yaml` **0.3.0**, a minor bump for the new public API (`SearchField`, `MatchSection*`, `SearchResultItem.matchedIn/basename/matchSections`, `SnapshotStatus.filenamePolicyId`, `ApplyChangesOptions.filenameIndex`, `IndexFolderOptions.filenameIndex`, `SnapshotInterchangeV2`, `query(searchField:)`). `CHANGELOG.md` keeps the 0.2.1 entry as history, and the 0.3.0 entry says contract 2.2.0. `old_library_test.dart`'s "previous" stand-in reports "2.1.0" and the expected value is `expectedContractsVersion`.
  - Python: no hard-coded version (`tests/test_native_freshness.py` reads the file). The Python reference's filename changes come with the PR unchanged.
  - MCP/RPC: `search_knowledge.request/result` schemas from the PR. `index_status` via the merged schema.

### 2.2 Index format

- **Composable: yes, by test.** The scratch merge auto-merged `manifest.zig`. The decoder accepts `flag_xxh3_sections` for v2 and v3 (merged `manifest.zig:376`). The filename catalog and lexical sections go through `segment.encode`/`lexical_segment.encode` and so get XXH3 headers. `validateSnapshotWithFilename` checks them through `inspect`.
  - A merged `searchd` wrote `HYBMAN03 version 3 flags 0x7` and `HYBMAN02 version 2 flags 0x7` indexes.
  - It also read a PR-written v3 index (FNV, flags 0x3) and main's v2.1 index.
- **The `snapshot_open.zig` conflict** is the eager PR open (`Engine.open` + `buildPositionTables` + roots + full filename read/validate) against main's lazy `loadEngine`/`openWith` and `scope.Loads`.
  - My minimal resolution: main's lazy body, plus the PR's filename block after `openWith`, plus `opened_engine.folder = folder` in `openScoped` (with `var`).
  - Result: `zig build test` **276/277**. The failing test is NFR-13 10k (OOM in `parseMeta`); `test-abi` 22/22; Python 238 with the single expected native-freshness failure; family-folder gate pass; Dart +83 against a scratch merged dylib.
- **Lazy open with filename sections: no, as written.** The block reads both sections whole and rebuilds the catalog and postings from the body documents to compare (`filename_field.validate`) at every open: `ss_open` +15.5 ms and serve startup +18 ms at 10k (3.4). It belongs at the first filename query, once per handle, under `scope.Loads`' mutex, and is checked by checksum and counts at load (R4).
- **The 292cb568 compat test still makes sense and passes in the merged tree** (part of the 277). It exercises reading an old-format index and upgrading it on its first `apply_changes`. After the merge that first upgrade also adds `recovery_state` (until R3 changes it) and leaves filename off. Add an assertion that the upgraded generation has no filename sections.
- **"An old library refuses an updated index with `UnsupportedFlags`": only half true after the merge.** Measured with `searchd query`:

  | reader \ index | main v2.1 | merged v2 (no filename) | merged v3 (filename) | PR v3 (FNV) |
  |---|---|---|---|---|
  | main f45c06d | reads | **reads** (meta key ignored) | **`BadMagic`** | `BadMagic` |
  | PR 54f667d | `UnsupportedFlags` | `UnsupportedFlags` | `UnsupportedFlags` | reads |
  | merged | reads | reads | reads | reads |

  The refusal holds both ways, but a 0.2.1 or 292cb568 library refuses a filename index with `BadMagic`, not `UnsupportedFlags`. Ruling R2 makes it consistent: the filename extension becomes a v2 flag bit, so an old reader stops at the flag check.

### 2.3 Natives

- **The PR's CI build is authentic and reproducible on this Mac for two of three targets.**
  - GitHub API: run 41309041051 (`native-package`, event `pull_request`, head `bf2c9b7`) concluded `success`, and every step succeeded on `macos-14`.
  - Artifact 13084576932 digest `sha256:8dc7dcf0…455ddd` equals the PR's stated SHA-256.
  - The `checks` and `native-package` runs at the final head 54f667d are both `success`. The earlier `checks` runs failed on the expected stale-native test before adoption.
  - `git diff bf2c9b7 54f667d -- zig contracts bindings/dart/search_simpli/tool` is empty, so the stamp covers the head.
- **My rebuild of 54f667d** (`tool/build_native.sh`, fresh `ZIG_GLOBAL_CACHE_DIR`/`ZIG_LOCAL_CACHE_DIR`, 13 s):
  - macOS dylib 773,240 B and Android `.so` 746,568 B (and the `jniLibs` copy) are **byte-identical** to the committed ones (sha256 `4344023261f5e21c…`, `97f537363fc11e33…`).
  - **The iOS framework binary is not**: 754,208 B here against 1,016,352 B committed.
  - Same `__TEXT` (611,846 B), same symbol count (1,987), `minos 17.0` in both. The committed one says `sdk 17.5` (the runner's Xcode); mine says `sdk 27.0`, like main's.
  - The older linker writes the 262,144 B `__thread_bss` into the file (`__DATA` filesize 278,528 against 16,384), orders `__got`/`__const` differently, and 226 bytes of `__text` differ (address fixups).
  - It is a toolchain difference, not a source difference. But it is not the S3-T8 recipe's byte-identical evidence, and the shipped iOS binary should come from this Mac like every earlier release.
- **The `SOURCE-SHA256` scheme is the same.** `tool/source_digest.py` is unchanged on both sides, and `source_digest.py` prints the committed `4293d53e…bf4b95` on the branch (main: `41ef1574…5714e`).
- **After the merge, the digest changes and all four binaries must be rebuilt on this Mac.** The ten conflicts include all of them: three natives, the `jniLibs` copy and `SOURCE-SHA256`.

## 3. Quality

### 3.1 The branch's suites on this Mac (worktree at 54f667d)

| Suite | Result |
|---|---|
| `zig build test --summary all` | `5/5 steps succeeded; 263/263 tests passed` (32 s) |
| `zig build test-abi --summary all` | `abi_test: 22/22 checks passed` |
| `python3 -m unittest discover -s tests` (Zig on PATH) | `Ran 238 tests` … `OK` (0 skips on macOS; the PR's Linux run had 4 platform skips) |
| same with `SEARCH_SIMPLI_NO_ZIG=1` | `Ran 202 tests` … `OK (skipped=33)` |
| `tests.test_mcp tests.test_folder_surfaces tests.test_cli_process` | `Ran 42 tests` … `OK` |
| `scripts/relevance_smoke.py --pack family-folder` | recall@5 1.000, outline 7/7, read_span 9/9, lifecycle 3/3, phrase/prefix P/R 1.00, `0 skipped`, `gate: pass` |
| `dart analyze lib test` / `dart test` | `No issues found!` / `+82: All tests passed!` (committed natives) |
| `scripts/check_requirements.py` | OK |
| `scripts/check_no_home_paths.py` | exit 0 |
| trailing whitespace in `*.md`/`*.py` | none |

For comparison, main f45c06d: Zig 268, ABI 22, Python 208, Dart 75 (S4-T1 Verdict). The scratch merge gives Zig 277 (276 passing), ABI 22, Python 238, Dart 83.

### 3.2 New tests: what they cover and what is missing

- **Filename:**
  - `filename_field_test.zig`: catalog and anchor; inconsistent labels; opt-in publication with the setting pinned; hidden-file parity; literal backslash.
  - `filename_response.zig:323`: match sections and citations.
  - Python: `test_filename_search.py` (16, reference semantics including file BM25, both-fusion ties, best chunk of a multichunk file); `test_filename_cli.py` (8 native: six frozen cases, default-content golden on both snapshots, CLI/RPC sections, mode validation, scoped prefix parity Python↔native, interchange v2, hidden/empty/unsupported, refresh and migration); `test_filename_integration.py` (v3 with S3 structure/positions/source, refresh keeps the channel with root scope first, bound catalog corruption detected).
  - Dart: the host-fed regression in `folder_knowledge_test.dart:201-243`.
- **Recovery:** `apply_test.zig` "committed recovery state preserves own labels, hashes, mtimes, pending and moves without cache"; the Dart host-fed test deletes INDEX-STATE and updates.
- **Confinement:** `test_file_confinement_race.py` (an intermediate component replaced by a symlink is not followed; the pinned directory survives a rename).
- **Missing:**
  - No manifest-v3 unit tests in `manifest.zig` (round trip, checksum over the new header fields, stray flags, duplicate names); only the Python corruption test covers it.
  - No cost or scale test for the filename query (a 10k case would have caught the quadratic path).
  - No memory test with `recovery_state` (NFR-13's 10k test, written after the PR's base, is what catches it).
  - No test of a symlinked prefix above the root.

### 3.3 Spot checks

- **Invented names only.** The fixture corpus is six invented filenames (`Annual_Budget_2026.md`, `Café_Record.md`, `Lunar Launch.md`, `River-Transit.md`, `StArChArT.md` and a Tamil compound), each with "This file stores numbered observation N." A scan of the added lines for personal or device names and home-path prefixes finds only the repository owner's public GitHub handle, in issue, PR and run links.
- **No home paths:** `check_no_home_paths.py` exit 0.
- **Trailers** (`git log --format=%B`, 11 commits):
  - **no `Claude-Session` trailer** in any commit.
  - `Co-Authored-By: Codex <noreply@openai.com>` appears **once** in each of `be79542`, `1f050ab` and `5822041`. The other 8 commits carry none.
  - All 11 commits have the owner's account as author. That is consistent for an external agent's PR; our integration commits carry our own single `Co-Authored-By` line.
- **CI workflow** `.github/workflows/native-package.yml`: `permissions: contents: read`, PR-triggered on `zig/**`, `contracts/**`, `tool/**`. It installs Zig from PyPI `ziglang==0.16.0` (same bytes for macOS and Android as the official tarball, per 2.3). Actions are pinned by major tag, as `checks` already is.

### 3.4 Measured costs (ReleaseSmall)

- **Filename query.** PR's own script `scripts/benchmark_filename_field.py` with ReleaseSmall `searchd` built from 54f667d (candidate) and from f45c06d (baseline); 30 sequential RPC round trips, p50/p95 ms. Startup is process launch to the first `index_status` reply.

  | files | content (main) | content (PR) | **filename (PR)** | **both (PR)** | startup main / PR-filename |
  |---|---|---|---|---|---|
  | 1,000 | 0.022 / 0.043 | 0.018 / 0.039 | **2.77 / 3.06** | 3.03 / 3.13 | 3.1 / 9.7 |
  | 3,000 | 0.016 / 0.030 | 0.017 / 0.038 | **22.8 / 23.2** | 23.9 / 24.1 | 3.3 / 24.9 |
  | 10,000 | 0.020 / 0.047 | 0.019 / 0.037 | **275.9 / 277.3** | 275.2 / 292.0 | 4.3 / 74.9 |

  3× the files (1k→3k) gives 8.2× the time, and 3.3× (3k→10k) gives 12.1×: quadratic. Snapshot bytes at 10k: 6,581,088 (main) against 10,391,553 (PR with filename, +58 %).
- **Serve startup** (`searchd serve` launch to the first `index_status` reply, p50 of 12, the 10k one-line corpus): main 3.79 ms; PR without filename 57.41 ms (its eager, pre-S4-T1 open); PR with filename 75.56 ms; merged without filename 37.43 ms; merged with filename 52.10 ms.
- **Open and one changed file through the C ABI** (my ctypes drivers, the committed f45c06d dylib against a ReleaseSmall dylib from the scratch merge). A 10k-file host-fed index (two lines per file, one root, built by `ss_apply_changes`). `ss_open` p50 of 30 fresh handles, two rounds; one `change` through `ss_apply_changes` on a fresh copy, five interleaved runs.

  | | MANIFEST | `ss_open` p50 | one changed file |
  |---|---|---|---|
  | main lib, main-written index | 533 B | **1.65 / 1.58 ms** | 66.6 / 63.4 / 62.1 / 62.8 / 63.1 ms |
  | merged lib, main-written index | 533 B | 1.70 / 1.58 ms | — |
  | merged lib, merged-written (no filename) | 2,560,741 B | **34.25 / 32.36 ms** | 131.2 / 130.3 / 126.6 / 130.6 / 132.1 ms |
  | merged lib, merged-written (filename) | 2,560,861 B | **49.90 / 47.79 ms** | 145.3 / 143.9 / 143.3 / 144.2 / 146.3 ms |
  | (first filename query after open) | | 277.2 / 267.5 ms | |

  The same through the CLI (`searchd index --update` after one file changes, the 10k one-line corpus, five runs): main p50 199.1 ms, merged 269.0 ms, merged with filename 282.3 ms.

  Not re-run: S4-T1's own 10k timing-corpus driver (it is not committed). On that corpus main's one-changed-file p50 is 149–157 ms. An extra ~70 ms like the one above would break NFR-12's 200 ms ReleaseSmall bound. That is an inference, to be measured by the integration.
- **NFR-13** (`zig/src/nfr13_arena_test.zig`, peak live bytes, in the scratch merge):
  - At the shipped 64 MiB cap, the 10k test **fails** with `OutOfMemory` in `parseMeta` (`std.json` dynamic parse).
  - With the cap raised in the scratch copy to 1 GiB: open **143,989,908**, find 150,225,242, list_files 151,032,018. Main's open is 53,649,238 and its list_files 60,691,348.
  - With the duplicate meta parse removed from my resolution (one `parseMeta` per open), open is 71,623,136, still above 67,108,864. read_span, outline and list_files rose to 156–163 MB in that variant; I did not trace why.
  - The family folder moves from 9,414,318 to 9,490,356.

## 4. Risks for the consumer app (pins the engine through the Dart package)

**Changes even if the host never opts in:**

1. **The pin bump is mandatory to stay current.** Contract 2.2.0 (after R1) is an exact match, so the Dart package and the natives move together, as at every pin.
2. **Every generation the new library writes carries `recovery_state` in the manifest (as the PR stands).** For a 10k-file folder that means `ss_open` going from about 1.6 ms to 32–34 ms, `apply_changes` doubling, and NFR-13 broken. R3 removes this. After R3, the non-opt-in cost should return to main's numbers, and the integration must show it.
3. **Rollback.** The new library writes v2 with flag 4 when filename is off: the 0.2.1 library reads it (measured), the 292cb568 library refuses it (`UnsupportedFlags`, as with S4-T1). A filename index is refused by older libraries: `BadMagic` today, `UnsupportedFlags` after R2. So "do not roll the library back after an update" stays the rule for 292cb568, and extends to 0.2.1 for filename-enabled directories.
4. **Confined `file` reads under a symlinked prefix are silently skipped** (1.3). Only relevant if the app ever uses `file` changes with `allow_file_reads`. Host-fed `content_base64` is unaffected.

**Opt-in (filename search), how a host enables it:**

- On a **new, empty directory**, pass `ApplyChangesOptions(filenameIndex: true)` to the first `SearchSimpli.applyChanges`. The other routes are `IndexFolderOptions(filenameIndex: true)` for `indexFolder`, or importing a `SnapshotInterchangeV2`.
- Later `applyChanges` calls may omit the option, and the setting is kept. Passing `false`, or `true` on a directory built without it, raises `FilenameSettingMismatch`.
- **So yes, an existing index needs a rebuilt output directory**: feed every file's bytes again into a new directory, then switch. `indexFolder` updates currently need `filenameIndex: true` restated (1.4); R6 fixes that.
- Query: `query(text, mode: RetrievalMode.lexical, searchField: SearchField.filename | SearchField.both)`. A vector, hybrid or default mode with filename throws `ArgumentError` in Dart. On a directory without the channel, the native side answers `FilenameIndexUnavailable`, which surfaces as a `SearchSimpliException`.
- Results add `matchedIn`, `basename` and `matchSections` (separate filename and content citations). `answerPolicy.filenameMatchesAreNavigation` is true. `status().filenamePolicyId` is `filename-field-v1` only on enabled directories.

**What breaks nothing if the host does not opt in:**

- Every new Dart member is optional or nullable: the `query` defaults, `SnapshotStatus` gains a nullable field, `ApplyChangesOptions.filenameIndex` defaults to null and sends nothing, and the interchange V1 class is unchanged.
- Content results are byte-identical (`test_default_content_bytes_and_frozen_golden_on_both_snapshots`).
- Pending, `find`, `read_span` and `outline` are unchanged.
- The app's own code compiles unchanged against 0.3.0 (all additions). The Dart formatter reflowed `contracts.dart`/`search_simpli_base.dart` without changing their API.

## 5. Recommendation: (b), integrate through `task/S4-T2`

- (a) is not possible: a rebase is the same semantic merge, and as-is it fails NFR-13 and gives back S4-T1's open and one-changed-file gains.
- (c) would send the author to redo work that depends on S4-T1 internals (the `scope.Loads` lazy loads, the XXH3 sections, the NFR-13 harness) that only exist on main.

The PR's design, tests, fixtures, Python reference, Dart API and docs are worth keeping whole. The fixes are bounded, so they belong in our integration task, built by an Opus builder on this Mac and verified by another agent.

### Draft rulings for S4-T2

`S4-T2 · Integrate PR #21 (filename channel, bound recovery, scoped writers) onto main after S4-T1.` **Depends on:** S4-T1 (merged). **Size:** L. Worktree `task/S4-T2` from `origin/main` (f45c06d). Every shell: `unset SEARCH_SIMPLI_LIBRARY_PATH`, pinned Zig on `PATH`. The usual rules apply: public repo, invented names, measured numbers, no home paths or device names, one `Co-Authored-By`, no `Claude-Session`, no `git merge --no-edit`.

- **R0. The merge.** `git merge --no-ff --no-commit 54f667d`, which keeps the author's 11 commits in history. Resolve the ten conflicts semantically:
  - `snapshot_open.zig`: main's lazy open plus R4.
  - `index_status.result.schema.json`: the union, `source` required.
  - `pubspec.yaml`: 0.3.0.
  - `CHANGELOG.md`: keep 0.2.1, write 0.3.0.
  - `old_library_test.dart`: main's form, previous version "2.1.0".
  - The four binaries and `SOURCE-SHA256`: placeholder, rebuilt in R8.

  Commit the merge as is (the tree may be red), then one commit per ruling. State in the Report that the merge commit alone is not green.
- **R1. Contracts 2.2.0.**
  - `contracts/CONTRACTS_VERSION` 2.2.0.
  - `ss_version` expectations in `abi.zig` and `abi_test.c`, the header doc, and the `abi_test.c` status golden with both `source` and (on a filename fixture) `filename_policy_id`.
  - Dart `expectedContractsVersion` '2.2.0', package **0.3.0** (minor: new public API), CHANGELOG 0.3.0 naming contract 2.2.0, manifest v2.2 (R2), and the rollback rule.
  - The register and specification move CAP-16/FR-16 to the same status as the capability file.
- **R2. One manifest family: v2.2, not HYBMAN03.**
  - Encode the filename extension as **manifest v2 flag bit 3 (`flag_filename_sections = 8`)**. Same magic `HYBMAN02` and version 2. When the flag is set, the header grows by the PR's 48 bytes of filename fields and the payload by its three strings. Keep the PR's field order and checks.
  - Old readers then stop at the flag check with `UnsupportedFlags`: 292cb568 on any flag-4 or flag-8 index, 0.2.1 on flag 8. A test states it, the way S4-T1 stated its refusal.
  - Drop the HYBMAN03 reader. No released library wrote it; the PR's own natives were never pinned. Say so in the Report.
  - Fold `docs/manifest-format-v3.md` into `docs/manifest-format-v2.md` as "minor version 2.2". Rename references in `docs/filename-field-format-v1.md`, `docs/tasks/recovery-filename-integration.md` and the tool docs.
  - Add Zig unit tests in `manifest.zig`: round trip with and without flag 8, a checksum flip in each new header field, stray bit 4+, duplicate section names, flag 8 without both names.
- **R3. Recovery state out of the meta.**
  - Write the generation's state as its own immutable section `state-N.hybstate`: XXH3 like the others, published before the manifest, pruned and allocated with its generation.
  - Bind it in the manifest by length and checksum. That is flag bit 4 (16) in v2.2 with 16 header bytes and one payload string, or a field inside the flag-8 extension if the builder shows that is simpler; state which.
  - **Only writers read it** (`apply.zig`'s previous-generation path), with the PR's precedence: the bound state, then a matching INDEX-STATE, then the conservative reconstruction. The open never touches it.
  - Keep the PR's recovery tests and point them at the section. Add a corruption test (a flipped byte refuses the write with a stated code; the reader still opens).
  - Gate: the MANIFEST of a 10k index stays under 1 KiB without filename (main: 533–540 B).
- **R4. Filename sections load lazily and are checked cheaply.**
  - `ss_open` reads neither filename section. The first filename or both query loads both once per handle under `scope.Loads` (the S4-T1 pattern): checksum, counts and a structural walk, with the decoded catalog and lexical index kept on the handle.
  - Move `filename_field.validate`'s full rebuild to writers (after building, before publishing) and to a test, not the open.
  - `index_status` reports the policy id from the manifest alone.
  - Extend `lazy_open_test.zig`: filename sections not read at open; a damaged catalog fails the first filename query with a stated code while content queries keep working; the concurrent first-use test covers the filename load.
- **R5. The filename query becomes linear.**
  - Store, or build once at load, the catalog→body-anchor ordinal map; no `findAnchor` scans.
  - Hoist the scoped average and `N` out of the posting loop (once per query).
  - Use the lexical section's own term lookup, not a linear `termIndex`.
  - No decode per query.
  - Keep the exact semantics. The six frozen cases, the Python↔native parity and the hidden-parity tests must pass unchanged.
  - Gates (ReleaseSmall, this Mac, PR script with ReleaseSmall binaries, 30 queries): filename and both p50 **≤ 5 ms at 10k files**, with growth from 1k to 10k under 15× (today 99.6×).
  - Fix `openConfined` here too: open the declared root once (prefix links followed, as `confineFile` already allows), then no-follow for every component below it. Add a test with a root declared through a symlinked prefix: indexed, not `unreadable`.
- **R6. CLI and `ss_index_folder` keep the setting.** `indexer.Caps.filename_index` becomes `?bool`. `--filename-index` sets true and omission keeps it. Tests for `searchd index --update` and Dart `indexFolder` on an enabled directory.
- **R7. Budgets re-measured, S4-T1's gates kept.** In the Report, before (f45c06d) and after, on S4-T1's 10k timing corpus and harness (rebuild the drivers; commit them this time under `zig/bench/` or `scripts/`):
  - `ss_open` p50 of 30 is within 10 % of main's 7.2–9.1 ms with filename off. With filename on, it is no more than main's plus 1 ms, since the open now touches only the manifest.
  - The first filename query after a cold open is reported.
  - One changed file in ReleaseSmall stays ≤ 200 ms (NFR-12), filename off and on.
  - NFR-13: the 10k test passes at 64 MiB unchanged. Add a filename-enabled 10k variant (`find`, `search_knowledge`, a filename query, a both query) under the same cap, with peaks.
  - The 292cb568 compat test passes, plus an assertion that the upgraded generation has no filename sections.
- **R8. Natives** by S3-T8's recipe on this Mac:
  - `tool/build_native.sh` with the NDK, then a second build with fresh `ZIG_GLOBAL_CACHE_DIR`/`ZIG_LOCAL_CACHE_DIR` must be byte-identical (`git status` empty).
  - `check_native.sh` ok and `bundle_probe.sh` `PROBE RESULT: ok` with `ss_version=2.2.0`.
  - `SOURCE-SHA256` from `tool/source_digest.py`, with sizes and sha256 in the Report. `searchd` rebuilt.
  - Keep `.github/workflows/native-package.yml` as a cross-check only: its macOS and Android outputs must match this Mac's bytes (state it). Its iOS binary is not adopted (runner SDK 17.5 against 27.0, see 2.3).
- **R9. Docs.**
  - `docs/authorization.md` and `docs/mcp-server.md`: scoped writers cannot declare roots or read files.
  - `docs/manifest-format-v2.md` v2.2, `docs/filename-field-format-v1.md` and `docs/folder-knowledge-implementation.md`: the state section, the filename sections, lazy load.
  - CAP-16/FR-16 status aligned in the register and specification.
  - `PROJECT-STATE.md` and `docs/journey/03-next.md`: move the CAP-16 row; give the consumer row the 2.2.0 pin, the opt-in recipe and the rollback rule.
  - `docs/tasks/recovery-filename-integration.md` gets a pointer to S4-T2. This task's Report covers deviations, numbers, and the PR author's credit (the commits are preserved by the merge).
- **R10. Suites.** All in the worktree after the last change, with counts in the Report:
  - Zig (expect 277 or more), ABI, Python with and without Zig, MCP/surfaces, family-folder judgments v2 (0 skipped), relevance smoke, `dart analyze`/`dart test` against the rebuilt dylib.
  - `check_requirements.py`, `check_no_home_paths.py`, trailing whitespace.
  - The Linux `checks` CI green after the merge (the verifier checks the run).
- **R11. The consumer pin** is the app's task. It is named in the Report with the 0.3.0 API list (section 4 here) and the statement that filename search needs a fresh directory.

---

*Scratch worktrees used for this review (`review-pr21`, `review-pr21-merge`) were removed with `git worktree remove`. No repository was changed.*
