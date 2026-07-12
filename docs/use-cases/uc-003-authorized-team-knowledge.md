# UC-003 — Authorized team knowledge

Status: Diagnostic

## Outcome

Team members or internal agents search one shared corpus while receiving only passages permitted by their trusted identity and document labels.

## Actors

- Primary actor: authenticated employee, contractor, or internal agent.
- Data owner: organization or tenant administrator.
- Operator: controlled knowledge service.

## Corpus

Public guides, tenant documents, engineering designs, operating procedures, and other text extracted into a shared collection. Documents carry required labels derived from path rules or an upstream authorization source.

## Representative questions

1. Anonymous: “Show the public onboarding guide.”
2. Tenant member: “What is Acme’s private project plan?”
3. Engineer: “How is the confidential search service designed?”
4. Tenant member: “List engineering-only sources.”
5. Anonymous: request a known private chunk id directly.

## Expected tool flow

The application derives principal labels from authentication, injects them below the LLM boundary, and uses the same principal for search, listing, and authoritative reads. The model cannot widen the principal or infer whether a denied id exists.

## Authorization and privacy expectations

- All matching document rules union their required labels.
- A principal must possess every required label.
- Forbidden documents receive no lexical rank, vector rank, or fused score.
- `list_sources` and `read_chunk` reapply the same policy.
- Denied and unknown chunk ids return the same response.
- Logs, embeddings, backups, caches, and model egress follow the same classification policy.
- Tenant isolation or label-aware BM25 statistics must address aggregate/timing leakage before production multi-tenancy.

## Acceptance criteria

- Cross-channel tests prove unauthorized content cannot influence returned ranks or passages.
- Direct-id, source-listing, path-prefix, and principal-forgery tests fail closed.
- Principals come from verified identity rather than CLI flags in an operational deployment.
- Tenant leakage, audit, storage encryption, backup, and log policies are explicitly reviewed.
- Relevance is evaluated within each permitted corpus view.

## Current evidence and gaps

Canonical required labels persist through Python, interchange, and Zig segments; search/list/read isolation and gateway forgery rejection are tested with diagnostic fixtures. Authentication, tenant-specific statistics or separate indexes, audit logs, encryption, and operational policy remain unimplemented.
