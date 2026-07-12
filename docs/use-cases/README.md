# Search Simpli use-case library

This directory records the situations Search Simpli is intended to serve. A use case is more than a feature request: it defines the actor, corpus, representative questions, authorization boundary, freshness need, success evidence, and risks.

## Catalog

| ID | Use case | Primary actor | Corpus | Current support |
|---|---|---|---|---|
| UC-001 | [Personal files knowledge assistant](uc-001-personal-files.md) | Individual | Notes, Markdown, source/text files | Implemented reference path; real user judgments pending |
| UC-002 | [Codebase search for an agent](uc-002-codebase-agent.md) | Developer or coding agent | Source, docs, configs | Core retrieval/tools implemented; structure-aware chunks pending |
| UC-003 | [Authorized team knowledge](uc-003-authorized-team-knowledge.md) | Team member or internal agent | Shared public/private documents | Static required-label path implemented; authentication pending |

## Adding a use case

1. Copy [TEMPLATE.md](TEMPLATE.md) to `uc-NNN-short-name.md`.
2. Give it a stable ID; do not recycle IDs after removal.
3. Include at least five representative questions, including an unanswerable or negative case.
4. State authorization and data-egress expectations explicitly.
5. Define measurable retrieval and citation acceptance criteria.
6. Link any judgment fixture, benchmark, experiment, or implementation issue.
7. Add it to the catalog above and update its support status as evidence changes.

## Status vocabulary

- **Proposed:** scenario and acceptance criteria exist.
- **Diagnostic:** exercised only with authored/synthetic fixtures.
- **Validated:** evaluated against representative user-derived judgments.
- **Operational:** reliability, security, freshness, and performance targets are also met.
- **Blocked:** a named external decision or capability prevents evaluation.

No use case should be called validated solely because its implementation tests pass. Behavioral correctness, retrieval relevance, citation support, and operational suitability are separate evidence.
