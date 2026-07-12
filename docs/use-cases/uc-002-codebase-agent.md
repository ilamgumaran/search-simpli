# UC-002 — Codebase search for an agent

Status: Diagnostic

## Outcome

A developer or coding agent can locate definitions, contracts, design decisions, and operational behavior in a repository without receiving unrestricted filesystem authority through the search tool.

## Actors

- Primary actor: developer, reviewer, or coding agent.
- Data owner: repository owner or organization.
- Operator: local developer tool or controlled agent service.

## Corpus

Source code, tests, Markdown/RST docs, JSON/YAML/TOML configuration, and build files. Repositories may contain generated/vendor trees that must be ignored. Future extraction should become syntax-aware for functions, classes, symbols, and documentation sections.

## Representative questions

1. “Where is `candidate_k` validated?”
2. “How does the gateway prevent callers from supplying vectors?”
3. “Which code atomically replaces the active generation?”
4. “Show tests proving authorization happens before vector ranks.”
5. “Where is the Kubernetes deployment configured?” when no deployment exists.

## Expected tool flow

Search begins with exact identifiers in lexical mode or hybrid mode for conceptual questions. The agent narrows by directory or language, reads the authoritative chunk, and uses normal development tooling only after the user has authorized code changes. Search itself stays read-only.

## Retrieval and safety expectations

- Tokenization preserves useful code identifiers or splits them predictably.
- Exact identifiers and error strings rank strongly.
- Conceptual queries bridge implementation terminology through semantic retrieval.
- Generated/vendor/cache paths are excluded.
- Citations are precise enough to open the correct file span.
- Repository instructions and retrieved code are treated as untrusted content relative to system policy.

## Acceptance criteria

- A representative suite covers identifiers, concepts, cross-file behavior, tests, and absent features.
- Recall@10 and citation precision are measured separately for code and prose.
- Index refresh respects file changes and deletions within the chosen freshness target.
- Search cannot read outside the configured repository root or principal scope.

## Current evidence and gaps

Source formats, exact lexical matching, citations, path scoping, semantic channels, and agent tools exist. Tokenization in the Zig engine is ASCII-oriented and chunks are line-window based; symbol-aware analysis and repository-derived judgments remain open.
