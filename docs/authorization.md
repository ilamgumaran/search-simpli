# Pre-retrieval authorization

Status: implemented across Python indexing/tools, neutral interchange, Zig segment v3, Zig lexical/vector/hybrid search, source listing, chunk reads, raw RPC, and the text-only gateway; since S3-T3 also roots (a root's `required_labels` add to each file's), visible-scope BM25 statistics and the scoped core operations (`zig/src/scope.zig`, `zig/src/service.zig`).

## Security rule

Retrieval scope is not authorization. A path prefix chosen by an LLM is a useful search constraint, but it cannot establish what the caller is allowed to see.

The implemented policy is `all-required-labels-v1`:

- every chunk has zero or more required labels;
- a principal may see a chunk only when it possesses every required label;
- chunks with no labels are public to this index;
- labels filter lexical and vector candidates before component ranks and fusion;
- the same decision applies again to source listing and authoritative `read_chunk`;
- denied and unknown chunk ids return the same not-found result.

Example:

```text
public/guide.md                    requires []
private/general/plan.md            requires [tenant:acme]
private/engineering/design.md      requires [group:engineering, tenant:acme]
```

A tenant principal cannot see the engineering chunk without the second label.

## Assign document requirements

Path rules are a simple local bootstrap:

```json
{
  "version": 1,
  "rules": [
    {"path_prefix":"private/","required_labels":["tenant:acme"]},
    {"path_prefix":"private/engineering/","required_labels":["group:engineering"]}
  ]
}
```

All matching rules contribute labels. Therefore the engineering path requires both labels rather than letting the more-specific rule erase the tenant boundary.

```sh
python3 search.py index ./knowledge \
  --access-rules access-rules.json \
  --out .search/index.json
```

Labels must be non-empty, contain no NUL or line breaks, and are deduplicated and sorted. Unsafe relative prefixes and unknown rule fields are rejected. The rule contract is `contracts/access-rules.schema.json`.

This path mapping is intentionally simple. A full connector should derive labels from authoritative source ACLs, preserve stable subject/group identifiers, and update labels when upstream permissions change.

## Trusted principal boundary

For the Python tool or gateway, principal labels are process configuration:

```sh
python3 knowledge_tools.py .search/index.json \
  --principal-label tenant:acme \
  --principal-label group:engineering

python3 zig_gateway.py .search/index.json /srv/search/snapshot \
  --principal-label tenant:acme \
  --principal-label group:engineering
```

The LLM-facing request cannot supply `principal_labels`. The gateway rejects that field and injects its configured principal into internal Zig requests for search, list, and read. This prevents a model or prompt-injected document from granting itself access.

The raw Zig JSON-RPC process accepts a bounded `principal_labels` array because it is an internal engine interface. It must sit behind an adapter that authenticates the caller and derives labels from trusted identity/session state. Passing CLI labels demonstrates the boundary; it is not itself an authentication system.

## Persisted representation

Interchange v1 carries `required_labels` as a JSON string array. The importer validates at most 64 labels, bounds each label, rejects duplicates, sorts them, and packs them as a canonical newline-separated field.

`HYBSEG01` v3 persists that canonical field in each document record. V1 and v2 segments remain readable and are interpreted as public because they contain no label metadata. Deployments adding authorization must reindex old snapshots before treating them as protected.

The packed representation keeps decode zero-copy and avoids a separate nested-slice allocation. Query checks parse at most the document's bounded labels; RPC principal parsing uses a fixed 64-label stack workspace.

## Live result

The checked-in `fixtures/access-knowledge` and `fixtures/access-rules.json` were indexed with 128-dimensional mechanical test vectors, exported, and imported as Zig generation 4.

Observed through three gateway principals:

| Principal | Listed sources | Confidential query | Engineering query/read |
|---|---|---|---|
| anonymous | public only | no result | not found |
| `tenant:acme` | public + tenant general | tenant plan returned | no result / not found |
| tenant + engineering | all three | tenant plan returned | engineering design returned/read |

An anonymous request containing forged `principal_labels` returned JSON-RPC `-32602` before reaching Zig.

The authorization mechanics test uses hash vectors only to make both channels deterministic without a model download. Hash vectors are not semantic-quality evidence.

## Known limits and scale choices

This implementation prevents document content and identifiers from entering unauthorized result ranks, source lists, and reads. It is not yet a complete multi-tenant security proof:

