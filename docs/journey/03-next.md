# Next

**1 Nov (S4-T2, Xcode Mac): PR #21 integrated, verified and on `main` (fast-forward; the verifier re-measured at low load `ss_open` 7.29–7.33 ms against 7.23–7.26 on f45c06d, one changed file p50 147.5 ms off and 172.5 ms with filename sections against 140.9, filename query p50 0.028 ms at 10k; 0.2.1 and 292cb568 refuse every 0.3.0 generation with `UnsupportedFlags`).**
The filename channel (CAP-16, opt-in), recovery state bound to each generation and scoped
writers, merged with the author's commits kept; contracts 2.2.0, Dart 0.3.0, natives rebuilt
(`SOURCE-SHA256` `978c0e57…63d4dd`). Manifest v2.2: filename sections are flag bit 3, the
recovery state its own section `state-N.hybstate` (bit 4) read only by writers. S4-T1's
gains hold on the 10k index (ReleaseSmall): `ss_open` 7.31–7.39 ms against 7.33–7.35 on
f45c06d, MANIFEST 576 B (696 B with filename sections), one changed file p50 148.3 ms (172.6
with filename sections; f45c06d 141.3), NFR-13 peak 52.3 MB (57.2 with filename sections;
f45c06d 60.7). Filename query p50 0.023 ms over RPC at 10k; the first one after an open
loads the sections (4.8 ms). **For the consumer app:** the pin row below. [S4-T2](../tasks/S4-T2.md).

