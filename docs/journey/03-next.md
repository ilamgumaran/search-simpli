# Next

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

## Blocked, with the named unblocker

| Blocked | Blocked by | Unblocker |
|---|---|---|
| **CAP-13 / I-01 — MCP adapter** | Step-6b maintainer approval is still pending | A named maintainer other than the author approves the recorded requirements, conflicts (CFT-02, CFT-08), and acceptance gate |
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