- **Visible-scope statistics (S3-T3).** Zig BM25 now uses the document count, average length and document frequencies of the documents the request may see (roots named ∩ labels), not the corpus's: a word that occurs only in hidden documents does not change any visible score, and visible scores are bit-identical to an index that never held the hidden documents (`zig/src/apply_test.zig`, "a hidden label domain inside one root is indistinguishable from absent in every payload"). Per (root, label set) groups are precomputed when a generation is opened with `snapshot_open.openScoped`; a root with more than 64 label sets is counted exactly at query time. The RPC server and the C ABI do not build the groups yet (S3-T4 wires their scope), so a labelled query there counts its visible scope exactly, one pass over the documents per query; an index whose records carry no label skips this entirely. A path prefix still narrows candidates only, never statistics. The Python reference has computed BM25 over its filtered chunks all along.
- **Scoped status and listings (S3-T3).** In the core (`service.ScopedService`), `index_status`, `list_sources`, `list_files`, `read_chunk`, `read_span` and `outline` count and answer from the visible scope only: hidden files, terms, postings, pending files and roots are absent from every count, a hidden chunk id reads like an unknown one, and a hidden file's `read_span`/`outline` answers the absent file's `not_found` message. The RPC `index_status` and C ABI `ss_status` still report whole-index counts, since neither takes a principal yet; S3-T4 moves them onto the scoped operations.
- Timing, cache activity, index size, logs, backups, crash artifacts, and operator access need separate controls.
- **Measured (S3-T3, 2026-10-31): hidden versus absent timing is disclosed, not equal.** Index A: the family-folder fixture's `school` and `home` roots plus the 10 `laptop` files placed in root `home` under `laptop/` with `required_labels: ["adults"]` (a second label domain inside one root: 42 files, 998 chunks, 16,912 terms). Index B: the same without those 10 files (32 files, 115 chunks, 700 terms). The same `search_knowledge` (lexical, top 10) by a principal without `adults`, whose payloads are identical on A and B; 5 warm-up then 200 timed queries per index, three repetitions, the median of the three p50s and p95s below, in µs (MacBook Pro, Apple M5 Pro, macOS 26.6.2, Zig 0.16.0):

  | Query | Fast p50 A / B | Fast p95 A / B | Small p50 A / B | Small p95 A / B |
  | --- | --- | --- | --- | --- |
  | `babi` (only in hidden files, 344 times) | 14.8 / 8.3 | 18.6 / 11.3 | 24.7 / 8.8 | 29.6 / 10.8 |
  | `the` (in visible and hidden files) | 16.0 / 14.3 | 20.8 / 19.7 | 28.3 / 24.8 | 35.8 / 28.5 |
  | `newts` (in neither) | 26.9 / 8.2 | 32.7 / 10.2 | 48.7 / 8.8 | 54.9 / 11.9 |
  | `tide table` (visible files only) | 22.1 / 14.8 | 28.3 / 19.4 | 27.1 / 14.3 | 30.8 / 18.3 |

  Two channels show. The query-term lookup scans the whole dictionary (`lexical_build.findExact`, linear), so every query is slower in an index whose vocabulary, hidden terms included, is larger: `newts`, absent from both, costs 18 µs more in ReleaseFast. And a word found only in hidden files still has its postings walked (S2-T4's finding). Neither reveals which files hold a word; together they reveal roughly how large the hidden vocabulary is and how common a hidden word is. S3-T2's sorted dictionary (binary search) should shrink the first; the second needs per-scope posting bounds. Deployments that must not leak these use separate indexes (option 3 below).
- **Measured (S2-T4, second verdict, 2026-10-08):** a query word that exists only in label-hidden chunks is reported exactly like an absent word (same code, message, `term`, `request`, `matched_chunks`), but the engine still walks that word's postings to find none in scope, so wall time grows with how common the word is in hidden files: about 110 µs against 3 µs for a word hidden in 3,000 chunks at 6k chunks, and with `"profile": true` the report's `tokenize_us`/`score_us` show it. A word hidden in one or two chunks is not distinguishable. The channel reveals roughly how common a word is behind the wall, not which files hold it, and it predates S2-T4 (the old scorer walked every hidden posting too). Options when this matters: coarser `profile` for callers with a label scope, or per-label posting bounds.
- Principal labels are injected from CLI configuration, not an authenticated OIDC/session/token verifier.
- Rule changes still publish a new complete snapshot, but compatible incremental preparation can relabel unchanged chunks without repeating neural embeddings.
- V1/v2 documents are public by interpretation.

Three deployment options follow from the threat model:

1. **Personal/local:** one trusted user, no labels, smallest operational surface.
2. **Shared corpus with coarse groups:** current pre-rank labels, authenticated gateway, scrubbed status/metrics, and careful side-channel review.
3. **Strong tenant isolation:** physically separate tenant indexes/processes/encryption keys, then use labels for defense in depth inside each tenant. This avoids corpus-global ranking statistics and storage metadata becoming cross-tenant channels.

Label-aware BM25 statistics are implemented (S3-T3, above); the next hardening experiment is per-scope posting bounds or separate per-tenant indexes as the explicit isolation boundary. The choice depends on tenant count, corpus sharing, update rate, and acceptable leakage—not only query latency.
