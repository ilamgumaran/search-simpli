# Pre-retrieval authorization

Status: implemented across Python indexing/tools, neutral interchange, Zig segment v3, Zig lexical/vector/hybrid search, source listing, chunk reads, raw RPC, and the text-only gateway.

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

- `index_status` reports global document/term/posting counts and may leak corpus size.
- Zig BM25 uses corpus-global document frequency and average length before unauthorized document scores are zeroed. Returned ranks are filtered, but aggregate statistics can create a subtle cross-label information channel.
- Timing, cache activity, index size, logs, backups, crash artifacts, and operator access need separate controls.
- Principal labels are injected from CLI configuration, not an authenticated OIDC/session/token verifier.
- Rule changes still publish a new complete snapshot, but compatible incremental preparation can relabel unchanged chunks without repeating neural embeddings.
- V1/v2 documents are public by interpretation.

Three deployment options follow from the threat model:

1. **Personal/local:** one trusted user, no labels, smallest operational surface.
2. **Shared corpus with coarse groups:** current pre-rank labels, authenticated gateway, scrubbed status/metrics, and careful side-channel review.
3. **Strong tenant isolation:** physically separate tenant indexes/processes/encryption keys, then use labels for defense in depth inside each tenant. This avoids corpus-global ranking statistics and storage metadata becoming cross-tenant channels.

The next hardening experiment should either implement label-aware BM25 statistics or select separate per-tenant indexes as the explicit isolation boundary. The choice depends on tenant count, corpus sharing, update rate, and acceptable leakage—not only query latency.