**1 Nov (S4-T1, Xcode Mac): the phone-side costs are verified and on `main` (fast-forward; the verifier re-measured open 110 -> 7.6 to 9.1 ms and one changed file p50 232 -> 149 ms, ReleaseSmall).**
`ss_open` is lazy (10k index 102 -> 7.2 ms, ReleaseSmall p50 of 30); one changed file in the 10k
index is 154–158 ms in `ReleaseSmall` (was 243–249 ms; XXH3 section checksums, manifest v2.1, so
NFR-12's bound is `ReleaseSmall` again); NFR-13 has its 64 MiB arena-cap test (peak 60.6 MB on
the 10k index); the lexical `search_knowledge` is 20.5–21.3 µs on the small fixture (was
35.5–36.8). Dart 0.2.1, contracts 2.1.0, natives rebuilt. **For the consumer app:** pin bump
after the merge (the app's task); an index written by the old pin still opens and updates, but
the old library cannot read an index the new one wrote. [S4-T1](../tasks/S4-T1.md).

**31 Oct (S3-T8 builder, Xcode Mac): series S3 (folder knowledge, CAP-19) is complete on this branch.**
S3-T1 to S3-T7 are on `main`; S3-T8 rebuilt the three native libraries (byte-identical to
S3-T6's, 16 KiB aligned), bumped the Dart package to 0.2.0 (contracts 2.0.0; an old library is
refused), moved CAP-19's register rows to `Diagnostic · implemented` and put the benchmark
table in `PROJECT-STATE.md` ("Folder knowledge (S3)"). **What is next is the consumer app's
M16-T1** (its repository): pin the S3-T8 merge commit, regenerate its contract types from
`contracts/tools`, generate its skill file from `skills/folder-knowledge/SKILL.md`, and run
`fixtures/family-folder` as a shared folder on both phones. NEXT rows filed during S3 (all in
"Ready to build now" below): delta sections or a cheaper checksum (NFR-12's `ReleaseSmall`
bound), the `ReleaseSmall` `search_knowledge` regression on a small corpus, and a CI row (the
Linux native job now runs the MCP and surface tests by name and fails on a skip; the judgment
pack and `tests/mcp_client.py` run there too). Still open: NFR-13's 64 MiB arena-cap test is not
recorded (a NEXT row), and CFT-09 stays blocked (interchange carries no chunker id; see the Blocked table). [S3-T8](../tasks/S3-T8.md).

**25 Oct (Codex cloud): directory content search verified; filename design proposed.**
The owner asked for filename and document contents search for LLM retrieval.
[Directory audit/tasks](../tasks/directory-search.md) records the native/Python
probe and baseline suites. [CAP-16](../requirements/cap-16-directory-filename-search.md)
proposes one file-level lexical field and opt-in combined retrieval; filenames
remain unsearchable today. Next design slice is DS-01: exact format/fixture
freeze, independent review and named maintainer approval before DS-02 build.
No new retrieval runtime or library change; prior approval/platform gates remain.

**22 Oct (verifier, Xcode Mac): S1-T22 verified and merged.** The iOS
framework binary is 16 KiB page-aligned as built (Apple's linker over the Zig
static library; `tool/check_native.sh` checks every segment), and
`tool/build_native.sh` is now a digest input. Next: the app re-pins to the
merge sha, sets `searchSimpliCoreIdentity` to `c4e153af…cbc9`, deletes its rounding step in
`tools/ios/bundle_native_libs.sh` and republishes once.
[Task](../tasks/S1-T22.md).

**19 Oct (Codex cloud): SQ-01 design candidate is specified.**
[E-02 / suite-v3 design](../requirements/cap-11-e02-negative-evaluation.md),
[claim #13](https://github.com/ilamgumaran/search-simpli/issues/13), defines the
metric and authorization gates before SQ-02. No runtime implementation is
claimed. SQ-02 requires the final spec's named maintainer approval. PR #12 is
merged (`89fadce`); [PR #11 integration](../tasks/recovery-pr11-integration.md)
requires documentation-conflict resolution and a fresh native rebuild including
iOS on the equipped Mac. It remains open; do not treat both PRs as finished.

**19 Oct (Codex cloud): proposed search quality plan, documentation only.**
Read the [design](../search-quality-plan-2026-10.md) and
[SQ task breakdown](../tasks/search-quality-follow-ups.md). Suggested first slice:
SQ-01/SQ-02, negative-query evaluation, followed by the offline regression gate.
The real-folder baseline, fusion experiment, Unicode migration and persisted
384-d benchmark have explicit dependencies and acceptance checks. No future task
is claimed or implemented; existing E-01A/CAP-14 approvals and S1-T9 owner
sequencing remain intact. Main's S1-T21 is verified iPhone support; recovery
[PR #11](https://github.com/ilamgumaran/search-simpli/pull/11) remains open and its
conflicting S1-T21 numbering needs reconciliation before landing. Historical
entries below describe their own dates; use PROJECT-STATE for current behavior.

**15 Oct (tester, Xcode Mac): S1-T20 verified and merged.** The owner's Codex cloud work of 13–14 Oct is on `main`: at an exhausted `u64` generation the `NoFreeGeneration` line lists every trace at the top number, in the fixed order `MANIFEST`, `INDEX-STATE.json`, `documents-N.hybseg`, `lexical-N.hyblex`, and says to use a fresh output directory and inspect the listed traces; the "delete or rename that file" promise is withdrawn, and `docs/generation-lifecycle.md` says so. This closes the S1-T18 Verdict findings 1 and 2. On this Mac: Zig 176/176, C ABI 16/16, Python 100, Dart 57/57; the three plants failed as required. Libraries: macOS byte-identical to the cloud's, Android this Mac's rebuild, stamp `f12cb3d3…`; contract unchanged (1.2.0). Carried: a directory or symlink with the exact max name is listed when the other traces sit at max − 1 (ruling 2). GitHub run 38840149959 on the merge green in both jobs. The app re-pins to `15d2c8e`. S1 is idle until the owner reads S1-T9. [S1-T20](../tasks/S1-T20.md)

**15 Oct (tester, Xcode Mac): S1-T19 verified and merged.** The owner's Codex cloud work of 13 Oct (PR #8) is on `main`: on Linux and Android, directory sync reopens `.` as a readable descriptor instead of syncing Zig's `O_PATH` handle, and a separate `native-linux` CI job runs the engine, C ABI and Python process suites with checksum-verified Zig 0.16.0. Round 1 on this Mac was rejected because the harness's `_POSIX_C_SOURCE` hid `mkdtemp` on macOS; the round-2 fix, `zig/tests/abi_test.c` only, also defines `_DARWIN_C_SOURCE` on Apple. On this Mac: Zig 173/173, C ABI 16/16, Python 98, Dart 57/57 with clean analysis; GitHub run 38838411456 green in both jobs. The macOS dylib is byte-identical to before; the Android library that merged is this Mac's rebuild. Contract unchanged (1.2.0). Carried, not fixed: `openDir` failure in `syncDirectory` maps to `error.Unexpected`; actions pinned by major tag, not sha; the `checks` job has no `permissions:` block. Next: S1-T20 (blocking-generation diagnostics, built in the cloud on top of S1-T19), to be verified on this Mac. [S1-T19](../tasks/S1-T19.md)

**13 Oct (Codex cloud): S1-T19 repairs Linux publication and adds native CI.** The owner asked to pull latest Search Simpli and proceed with improvements. Main `b722c45` failed 42 native tests because `fsync` received Zig's `O_PATH` directory descriptor; the C harness also failed to compile. The review candidate `task/S1-T19` now passes the local engine, ABI, Python and Dart checks, with matching rebuilt libraries and unchanged contract 1.2.0. Read [S1-T19](../tasks/S1-T19.md) for independent results, exact skips, CI status and next handoff. Review this branch before landing it. The earlier S1-T9 owner review and judged-benchmark queue remain separate; no new retrieval capability was implemented.

**10 Oct (orchestrator, Xcode Mac): carried, not scheduled (S1-T18 Verdict findings 1–3).** ~~The `NoFreeGeneration` line names only the first file at the top number, so its "delete or rename that file" advice can take several runs when `MANIFEST`, `INDEX-STATE.json` and section files all sit at `u64` max: name every file at the top number, or drop the promise; `docs/generation-lifecycle.md` should say the message names the file.~~ — done in S1-T20 (15 Oct). S1 is idle until the owner reads S1-T9 (leaks); the judged benchmark follows it in the agreed order.

**10 Oct (tester, Xcode Mac): S1-T18 is `verified` and merged to `main`; contract unchanged (1.2.0).** `NoFreeGeneration` now names the file and the number on one line, in the CLI and in `ss_last_error` (the criterion's stray `lexical-18446744073709551615.hyblex` is named; main printed a bare `error: NoFreeGeneration`). The Dart `indexFolder` signature is back to its pre-S2-T14 shape, and the allocator seam is package-private. Libraries byte-identical, stamp `9d1813e5…`. Candidates from the Verdict, not scheduled: finding 1 (with several files at the top number only the first is named, and "delete that file" does not get a publish through: name them all or drop the promise) together with the lifecycle doc sentence (finding 2).

**10 Oct (orchestrator, Xcode Mac):** **S1-T18 is `ready`** (XS; S2-T14 findings 2 and 3): `NoFreeGeneration` names the file that caused it; the Dart allocator test hook leaves the public `indexFolder` signature. The app side of S2-T14's finding 1 (the app's own publish numbering can wedge after a lost `MANIFEST`) is simpli-helper **M12-T11**.

**10 Oct (tester, Xcode Mac): S2-T14 is `verified` and merged to `main`; contract unchanged (1.2.0).** After a lost `MANIFEST` the next self-numbered publish goes above everything on disk: the S2-T12 case gives generation 3 (was 1), and generation 2 is superseded and prunable. `u64` max is a clean `NoFreeGeneration` (was a panic). The Dart `indexFolder` leak is closed. Libraries byte-identical, stamp `b2cf76ee…`. **For the app's M12-T10:** `ss_import_json` publishes a caller's number as given, backwards too, and refuses a taken one with `PathAlreadyExists`, so the app's `ss_open`-based numbering cannot republish after a lost `MANIFEST` (Verdict finding 1). Candidates from the Verdict, not scheduled: findings 2-6 (a huge trace blocks numbering, the public `allocator` seam, the untested free-pair loop, "an arena is fine", `--update` ignoring `--generation`).

**10 Oct (tester, Xcode Mac): S1-T17 is `verified` and merged to `main`; contract unchanged (1.2.0), id still `analyzer-v2`.** The NFC timing test now guards `compose` itself: a 1 MB single-region jamo line, which the old shifting `compose` fails at 15.8-16.0x while the S1-T16 line alone passed it; three stale comments fixed; libraries byte-identical, stamp `477e39a3…`. Candidates from the Verdict, not scheduled: comment nits (the timing test's syllable-twin sentence, T-jamo coverage, `gen_unicode_tables.py`'s docstring) with the next task that touches those files.

**10 Oct (orchestrator, Xcode Mac):** **S1-T17 is `ready`** (XS): the NFC timing test guards the Korean line, not `compose` (S1-T16 finding 1); add a decomposed-Latin family; fix two stale comments.

**10 Oct (tester, Xcode Mac): S1-T16 is `verified` and merged to `main`; contract unchanged (1.2.0), id still `analyzer-v2`.** NFC is linear: a 1 MB Korean line with one mark 11.7 s → 2.2 ms, `searchd index` on it 13.2 s → 35 ms; output byte-identical (`nfc_compare.py` 0, the tester's 931,699-string oracle × 2 seeds 0, every golden and captured output identical). Libraries: stamp `8afa730e…`. Candidates from the Verdict, not scheduled: a single-region line (NFD jamo, no spaces) in `nfc_timing_test.zig`, so the test guards `compose` itself; a linear sort for long runs of stacked marks (`canonicalOrder`, crafted input only); fresh Zig cache dirs for plant runs outside a worktree (a `ROLES.md` line).

**10 Oct (orchestrator, Xcode Mac):** **S1-T16 is `ready`**: NFC recomposition is quadratic and now reaches Korean (1 MB line 48 ms → 17 s; S1-T15 finding 1); ruling: linear one-pass composition, byte-identical output, id unchanged. The app's next core pin is `0abbd8b` (S1-T15) or later: simpli-helper M12-T10.

**10 Oct (tester, Xcode Mac): S1-T15 is `verified` and merged to `main`; contract unchanged (1.2.0), id still `analyzer-v2`.** Zig's NFC equals Python's on every codepoint (23,422 differing cases → 0) and on 220,000 random strings of the tester's own; variation selectors are dropped (`1️⃣` → `1`); every golden and captured output is byte-identical. Libraries: stamp `817b1f70…`. A decomposed Tamil `ொ` query now finds precomposed text. Candidates from the Verdict, not scheduled: a linear NFC composition step (quadratic now also for Korean in the slow path: 256 KB one line 11 ms → 1.1 s; joins S2-T11's candidate); the casefold gap (own task, id ruling); a Tamil blocked-starter case in `nfc_compare.py`.

**10 Oct (orchestrator, Xcode Mac):** **S1-T15 is `ready`**: Zig's NFC skips singleton decompositions and Hangul composition (S1-T14 finding 1; 1,020 + 11,172 codepoints differ from Python), and variation selectors now stay on tokens. Ruling: correct NFC, drop variation selectors; the id stays `analyzer-v2` only if every existing golden is byte-identical. The app's re-pin and one-time republish after S1-T14 is simpli-helper M12-T10.

**10 Oct (tester, Xcode Mac): S1-T14 is `verified` and merged to `main`; contract unchanged (1.2.0), id still `analyzer-v2`.** Tamil words stay whole (marks and inner ZWJ/ZWNJ belong to the token). Absent Tamil words: 11/12 queries with hits (106 hits) → 0/12; the Tamil set stays at 1.00. ASCII and precomposed Latin are byte-identical. Libraries: stamp `eead6954…`. **simpli-helper should re-pin in its next core task and republish every snapshot once:** an old Tamil snapshot answers nothing under the new library (success@1 0/10), because the id did not change. Candidates from the Verdict, not scheduled: complete Zig NFC (singletons, Hangul) or align the Python reference to it; drop variation selectors from tokens; Thai/Khmer/Chinese segmentation; `import_parity.py` query words from `core.tokenize`.

**10 Oct (orchestrator, Xcode Mac):** **S1-T14 is `ready`**: `analyzer-v2` splits Tamil words at vowel signs (`கணினி` → `கண`, `ன`), found by the app's M12-T7 tester with real input; an absent word matched 8 of 12 passages on one-letter fragments. Ruling: tokens include combining marks (Mn, Mc) and ZWJ/ZWNJ; ASCII must stay byte-identical, otherwise it becomes `analyzer-v3` by a separate ruling. The app re-pins after it lands.

**8 Oct, night (orchestrator, M1 laptop): series S2 is closed; the app pins to `main` `0ed134c` or later (latest `0bfa41c`), contract 1.2.0.** On `main`, each verified by a fresh Opus instance against its pre-registered bar: **S2-T1** (`67c2fb9`; the app's import door accepts `analyzer-v2`; Tamil through import 0.00 → 1.00 success@1; 814/814 ranked lists identical between the two doors), **S2-T3** (`c055c80`; rank only matched chunks; 43,154 captured calls byte-identical; p50 at 10k 9–13 ms → 0.02–0.6 ms), **S2-T5** (`7cded2c`; directory sync after the section renames and after `MANIFEST`; opt-in `keep_generations`; round one rejected because a failing second sync deleted the sections the new `MANIFEST` named, proven with an `fsync` interposer on a real process; the rework also heals a `MANIFEST` whose section is missing), **S2-T12** (`f547a94`; a lost `MANIFEST` re-indexes everything and reports `recovered: missing_manifest` instead of publishing an empty generation; Dart exposes `keepGenerations`, `recovered`, prune counts), **S2-T2** (`64ba009`; linear-time ASCII import build: 10k import 113 s → 0.19 s, byte-identical; round one rejected because the timing test failed on correct code under load), **S2-T4** (`0ed134c`; `warnings`, `request`, opt-in `profile` in the query report, contract 1.2.0; round one rejected because the warned term carried the dictionary's casing and a hidden word and an absent word got different messages, an existence test across the label wall; the rework's hidden-vs-absent reports are byte-identical over 2,108 pairs). **Also on `main`, closing the series:** S2-T13 (`4c42716`; non-finite query vectors rejected at the door, bad document vectors refused on import; cosine bit-identical on 10,000/10,000 valid pairs) and S2-T11 (`0bfa41c`; invalid UTF-8 query text rejected before analysis in every door; the old library hung forever on `caf\xff` on any v2 snapshot and crashed in `searchd`; 8,864 adversarial calls and 200,000 fuzz calls, longest 0.3 ms). **Candidate from the S2-T11 verdict, not scheduled:** `analyzer-v2` query time grows quadratically with non-ASCII length (64 KB 58 ms, 1 MB 13 s): a query-length cap or a linear NFC step. **Ready:** S2-T14 (generation numbers go backwards after a lost `MANIFEST`; a small Dart leak). **Process rules learned this series** are in `docs/process/ROLES.md` (rules of 2026-10-08). **For the app:** `agent-download/vizhi-app-orchestrator/10-search-simpli-s2-8-oct.md` in the shared folder and a message to its orchestrator: send `"analyzer_id": "analyzer-v2"`, pin `0ed134c` / 1.2.0, republish once, consider `keep_generations`.

**8 Oct (tester, Xcode Mac):** **S1-T13 is `verified` and on `main`** (merge `61dba12`, on top of S2-T1's `67c2fb9`; Verdict in `docs/tasks/S1-T13.md`). The Dart loader now counts a bundle named `.APP` or `.App` as an app. A real `Probe.APP` loads its own `Contents/Frameworks` copy, where the old loader loaded a decoy from the cwd. A shipped copy that exists but cannot be opened is now reported as "found but could not be opened", with the underlying error, instead of "did not ship". Seven findings, none blocking. The two for a later task: the old, vacuous no-mask test is still there, and the pin test rests on one of its three paths.

**8 Oct (tester, Xcode Mac):** **S1-T12 is `verified` and on `main`** (merge `08a1aee`; Verdict in `docs/tasks/S1-T12.md`). Inside a built macOS app the Dart loader now tries only the override and the exact `Contents/Frameworks` path. There is no bare name, and a missing library is a `StateError` saying the app did not ship it. In a development checkout the package's own `native/` copy comes before the bare name, which is now the last fallback (Linux keeps its exact `<exe dir>/lib` path first). A decoy in the cwd loaded on the old `main` in both cases and is never loaded now; `bundle_probe.sh --decoy` proves it, and the probe now removes its snapshot copies. **simpli-helper should re-pin to this `main` in M7-T2 or its follow-up.** Its macOS app must embed the `.dylib` in `Contents/Frameworks`, because nothing from a checkout is consulted inside an app any more (the override still wins). Open for the orchestrator (non-blocking findings): a bundle named `*.APP` is not recognised as an app, so a cwd decoy beats its bundled copy; the error says "did not ship" even when the copy shipped but failed to open; and two test gaps. Suites: Zig 112, ABI 12/12, lib 15/15, Python 79, Dart 27.

**8 Oct (tester, Xcode Mac):** **S1-T11 is `verified` and on `main`** (merge `0e9cd90`; Verdict in `docs/tasks/S1-T11.md`). Inside a built macOS app, the Dart loader now tries the app's own `Contents/Frameworks` copy by exact path before the bare name. A decoy in the cwd, or on the Flutter engine's rpath, loaded under the old order and loses under the new one. `bundle_probe.sh` now exits 1 when a run fails to answer and prints the sandbox value. Open for the orchestrator (non-blocking findings): with no copy in the bundle, the bare name still loads a stray copy, and the tester judges that an app should refuse it. A development checkout still lets a stray copy in the cwd beat `native/`. Suites: Zig 112, ABI 12/12, lib 15/15, Python 79, Dart 23.

**8 Oct (tester, Xcode Mac):** **S1-T10 is `verified` and on `main`** (merge `855736e`; Verdict in `docs/tasks/S1-T10.md`). Inside a built macOS app, the Dart package now opens `libsearch_simpli.dylib` from `Contents/Frameworks`, with the sandbox off and on, launched by executable and by `open`, with no `SEARCH_SIMPLI_LIBRARY_PATH`. **simpli-helper M7-T2 may now re-pin** to this `main` and drop M7-T1's test-only copy into the container. The app must ship the `.dylib` in `Contents/Frameworks`, signed with the app. Non-blocking verdict findings: the bare-name step searches the cwd and `/usr/local/lib` before the bundle; `bundle_probe.sh` always exits 0. Suites: Zig 112, ABI 12/12, lib 15/15, Python 79, Dart 23.

**8 Oct (orchestrator, Xcode Mac):** **S1-T10 is `ready`** (the Dart package finds `libsearch_simpli.dylib` inside a built macOS app bundle; needed by the app's M7-T2). Dart-only; no contract or stamp change, so it should not collide with S2-T1. The Xcode Mac runs S1-T9 (owner's read pending) and S1-T10; the M1 runs S2 as stated below. Both pull before every push.

**8 Oct (orchestrator, M1 laptop; the owner's ask of 8 Oct):** `docs/research/2026-10-luxir-learnings.md` is on `main`: what Yonik Seeley's Luxir teaches this engine, and three measured findings about our own paths that matter more: the app's publish path (`ss_import_json`) accepts only `ascii-alnum-v1`, so **the app cannot search Tamil** (Tamil fixture 0.00 through that path, 1.00 through `searchd index`); that path's dictionary build is about 100× slower than the folder path (108 s for 10k documents); and every query sorts the whole corpus three times (94 % of query time). **Series S2 is cut from it:** S2-T1 (Unicode analyzer on import; contract 1.1.0), S2-T3 (rank only matched chunks), S2-T5 (directory fsync; `keep_generations`) build first in parallel; S2-T2 (import build) after T1; S2-T4 (warnings, profile, request echo) after T3. S2-T6..T10 (fuzzy, folding and stemming, title field, in-place postings, positions) wait for the harder judged fixture ("J2"); the research doc §3.0 says which slices J2 needs. The M1 runs the S2 loop; the Xcode Mac keeps S1-T8+ and everything else. After S2-T1 the app must send `"analyzer_id": "analyzer-v2"` and re-pin the core: an app task for the app's orchestrator.


**4 Oct (orchestrator, Xcode Mac):** **S1-T8 is `verified` and on `main`** (`7a78ce0`; merge `4279ea1`; GitHub CI green). Every usage error on `searchd` now prints one line and exits **2**, decided before any work starts; failures of the work stay **1**; numbers are digits only; `--help` goes to stdout. A process test (`tests/test_cli_process.py`) pins those statuses on the real binary. CI sets `SEARCH_SIMPLI_NO_ZIG=1` because its runner has no Zig by design, and the test skips only on that flag. Round 1 was rejected and round 2 verified; both verdicts and the landing note are in `docs/tasks/S1-T8.md`. Suites: Zig 112, ABI 12/12, lib 15/15, Python 79, Dart 18.

**Carried forward from the S1-T8 verdicts (not scheduled):** `index --update` panics with an integer overflow when a snapshot's generation is u64 max (`generation_alloc.zig`, shared with the library; practically unreachable, but it deserves its own task). CLI rough edges: no `--flag=value` form; `--` is not end-of-options; a repeated flag takes the last value silently; flags before positionals name the wrong token; `serve --help` is read as a directory; empty-string paths fail as work errors with a trace; `--http 127.0.0.1:0` prints port 0; truncating a long multi-byte value can split a character; limit errors do not quote the value. Tests to strengthen: the truncation test, the source scan (it lists the old spellings only), and the exit-1 pin for `index`. An unreadable *subfolder* makes `index` fail with exit 1 while an unreadable *file* is only counted. **Proposal for the owner:** a pinned Zig 0.16.0 step in CI, which would also run the Linux x86_64 binary for the first time.

**Next, in the agreed order:** memory-leak measurement under a long-running caller (the app is one), then a harder judged benchmark, then hybrid only if that benchmark shows where keyword search loses.

**2 Oct (orchestrator, Xcode Mac):** search-simpli is run from the Xcode Mac from today (agreed with the M1 orchestrator at the owner's request; task ids from S1-T8). **S1-T8** is `ready`: every usage error on the CLI gives one line, with **exit 2 for usage errors and 1 for failures of the work** (owner's ruling), plus digits-only numbers and `--help` on stdout. Queue after it, in order: memory-leak measurement under a long-running caller, a harder judged benchmark, and hybrid only if that benchmark shows where keyword search loses.

**1 Oct (orchestrator, M1 laptop):** two small rounds landed on `main` on 30 Sep and both are `verified`: **S1-T6** (`ccd8076`: `budget_exhausted` on the CLI's non-update line, the self-referential README row removed, `check_no_home_paths.py` anchored at the repo root, one sentence above the caps table, and a freshness guard, `native/SOURCE-SHA256`, that fails when the prebuilt libraries are older than the Zig source) and **S1-T7** (`c8e2d16`: the digest covers `contracts/CONTRACTS_VERSION`; bad numbers on the CLI fail with one line and no stack trace). Suites: Zig 103, ABI 12/12, Python 71, Dart 18. **Anyone holding a local S1-T6 draft on another machine: pull first; that id is taken.** Run this repository's suites with `SEARCH_SIMPLI_LIBRARY_PATH` unset (`docs/process/ROLES.md`, rule of 30 Sep).

**What is not next here any more:** the list further down this file still names M12-T0 and M11-T1 as the queue; both merged in the app on 18 and 19 Sep. **Hybrid ranking:** the core accepts query vectors, the native folder indexer builds lexical segments only, and the app pins lexical mode; the app's own record of why is `simpli-helper/docs/tasks/M12-T0.md` criterion 3 (no embedding channel in the app yet; M12-T1 is where hybrid becomes real). The app pins `fd80e6b`; moving the pin to `main` is a small app task, not yet cut.

**Open, small, not scheduled** (from the S1-T7 verdict): the byte-count options accept `+5`, `-0` and `1_000`; an unknown flag still prints a stack trace after its message; an unknown command and a bare `searchd` exit 0.


**26 Sep:** S1-T5 is `verified` and merged to `main` (`c4cd8d0`) after being rejected on its first pass and reworked on Sonnet 5 — both verdicts are in `docs/tasks/S1-T5.md`. The round-C follow-ups are closed; **next is the owner's call**, with the two queued items below (`simpli-helper` M12-T0 re-pinning to this `main`, then M11-T1 using `indexFolder`) still the standing candidates. An adopter re-pinning now should note the shipped libraries changed again (`dylib` 382,088 B `cbaaa9f6…`, `.so` 382,288 B `c5f0b056…`) and that the two size caps now bite on a full rebuild where they were silently inert; `CONTRACTS_VERSION` is still `1.0.0`.


**From 2026-09-13 (owner's decision): Search Simpli becomes standalone and portable, then the family app adopts it.** See `docs/decisions/0002-standalone-portable-platform.md` and the tasks in `docs/tasks/` (S1-T0 C ABI + libraries, S1-T1 native chunker/Unicode analyzer/CLI, S1-T2 Dart FFI package, S1-T3 incremental folder indexing, S1-T4 round-C hardening). Process in `docs/process/ROLES.md`.

**Round A is done (17 Sep).** S1-T0 and S1-T1 are `verified` and merged to `main` (`3466083`, `3a17af8`). The engine has a C ABI and static/shared libraries for macOS arm64, Android arm64, and Linux x86_64; `searchd index/query/evidence/serve` indexes a folder natively with `analyzer-v2` (NFC, Unicode categories, case folding) and `line-window-v1`, both conformant to the Python reference (85/85 chunks, 36/36 full BM25 rankings, Tamil 10/10). Numbers, sizes, and the carried-forward gaps are in `PROJECT-STATE.md`'s "Standalone platform status" and in each task file's Verdict.

**Round B is done (17 Sep).** S1-T2 and S1-T3 are `verified` and merged to `main` (`beb4e4a`, `4ac5b3e`), plus `3602ebd` rebuilding the Dart package's shipped libraries from the merged engine.

- **S1-T3 — incremental folder indexing in the core.** `ss_index_folder` and `searchd index --update`: per-file SHA-256 hashes in `INDEX-STATE.json`, unchanged files skipped, deleted files tombstoned, one JSON report shape for both entry points, per-file and total byte caps. Re-publishing into an existing `--out` works, which was round A's sharpest rough edge. The round-A timing finding is closed twice over: `lexical_build.build` *and* `lexical_segment`'s duplicate-term check both became hash lookups, taking a 24,057-term/1,000-file corpus from 7.10 s to 0.12 s (tester-measured against the previous binary on the identical corpus), and the timing generator now guarantees ≥20,000 distinct terms instead of 57. Publication no longer uses `O_TMPFILE` anywhere, which is what made publishing work inside an Android app's private directory.
- **S1-T2 — Dart FFI package** under `bindings/dart/search_simpli/`: `ffigen` bindings, a `SearchSimpli` class with typed results matching `contracts/search-tool.schema.json`, `CONTRACTS_VERSION` asserted against the native library at open, prebuilt macOS arm64 and Android arm64 libraries, `dart test` 12/12, and an Android instrumentation smoke test on the emulator. Conformance re-measured by the tester at 18/18 complete rankings against the Python golden and 34/34 full top-5 against the CLI.

Numbers, sizes, hashes and the carried-forward gaps are in `PROJECT-STATE.md`'s "Standalone platform status (round B)" and in each task file's Verdict.

**Round C is done (17 Sep).** S1-T4 is `verified` and merged to `main` (merge `d860bb1`, verdict `ddb72a6` — `main`'s head). Hardening only: every non-blocking finding the round-B verdicts raised is closed.

- **S1-T4 — round-C hardening.** `ss_index_folder` is bound as `SearchSimpli.indexFolder` (typed `IndexFolderReport`, tested on the Mac and against the app's own private storage on the API 34 emulator). The macOS/Linux loader resolves `native/` **package-relatively** from `.dart_tool/package_config.json`, so the README's `path:`-dependency install works with no `SEARCH_SIMPLI_LIBRARY_PATH` (which still overrides) — proven by the tester from a fresh consumer package outside the checkout. The report JSON splits `skipped` into `unchanged` and `budget_exhausted` and names `too_large`/`unreadable` files instead of only counting them; an empty folder or a last-file deletion publishes an empty, queryable generation instead of `error: NoDocuments`; a file grown past `--max-file-bytes` is both reported and tombstoned; `lifecycle.scan` no longer calls `INDEX-STATE.json` an unknown file. `docs/incremental-indexing.md` is rewritten to the shipped design, the four live "API 37" labels are corrected to API 34 (Android 14), and the README's full-rebuild figure is re-measured (0.12 s, not 0.30 s). The shipped libraries were rebuilt and are byte-identical to the committed ones.

Numbers, sizes, hashes and the carried-forward gaps are in `PROJECT-STATE.md`'s "Standalone platform status (round C)" and in `docs/tasks/S1-T4.md`'s Verdict.

**The owner has paused this work after round C**, until later in the weekend. The two items below are the queue when it resumes.

**Next, in order.**

1. **`simpli-helper` M12-T0 re-pins to this `main` and adopts the core.** The app replaces its Dart lexical port with this package: add `bindings/dart/search_simpli` as a path dependency, package `libsearch_simpli.so` as a jniLib for `arm64-v8a`, pin `CONTRACTS_VERSION`, and delete the duplicate ranker. If M12-T0 was started against round B's `main`, it should re-pin to `ddb72a6`: the shipped libraries changed (381,592 B / 381,728 B, new `sha256`), the report JSON's `skipped` field is gone, and both round-B blockers for the app are closed — the loader no longer needs `SEARCH_SIMPLI_LIBRARY_PATH` in development, and `ss_index_folder` is bound.
2. **`simpli-helper` M11-T1 uses `indexFolder`.** Once the app is on the core, indexing a real folder on the device is a call, not a port: `SearchSimpli.indexFolder(dir, folder, options: IndexFolderOptions(update: true))` on a schedule or on demand, reading `unchanged`/`budget_exhausted`/`too_large_paths`/`unreadable_paths` out of the typed report to decide what to tell the family. The binding this used to wait on landed in round C and is proven against app-private storage on the emulator; a long-running caller is also where the unmeasured leak-freedom claim would first show up.

Still open from round A and unchanged: `analyzer-v2`'s case folding is simple rather than full, so `ß`, `ﬁ`, `ﬀ`, and `İ` do not fold — fine for the current fixtures, a decision to make explicit before the app ships it; and the Linux x86_64 binary is cross-compiled but has never been executed.

---

# Next — the live queue

Updated: 2026-07-31. Keep this short and current. The full backlog with *why* and
exit checks is [`IMPROVEMENT-BOARD.md`](../../IMPROVEMENT-BOARD.md); the exact
implementation state is [`PROJECT-STATE.md`](../../PROJECT-STATE.md).

## The one thing that unblocks the most

**E-01 — a representative, user-derived judged corpus.**

Every relevance number today comes from authored fixtures or a sampled public
dataset. That is honest diagnostic evidence, and it is *not* a production
relevance claim. Until a real corpus with independently authored queries exists:

- CAP-14 (trust calibration) cannot set its threshold;
- CAP-15 (structure-aware chunking) cannot prove a code-search gain;
- fusion/routing work (F-01) cannot be trusted beyond the diagnostic.

### It now has a specified path — awaiting one human decision

[**E-01A — real-folder judgment packs**](../requirements/cap-11-e01a-judgment-packs.md)
(merged as specification only) defines the privacy-bounded workflow: inventory a
real single-owner folder without copying content, separate tuning from a frozen
holdout, seal both with an explicit human confirmation over exact hashes, and
fail closed on drift, split leakage, or post-confirmation edits.

> **Blocking action, and it is a human one.** Implementation cannot begin until a
> maintainer posts an explicit step-6b approval covering §6 (invariants), §8
> (CFT-11–13), and §9 (the acceptance gate and its named `pending` criteria), and
> the approval block cites that comment. An agent may not supply this.

The leverage move remains **L-02** — do not hand-label from zero. Let the system
propose labels from behavior and have a human confirm, correct, or overrule.
That turns the corpus chore into a partnership and builds the Stage-2 machinery
at the same time. E-01A is the safe intake half of exactly that.

## Ready to build now

| Item | Why it is ready | Note |
|---|---|---|
| **E-02 — negative / unanswerable evaluation** | Small, self-contained, and it is the empirical guard on the source-of-truth invariant | Feeds CAP-14 |
| **Delta sections for `apply_changes` (S4-T1 candidate (b), filed)** | S4-T1 shipped the cheaper checksum (XXH3-64 sections, manifest v2.1), which met NFR-12 in `ReleaseSmall` (one changed file in the 10k index 154–158 ms, was 243–249 ms; five runs). Its scratch prototype of delta sections (a generation whose sections hold only the changed records, through the same publication path, `ReleaseSmall`, five runs) measured 102–130 ms (p50 105.7) with FNV-1a and 68–93 ms (p50 71.4) on top of XXH3; the prototype omits the reader's merge of base and deltas at every query, compaction and the manifest's delta chain, so these are lower bounds for the writer only. What remains after XXH3: reading the previous generation about 41 ms, the positional lexical rebuild 37 ms, encoding 40 ms, gathering 19 ms (S4-T1 Report) | Worth it only if a phone needs one changed file well under 100 ms or the corpus grows past 10k files; a format change (deltas, compaction share, reader merge) with its own task and a `docs/incremental-indexing.md` design |
| **Consumer app: pin bump to S4-T2** | The app's task, not this repository's. Pin the head of `main` after the S4-T2 merge (contracts 2.2.0, Dart 0.3.0, `native/SOURCE-SHA256` `978c0e57…63d4dd`); the 0.3.0 API is additive (CHANGELOG). Not opting in changes nothing in the app's results. **Opt-in recipe:** filename search needs a fresh directory: pass `ApplyChangesOptions(filenameIndex: true)` to the first `applyChanges` on a new, empty directory (or `IndexFolderOptions(filenameIndex: true)` to `indexFolder`), feed every file's bytes, then switch to it; later calls may omit the option (kept); query with `mode: RetrievalMode.lexical, searchField: SearchField.filename` or `.both`; results carry `matchedIn`, `basename`, `matchSections`. **Rollback rule:** a library older than 0.3.0 refuses every directory 0.3.0 has written or updated (`UnsupportedFlags`), with or without filename search, so keep the previous directory to roll back to; never roll the library back over an updated directory. An index written by 0.2.1 opens (7.34–7.36 ms on the 10k index) and its first update rewrites it as v2.2 | After the S4-T2 merge; M16-T8's device pass can re-take the open |
| **NFR-13 headroom past 10k files** | S4-T1's arena test holds the 10k index inside 64 MiB with 10 % to spare: the open alone 53.6 MB, `list_files` 60.7 MB, `find` 59.9 MB (peak live bytes, S4-T1 Verdict); after S4-T2 open 45.2 MB, `list_files` 52.3 MB, and with filename sections open 50.1 MB, `list_files` 57.2 MB (S4-T2 Report). A folder somewhat past 10k files would breach the cap. Measure the peak at 10k, 15k and 20k files and decide whether the open's resident tables (paths, statistics) or `list_files`' result must be bounded or paged before a phone folder grows past 10k | Before any phone folder passes 10k files |
| **Filename query complexity guard (candidate, claim #22)** | Protected-body and bounded-query-scratch tests at 1k/10k, including scope/labels; comparator self-read removed. A restored anchor scan is rejected by actual memory protection, not a timing estimate. | Implemented on `improve/filename-complexity-guard`; [verification and limits](../tasks/filename-complexity-guard.md). Pending PR review; not merged. |
| **One changed file with filename sections: headroom and the duplicated state** | After S4-T2 one changed file in the 10k index is p50 147.5 ms with filename off and 172.5 ms with filename sections at low load, 181–185 ms (worst 189.8) at load 5–7, against NFR-12's 200 ms (f45c06d 140.9). Each generation also writes `state-N.hybstate` (2,522,562 B at 10k), which duplicates `INDEX-STATE.json`. Profile the filename writer path and decide whether `INDEX-STATE.json` can become a pointer to the bound section or the section can shrink | Before a phone folder with filename search grows past 10k files, or together with the delta-sections row |
| **CI: keep the surface and MCP tests from skipping** | S3-T8 added a named, no-skip step to the Linux native job; the first GitHub run decides whether it is green | Check the run after the merge |

## Blocked, with the named unblocker

| Blocked | Blocked by | Unblocker |
|---|---|---|
| **CAP-13 / I-01 — MCP adapter** | No longer blocked on approval: approved with CAP-19 (owner, 2026-10-31; CAP-19 FR-24 realizes CAP-13), built by S3-T6 (`searchd mcp`, `Diagnostic · implemented`, I-01 done). Updated by the S3-T8 verifier | *Validated* still needs a real agent over a judged snapshot (CAP-13 §10, I-01) |
| **CFT-03** — CAP-12 interaction ledger vs INV-09 | The "capture is cheap and reversible" claim is unmeasured | Measure Stage-1 capture overhead, then a maintainer confirms INV-09 compliance |
| **CFT-09** — CAP-15 durable path vs INV-04 | `CON-03` and the Zig manifest/`index_status` do not carry a chunker id/version | Add a versioned chunker-identity field through interchange → manifest/status, with a migration plan. Until then CAP-15 is **Python-only** |
| **CAP-14 threshold** | No negative-bearing judged corpus | E-01 + E-02 |

## Open loose end

- **Persisted 384-d startup / memory / concurrency benchmark** remains the gate
  that decides whether the next engine work is ANN, lexical pruning, or simply
  better process management. No scale machinery before it.

## Standing candidates (not yet scheduled)

From the board, in rough value order: **S-01** trust-calibration signal ·
**S-02** plain-language "why this ranked" · **F-01** query routing to address the
observed equal-RRF regression · **O-01** collaborative knowledge model ·
**L-01** interaction ledger (after CFT-03) · **O-02** authenticated identity.

## How to pick

1. Prefer the item that **unblocks the most other items**.
2. Prefer the item whose **acceptance gate is already decidable**.
3. Do not start anything whose gate depends on an unbuilt capability — rescope it
   or mark the criterion `pending` first.

## 2026-11-01 — S4 started: the phone-side costs

**1 Nov (S4-T1 builder, Xcode Mac): three "Ready to build now" rows done.** (1) *`ss_open` lazily*: the source section loads at the first `read_span`/`outline`, the statistics at the first scored query that names a scope, the position tables at the first `find`; `ss_open` on the 10k index 102.2–103.2 → 7.16–7.44 ms (24.95–25.38 ms on an index written before S4-T1), open + first `read_span` 19.2–19.3 ms, open + first scoped query 8.3 ms (ReleaseSmall, p50 of 30, two rounds). (2) *NFR-13*: `zig/src/nfr13_arena_test.zig`, five operations over the family folder under a 64 MiB capped allocator (peak 9.4 MB) and `find`/`search_knowledge` over a 10k index (peak 60.7 MB generated, 60.6 MB on the benchmark corpus); NFR-13 is `Diagnostic · implemented`. (3) *the ReleaseSmall `search_knowledge` regression*: profiled to the fuse stage (identical source, 11–12 → 17–18 µs, a codegen effect); an 8-line fix skips the two sorts for a single channel: 35.5–36.8 → 20.5–21.3 µs on the union fixture, 48–51 → 32–34 µs on the 10k corpus. The NFR-12 row became the delta-sections row above (candidate (b), filed with its prototype numbers). [Task](../tasks/S4-T1.md).

**1 Nov (orchestrator, Xcode Mac): S4-T1 written and started.** The three measured S3 rows that a phone feels (the 102 ms `ss_open`, the 215 ms one-changed-file in ReleaseSmall, the unrecorded NFR-13 arena test) and the ReleaseSmall `search_knowledge` profile are one task, built by Claude Opus 5.5 from `origin/main`. The consumer app has every S3 surface in use (its M16-T1 to T7, T9 merged 31 Oct–1 Nov; the device pass pending). [Task](../tasks/S4-T1.md).

## 2026-10-31 — S3 folder knowledge approved

CAP-19 (`docs/requirements/cap-19-folder-knowledge.md`) was approved for build by the owner on 2026-10-31. Tasks `docs/tasks/S3-T1.md` … `S3-T8.md`; order T7 → T1 → T2 ∥ T3 → T4 → T5 → T6 → T8; details in `docs/folder-knowledge-implementation.md`. S3-T7 (the frozen family-folder fixture) started 2026-10-31 on `task/S3-T7`.

**31 Oct (verifier, Xcode Mac): S3-T7 verified and merged (round 2).** The family-folder fixture and `judgments.json` version 2 (13 scenarios, 5 phrase, 5 prefix, 5 outline, 8 `read_span`) are frozen on `main`; `read_span` hashes include the last line's terminator; x1's front-matter line is an expected engine miss. Next: S3-T1. [Task](../tasks/S3-T7.md).

**31 Oct (verifier, Xcode Mac): S3-T1 verified and merged.** Manifest v2, `md-section-v1`, records v4 and the retained source section are on `main`; `read_span` and `outline` answer the frozen pack exactly in the Zig core and the Python reference (outline 7/7, read_span 9/9); native libraries rebuilt (`9ba263a2…`). Next: S3-T2 and S3-T3. [Task](../tasks/S3-T1.md).

**31 Oct (verifier, Xcode Mac): S3-T2 verified and merged.** `HYBLEX02` positions and offsets and `find` (words, phrase, prefix, snippets, cursors) are on `main` in the Zig core and the Python reference; the frozen pack's phrase and prefix judgments reach precision and recall 1.00 with both expected misses missed; `HYBLEX02` is 1.39× `HYBLEX01` on the 10k corpus. S3-T3 merges next and takes the shared `indexer.zig`/`manifest.zig`/`scoring.zig` lines named in the Verdict. [Task](../tasks/S3-T2.md).

**31 Oct (verifier, Xcode Mac): S3-T3 verified and merged.** Roots, `apply_changes` (host-fed batches with strict content or confined files, deterministic rename pairing, pending, `remove_root`), INDEX-STATE v2 and visible-scope statistics are on `main` in the Zig core and the Python reference; the pack's lifecycle scenarios run (0 skipped). NFR-12's one-changed-file bound is amended to ReleaseFast (168 ms; ReleaseSmall 220 ms reported) with a NEXT row for delta sections. Next: S3-T4 (ABI, CLI, Dart and RPC surfaces, scoped `index_status`). [Task](../tasks/S3-T3.md).

**31 Oct (verifier, Xcode Mac): S3-T4 verified and merged.** Contract 2.0.0: the folder-knowledge operations are on the C ABI, the Dart binding, the `searchd` CLI and the RPC server, all from one JSON producer (`ops.zig`), with CLI/RPC/Dart parity on the fixture judgments; status and evidence are scoped; a lost source section no longer blocks queries; deep `read_span` is fast through a sparse line index. The consumer app re-pins and regenerates its contract types (its `open` refuses a 1.x library). Next: S3-T5 and S3-T6 (MCP), then S3-T8. [Task](../tasks/S3-T4.md).

**31 Oct (verifier, Xcode Mac): S3-T5 verified and merged.** Request and result JSON Schemas for the nine tools (`contracts/tools/`), a standard-library validator, the folder-knowledge skill with its exact negative sentence and an example loop whose every `[n]` maps to a returned hit; the five search_knowledge/list_files shape findings go to S3-T6 with the MCP server, and `docs/README.md` links the schemas in S3-T8. [Task](../tasks/S3-T5.md).

**31 Oct (verifier, Xcode Mac): S3-T6 verified and merged.** `searchd mcp` serves the index over MCP stdio (revision `2025-11-25`): CAP-13's four tools with `--baseline`, the eight read tools by default, `apply_changes` only with `--allow-write` inside `--roots`; results equal the RPC ones for every fixture judgment; the scope comes from the command line only; overhead p95 under 50 µs against the 5 ms gate. CAP-13 is Diagnostic and I-01 done. Next: S3-T8. [Task](../tasks/S3-T6.md).

**31 Oct (verifier, Xcode Mac): S3-T8 verified and merged; series S3 is complete on `main`.** The rebuilt native libraries are byte-identical and 16 KiB aligned (`SOURCE-SHA256` `9f9a58d6…`), the Dart package is 0.2.0 at contracts 2.0.0, CAP-19 is `Diagnostic · implemented` (NFR-13 Proposed, CFT-09 Blocked, both accepted), and the benchmark table is in `PROJECT-STATE.md`. Re-measured: 10k index 0.55 → 0.69 s and 249 → 130 MB (ReleaseSmall), `ss_open` 47.5 → 102 ms (a NEXT row asks for lazy loading). The CAP-13 / I-01 Blocked row is updated. Next: the consumer app's M16-T1 pins this merge. [Task](../tasks/S3-T8.md).

- **S4-T2 · Integrate PR #21 after S4-T1** (1 Nov 2026; verified and merged: [Report and Verdict](../tasks/S4-T2.md)): the filename channel, bound recovery and scoped writers merged with the author's commits kept; contracts 2.2.0, Dart 0.3.0, manifest v2.2 flag bits instead of HYBMAN03, the recovery state in its own section read by writers only, filename sections loaded at first use, a linear filename query (≤ 5 ms at 10k), `openConfined` fixed, natives rebuilt here. Review: `docs/tasks/REVIEW-PR21.md`. The consumer pin follows as an app task.
