# Search Simpli

Search Simpli is a local search engine written in Zig with no third-party dependencies.
One binary (`searchd`) and one C library index a folder of text, Markdown and source files
and answer keyword queries with cited passages: a path and a line range for every hit.
The same index serves people (`query`, `find`), apps (a C ABI and a Dart binding) and LLM agents
(a JSON evidence envelope, nine tools, an MCP server); search cites, a model may only answer from it.

A dependency-free Python implementation (`search.py`, `src/search_platform/`) is the
behavioural reference the engine is tested against. The project is MIT-licensed; the
[contributor guide](CONTRIBUTING.md) says how to build, test and propose a change.
What the README said before 16 Nov 2026 is kept, unchanged, in
[docs/status-history.md](docs/status-history.md).

## Five-minute start

You need `git` and [Zig 0.16.0](https://ziglang.org/download/) (exactly that version) on
`PATH`. From an empty folder:

```sh
git clone https://github.com/ilamgumaran/search-simpli.git
cd search-simpli
(cd zig && zig build -Doptimize=ReleaseSmall)
./zig/zig-out/bin/searchd index fixtures/knowledge --out .search/demo
./zig/zig-out/bin/searchd query .search/demo "how does hybrid search combine results" --top-k 2
./zig/zig-out/bin/searchd evidence .search/demo "hybrid search" --top-k 1
./zig/zig-out/bin/searchd find .search/demo "hybrid"
echo '{"jsonrpc":"2.0","id":1,"method":"search_knowledge","params":{"query":"hybrid search","top_k":1}}' \
  | ./zig/zig-out/bin/searchd serve .search/demo
```

The build prints that it skips the Android libraries when `SS_ANDROID_NDK` is not set;
that is expected. `query` prints ranked passages for a person, `evidence` the JSON an LLM
tool call receives, `find` an exact word search, and the last line one JSON-RPC request.
`./zig/zig-out/bin/searchd --help` lists every command. With Python 3 and no Zig, the
reference does the same over a JSON index:

```sh
python3 search.py index fixtures/knowledge --out .search/index.json
python3 search.py query .search/index.json "how does hybrid search combine results"
```

On an Apple-silicon Mac the `ReleaseSmall` build took 10.6 s with an empty Zig cache
(S6-T1, 16 Nov 2026). Point `index` at your own folder to search it; `--update` re-reads
only changed files, and `--filename-index` adds search by file name. For a one-off question,
`searchd search <folder> "<query>"` answers over the folder with no index at all
([direct search](docs/direct-search.md)).

## Interfaces

The folder-knowledge operations answer through one operations layer, so a request gives
the same JSON on the command line, JSON-RPC and the C ABI (the Dart package's parity test
compares them). "Run on" names where this repository's suites or recorded tasks ran it.

| Interface | Entry | Run on | Read |
|---|---|---|---|
| Command line | `searchd index`, `query`, `evidence`, `find`, `outline`, `read-span`, `list-files`, `apply` | macOS arm64; Linux x86_64 (CI) | `searchd --help`, [zig/README.md](zig/README.md) |
| Command line, no index | `searchd search <folder> "<query>"`: built in memory, writes nothing, the same answers as `index` then `query` | macOS arm64; Linux x86_64 (CI) | [docs/direct-search.md](docs/direct-search.md) |
| JSON-RPC over stdio | `searchd serve <dir>` | macOS arm64; Linux x86_64 (CI) | [docs/zig-rpc-service.md](docs/zig-rpc-service.md) |
| JSON-RPC over loopback HTTP | `searchd serve <dir> --http 127.0.0.1:<port>` | macOS arm64, by hand ([S1-T1](docs/tasks/S1-T1.md)); no suite starts it | [docs/zig-rpc-service.md](docs/zig-rpc-service.md) |
| MCP | `searchd mcp <dir>` | macOS arm64 (an agent run, [S5-T10](docs/tasks/S5-T10.md)); Linux x86_64 (CI) | [docs/mcp-server.md](docs/mcp-server.md) |
| C ABI | `libsearch_simpli`, [`zig/include/search_simpli.h`](zig/include/search_simpli.h) | macOS arm64; Linux x86_64 (CI); built for Android arm64 and iOS arm64 | [docs/zig-engine-api.md](docs/zig-engine-api.md) |
| Dart | [`bindings/dart/search_simpli`](bindings/dart/search_simpli/README.md) over the C ABI | macOS arm64 (`dart test`); an Android emulator ([S1-T2](docs/tasks/S1-T2.md)); the iOS framework is built and checked, not run on a device by this repository | [the package README](bindings/dart/search_simpli/README.md) |

The tools an LLM calls are described once, in [`contracts/tools/`](contracts/tools/), and
the [folder-knowledge skill](skills/folder-knowledge/SKILL.md) tells an agent how to use them.

## Layers

```text
bindings     Dart (later others)                                        -> the C ABI only
interfaces   abi.zig · cli.zig + main.zig · rpc.zig · mcp.zig          -> operations, core
operations   service.zig · ops.zig · report.zig · filename_response.zig -> core
core         formats, analysis, indexing, ranking: every other file     -> core
```

[docs/layers.md](docs/layers.md) assigns every file of `zig/src/`, names today's exceptions,
and says how to add an interface or a core feature; `scripts/check_layers.py` checks it in CI.

## What is measured, and what is not there yet

Measured, macOS arm64 unless stated (each number is linked to its record):

- **Size.** `searchd` built `ReleaseSmall` is 1,133,704 B ([S6-T8](docs/tasks/S6-T8.md));
  the shipped arm64 libraries are 959,584 B (Android) to 990,040 B (macOS)
  ([`native/`](bindings/dart/search_simpli/native/)).
- **Reading a 10,000-file index.** A whole `searchd query` process takes about 0.02 s;
  a warm query 0.1–0.2 ms ([objective plan](docs/plans/2026-11-16-objective-plan.md#where-the-engine-stands-against-it)).
- **Searching a folder directly.** One `searchd search` answers within 100 ms up to about
  1,000 files and within 1 s up to about 10,000 (149 MiB); past that, or for a second
  question, build an index ([direct search](docs/direct-search.md#when-to-use-it-and-when-to-build-an-index)).
- **Disk.** That index is 2.01 times its corpus (2.17 before the highlight offsets took one byte
  per token, 3.41 before each file's text was stored once, 4.44 before lexical format v3), a
  generated one with a large vocabulary
  ([index size](docs/index-size.md#landed), [S6-T8](docs/tasks/S6-T8.md), [S6-T7](docs/tasks/S6-T7.md),
  [objective plan](docs/plans/2026-11-16-objective-plan.md#disk-use-measured)).
- **Relevance.** J2, a judged fixture of 290 queries over invented files, runs in CI
  through the Python reference and a `ReleaseSmall` `searchd` against a committed baseline
  ([fixtures/j2/](fixtures/j2/README.md)). It is authored, not drawn from real use.

Not there yet, each an item of the [objective plan](docs/plans/2026-11-16-objective-plan.md)
(searching a folder directly, item C, is there: [direct search](docs/direct-search.md)):
a smaller index ([D](docs/plans/2026-11-16-objective-plan.md#d-a-smaller-index-objective-2));
semantic matches for an index `searchd` built, which is lexical only today
([E](docs/plans/2026-11-16-objective-plan.md#e-semantic-matches-for-a-searchd-built-index-objective-1));
and the web: no WebAssembly build or JavaScript binding
([F](docs/plans/2026-11-16-objective-plan.md#f-web-objective-4)).

## Where to start reading

| If you want to | Read |
|---|---|
| build, run the suites, propose a change | [CONTRIBUTING.md](CONTRIBUTING.md) |
| know the order of work | [the objective plan](docs/plans/2026-11-16-objective-plan.md), then [docs/journey/03-next.md](docs/journey/03-next.md) |
| see how the code is divided | [docs/layers.md](docs/layers.md), [zig/README.md](zig/README.md) |
| find any document | [docs/README.md](docs/README.md) |
| understand why the project exists | [the journey](docs/journey/README.md), [the vision](docs/journey/01-vision.md) |
| know the exact current state | [PROJECT-STATE.md](PROJECT-STATE.md) |
| read what the README used to say | [docs/status-history.md](docs/status-history.md) |
