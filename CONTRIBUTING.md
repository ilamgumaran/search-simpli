# Contributing to Search Simpli

Thank you for reading this. The repository is public and MIT-licensed. It is kept by one
maintainer with the help of coding agents, so review happens when it can: there is no
promise about review times. What follows is how the project works today, so that a
change you send fits it.

## How to propose a change

- **An idea, a question or a bug:** open an issue on GitHub. Say what you expected, what
  happened, and the commands and output that show it.
- **A change:** open a pull request against `main`. Keep it to one subject, say what it
  changes and why, and paste the output of the suites you ran (below). A failing or
  skipped suite is fine to report; an unreported one is not.
- **A new capability** (a new contract field, index format or C ABI function) starts as
  an issue or a capability document, not as code; see [When a change needs a capability
  document](#when-a-change-needs-a-capability-document).

The maintainer may turn an issue or pull request into a task file (below) so that a
second agent or person verifies it before it merges. You do not need to write one.

## Toolchain

| Tool | Version | Needed for |
|---|---|---|
| Zig | 0.16.0 exactly ([download](https://ziglang.org/download/)) | the engine, `searchd`, the C library |
| Python | 3.9 or later, no packages | the reference, the tests and every script |
| Dart SDK | 3.13 or later | the Dart binding (`bindings/dart/search_simpli`) |

Python 3.9 matters in one place: the analyzer's tables and the goldens are generated with
Unicode 13.0.0, which is Python 3.9's `unicodedata`; on a later Python those regeneration
checks skip (CI runs them on 3.9 in a job of their own). The Android and iOS libraries
need the Android NDK (`SS_ANDROID_NDK`) and macOS with Xcode; see [Native
libraries](#native-libraries-and-the-source-digest).

If your shell exports `SEARCH_SIMPLI_LIBRARY_PATH`, unset it before running anything: it
points the Dart binding at another copy of the library and outranks this repository's own.

## The suites

These are the commands the CI workflow (`.github/workflows/checks.yml`) runs, from the
repository root unless a `cd` says otherwise. The comments say what a passing run shows;
the counts themselves grow as tests are added, so paste the ones your run printed.

**Without Zig** (the `checks` job):

```sh
python3 scripts/check_requirements.py
python3 scripts/check_layers.py
SEARCH_SIMPLI_NO_ZIG=1 python3 -m unittest discover -s tests -v
python3 relevance_smoke.py fixtures/relevance-smoke/corpus fixtures/relevance-smoke/judgments.json \
  --mode lexical --top-k 10 --min-ndcg 1 --min-mrr 1 --min-recall 1 --min-success 1
python3 scripts/relevance_smoke.py --pack family-folder
PYTHONHASHSEED=0 python3 scripts/relevance_smoke.py --pack j2 --output .search/j2.json
python3 scripts/j2_gate.py .search/j2.json
```

(The tests that need Zig are skipped here, and the run says how many.)

**Zig engine and C ABI** (the `native-linux` job):

```sh
python3 scripts/check_layers.py              # the static guard: every test file reached
python3 scripts/check_test_counts.py --run   # zig build test --summary all: none failed,
                                             # each step's total equals the listing, and
                                             # the static checker passes
cd zig
zig build test-abi --summary all    # abi_test: every check passed
cd ..
env -u SEARCH_SIMPLI_NO_ZIG -u SEARCHD_BINARY python3 -m unittest discover -s tests -v   # the Zig tests run too
```

The Python suite builds a Debug `searchd` itself when it finds Zig on `PATH`.

**Release builds** (the `native-linux-release` job). A defect once showed only in
`ReleaseSmall`, so the same suites run there too:

```sh
python3 scripts/check_layers.py
python3 scripts/check_test_counts.py --run -- -Doptimize=ReleaseSmall
cd zig
zig build test-abi -Doptimize=ReleaseSmall --summary all
zig build -Doptimize=ReleaseSmall --prefix ../.search/release
cd ..
SEARCHD_BINARY="$PWD/.search/release/bin/searchd" python3 -m unittest discover -s tests -v
```

**Unicode 13 goldens** (the `unicode-13-goldens` job, Python 3.9 only):

```sh
python3 scripts/ci_unicode_goldens.py --check-version
python3 scripts/ci_unicode_goldens.py
```

**Dart binding** (not in CI; run on a Mac):

```sh
cd bindings/dart/search_simpli
dart pub get
dart test                           # all passed; needs Zig on PATH (it builds searchd)
```

**Before every commit:**

```sh
python3 -I scripts/check_no_home_paths.py
git grep -nP ' +$' -- '*.md' '*.py'   # no output: no trailing whitespace
```

## Task files, builders and verifiers

Work in this repository is done as tasks. A task file, `docs/tasks/<id>.md`, states the
source of the work, numbered **Rulings** (what must be true at the end) and notes for the
builder. The builder works on its own branch `task/<id>`, fills in the task file's
**Report** from real output (commands, counts, measured numbers, every deviation), and
pushes. A **different** agent or person, the verifier, reproduces every claim from its own
runs, writes the **Verdict** and merges to `main` with `--no-ff`; a builder never verifies
its own work. Deviations are ruled on by the orchestrator in the task file before
verification. The full rules, with the lessons that added each one, are in
[docs/process/ROLES.md](docs/process/ROLES.md). The order of work is the
[objective plan](docs/plans/2026-11-16-objective-plan.md) and
[docs/journey/03-next.md](docs/journey/03-next.md).

## The evidence rule

Every document says which of these a statement is: **implemented and verified**,
**observed** (a benchmark or an evaluation, with its setup), a **working hypothesis**, or
a **future option**. Numbers are measured, never estimated, and come with the command,
the build mode, the corpus and the machine. A speed regression test asserts a growth ratio
across sizes, never a single wall-clock threshold. An experiment that changes a decision
is recorded in [EXPERIMENTS.md](EXPERIMENTS.md) and [PROJECT-STATE.md](PROJECT-STATE.md).
See [docs/README.md](docs/README.md#evidence-rule).

## Privacy: invented names only

The repository is public. Fixtures, examples, tests and documents use **invented** names,
folders and text, never a real person, family, device or file. No home-directory paths
(`/Users/<name>/`, `/home/<name>/`) or device identifiers in tracked files: write
`<home>/…` or a relative path. `scripts/check_no_home_paths.py` checks this, and the
Python suite runs it (`tests/test_privacy.py`). Commit messages carry no session links.

## When a change needs a capability document

A change that adds a capability or changes a promise to callers needs its capability
document **before** code: a new or changed field in `contracts/` (and its
`CONTRACTS_VERSION`), a new or changed index format, a new C ABI function, or a new
interface. Follow [docs/capability-process.md](docs/capability-process.md) with the
[template](docs/requirements/capability-template.md), register it in the
[requirements register](docs/requirements/README.md), and keep
`python3 scripts/check_requirements.py` passing. A fix that keeps every contract, format
and ABI as it is needs none.

## The layers

`zig/src/` is divided into core, operations and interfaces, each a folder (`core/`,
`ops/`, `interfaces/`) and the first two Zig modules (`core`, `operations`); imports run
one way only, and another layer is reached through its module, never by a path.
Tests, benchmarks and tools sit beside their subject, or in `zig/src/tests/` when they
cross layers. [docs/layers.md](docs/layers.md) lists every file and says how to add an
interface, a core feature or a test. A new layer file under `zig/src/` (not a test,
benchmark or tool) goes in its layer's folder, is added to `FILES` in
`scripts/check_layers.py` and is named in its folder's module root (`core/core.zig`,
`ops/operations.zig` or `interfaces/interfaces.zig`: a `pub const` and a `_ = name;`
line in the root's test-build `comptime` block); run
`python3 scripts/check_layers.py --write-doc` to regenerate the document's table, then
`python3 scripts/check_layers.py`.

A new test file (`*_test.zig`) is not added to `FILES`; it runs only when a step of
`zig build test` reaches it. Beside its subject, it is named in that folder's module
root, as above; in `zig/src/tests/`, in `tests/root.zig` (a `pub const` and a
`_ = name;` line in its test block). Naming it only through a module,
`@import("core").name`, is not enough: a Zig test build runs the tests of its root
module's files only. `python3 scripts/check_layers.py` fails, naming the file, when a
file that holds a `test` is reached by no step, and `--list-tests` shows which step runs
each file. `python3 scripts/check_test_counts.py --run` runs `zig build test --summary
all` and fails when a step's total differs from that listing, and also when the static
checker reports a problem. The two guards catch different losses, and both must pass.
The checker reads Zig only approximately (`docs/layers.md`, "What it cannot see"); the
comparison sees only totals. CI runs both, the checker in `checks` and the comparison
in both Zig jobs.

If the comparison fails, its table shows, for a step, `Listed` (the tests the checker
finds) and `Ran` (Zig's total, skips included). The difference is the number of tests
in question:
- If Ran is lower, that many tests are named only through code that is never compiled:
  an alias in a struct no test reaches into, a `comptime` switch that is false, or a
  platform or mode guard. Name the file plainly in its root, or remove the dead code.
- If Ran is higher, Zig runs tests the checker does not see (`refAllDecls`); name the
  file in its root.
- If a step is missing, extra or has no total, `zig/build.zig` changed the steps, or a
  step failed to compile (the error is printed above the summary).

`docs/layers.md`, "When the comparison fails", has the details.

## Native libraries and the source digest

The Dart package ships prebuilt libraries in `bindings/dart/search_simpli/native/`
(macOS, Android and iOS, arm64) and `native/SOURCE-SHA256`, a digest of what they were
built from: `zig/build.zig`, every `zig/src/` file except `*_test.zig`,
`zig/include/search_simpli.h`, `contracts/CONTRACTS_VERSION` and `tool/build_native.sh`.
`tests/test_native_freshness.py` fails when the digest no longer matches. So **any change
to one of those files needs the libraries rebuilt**:

```sh
cd bindings/dart/search_simpli
tool/build_native.sh     # needs Zig on PATH, SS_ANDROID_NDK, and macOS with Xcode for iOS
tool/check_native.sh     # architectures, page alignment and the framework's keys
```

If you cannot build all three, say so in the pull request; the maintainer rebuilds them.
In a merge, the libraries and the digest are never taken from one side: they are rebuilt
from the merged source, last. Changes only to tests, documents, scripts or the Python
reference leave the digest as it is.
