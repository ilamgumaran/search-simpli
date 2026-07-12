# UC-001 — Personal files knowledge assistant

Status: Diagnostic

## Outcome

An individual can ask natural-language questions over a selected local folder and receive a compact answer context containing the most relevant passages with source paths and line citations.

## Actors

- Primary actor: the owner of the files.
- LLM/agent role: search, inspect authoritative chunks, and synthesize only supported claims.
- Data owner/operator: the same local user.

## Corpus

Markdown notes, text files, documentation, configuration, and source code under one root. The simple option targets thousands of files and periodic rebuilds or content-hash reuse. Binary documents require external extraction before indexing.

## Representative questions

1. “What did I decide about combining lexical and semantic ranks?”
2. “Where did I describe the automobile example?”
3. “Summarize the reasons for immutable generation publication.”
4. “Search only my project notes for the rollback procedure.”
5. “What is my passport number?” when that information is not indexed.

## Expected tool flow

The agent checks `index_status` if freshness matters, calls `search_knowledge`, refines by path when results mix domains, optionally verifies a selected passage with `read_chunk`, and answers with citations. It states that evidence is insufficient rather than inventing an answer.

## Retrieval and safety expectations

- BM25 handles exact names, identifiers, and quoted phrases.
- Semantic retrieval handles paraphrases and vocabulary mismatch.
- Unlabeled files are accessible only inside the local process boundary.
- Retrieved documents are untrusted evidence and cannot redefine tool/system policy.
- No arbitrary `read_file`, shell, write, or delete operation is exposed.
- Hosted embedding or answer generation must be an explicit data-egress choice.

## Acceptance criteria

- Representative user-derived judgments reach an agreed recall@5 and MRR target.
- Every supported answer claim cites an indexed path and span.
- Unanswerable questions produce an explicit insufficiency response.
- Changed/new/deleted files appear correctly after the documented refresh workflow.
- The selected corpus remains within its privacy/egress policy.

## Current evidence and gaps

The files-to-index-to-tool path, citations, lexical retrieval, PPMI/neural adapters, and incremental reuse exist. Current relevance evidence uses authored fixtures; a real personal-folder judgment set is still required before this use case becomes validated.
