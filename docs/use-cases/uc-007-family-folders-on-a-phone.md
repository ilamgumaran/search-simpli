# UC-007 — Family folders on a phone: whole folders, exact words, cited answers

Status: Proposed (2026-10-31) · Motivates: [`CAP-19`](../requirements/cap-19-folder-knowledge.md)

## Outcome

A person picks one or more folders they already keep — an iCloud Drive folder, a
folder on the phone, a folder on a laptop — and from then on the app can answer
questions about everything inside them, accurately and with citations, and can
also do what a plain search box does: find a word, an exact phrase, or the part
of a document that says something. The first file types are text (`.txt`) and
Markdown (`.md`); the same path later carries PDFs, Office files and scanned
pages, which the consumer app already turns into text.

The search engine does the finding and the citing. The language model only
reads what the engine hands it and writes the answer. Anything the engine can
do for the model it can also do for a plain app with no model at all.

## Actors

- **Primary actor:** a family member who owns the folders (the parent who picked
  them, the child who asks).
- **LLM/agent role:** calls the engine's tools (search, find a phrase, read a
  span, show an outline, list files), reads only the passages returned, and
  answers with citations; says so when the folders do not hold the answer.
- **Traditional app role:** a Library screen with a search box: words, exact
  phrases, prefixes; per-file hit counts; snippets with the match highlighted;
  jump to the passage.
- **MCP host role:** a desktop agent (an MCP client) connects to the same index
  over MCP and gets the same tools with the same results.
- **Data owner/operator:** the same family; everything stays on the device unless
  a parent has allowed a cloud model for a given folder.

## Corpus

- Several roots, each a folder the person chose: one on iCloud Drive (files may
  be placeholders not yet downloaded), one local, possibly one on a laptop
  later. Tens to low thousands of files per root; most under 100 KB; some
  Markdown notes over 1 MB.
- Text and Markdown first. Markdown carries structure the person thinks in:
  headings ("Spelling list › Week 7"), lists, code fences, front matter.
- Files appear, change, vanish and get renamed between app openings. Nothing
  tells the engine; the host (the app) reports what it sees when it looks.
- On phones the engine does not get file paths it can open itself (Android's
  document provider hands out content URIs; iOS folders are behind
  security-scoped bookmarks). The host must be able to hand the engine the
  bytes and the metadata of each file instead of a path.

## Representative questions

Exact finding (traditional):
1. "Find *tide table*." — every file and line that contains both words, best
   first, with the words highlighted in a snippet.
2. "Find the exact phrase *count me in*." — only passages with those words in
   that order, adjacent.
3. "Which notes mention anything starting with *photosyn*?" — prefix match.
4. "Show me the outline of `science-notes.md`." — headings with line ranges.
5. "Open lines 40 to 60 of that file." — the exact text, with a line before and
   after for context.

Questions for the model, answered from the folders:
6. "What did the teacher say about the spelling test next week?" — the engine
   finds the section; the model quotes the sentence and cites
   `school/notes.md › Week 7 › Spelling · lines 31–34`.
7. "When is the band concert?" — a date inside a list item; the citation names
   the heading the item sits under.
8. "Is there anything in my folders about newts?" — no hit: the model says the
   folders hold nothing about newts; it does not guess.
9. "Summarise the project-ideas note." — the engine returns the outline and the
   first span of each section; the model summarises per section with
   citations.
10. "What does the recipe say to do after the dough rests?" — the step after a
    phrase match: the engine returns the matching span and its neighbours.

Folder life:
11. A new file lands in the iCloud folder on another device; at the next
    refresh it is searchable. A file not yet downloaded shows as pending, by
    name, until it arrives.
12. A note is renamed; its old citations stop, the new name works, nothing is
    re-chunked.
13. A folder is removed from the app; nothing from it is ever returned again,
    and no statistic leaks that it was there.

## Expected tool flow

- **Traditional:** `find(query, mode: words|phrase|prefix, roots?, page)` →
  per-hit `{path, root, section_path, start_line, end_line, snippet, match_offsets, score}`
  and per-file counts; `outline(path)`; `read_span(path, start_line, end_line, context_lines)`;
  `list_files(root?, prefix?, kind?)`.
- **LLM:** `search_knowledge(question)` (ranked, cited chunks, as today) **and**
  the same `find`, `outline`, `read_span`, `list_files` tools, declared with JSON
  schemas the model can call; an `evidence` call that adds the neighbouring
  spans and the section path of each cited chunk. The model's answer cites
  `[n]` markers that the host resolves to `root/path › section · lines`.
- **MCP:** an MCP server exposes exactly those tools (and, read-only, the files
  as resources) with identical results to the direct API.
- **Host-fed indexing:** `apply_changes([{op: add|change|remove|move|pending, root, path, size, mtime, sha256?, bytes?}])`
  from the app's own folder walk; the engine re-chunks only what changed and
  answers with the same report fields it has today (added, changed, removed,
  unchanged, pending, too_large, unreadable).

## Retrieval and safety expectations

- Exact phrase search is exact: a phrase hit means those words, in that order,
  adjacent (after the analyzer's normalization), inside one chunk.
- Every result carries the root, the path, the line range and, for Markdown,
  the section path; the chunk id stays stable while the content and path stay
  the same.
- Roots are authorization scopes: a query over roots A and B never sees C's
  terms, counts or timings. A removed root's statistics leave the index.
- The engine never calls a model, never fetches from the network, never follows
  symlinks, never reads outside the roots it was given, and on phones never
  opens a path by itself unless the host says it may.
- Deterministic ordering for equal scores; bounded memory on phones (the
  consumer app runs it on devices with about 1 GB of free memory and a 10 MiB
  per-file cap).

## Acceptance criteria

- On a fixture folder of invented text and Markdown files (`fixtures/family-folder/`,
  at least 40 files, three roots, front matter, nested headings, lists, code
  fences, one file over 1 MB, two files with identical content), the ten
  representative questions above have judgments and the engine meets:
  phrase recall 1.00 (every judged phrase hit returned, none missed), words
  recall@5 ≥ 0.9, outline exactness 1.00, `read_span` byte-exact against the
  file, prefix recall 1.00.
- Rename, add, change, remove and pending are each one `apply_changes` call and
  one `index_status` read in a test; the report fields match.
- The MCP conformance test (a minimal client, no third-party packages) gets the
  same JSON for the same ten questions as the direct RPC.
- The three native libraries (macOS, iOS, Android) carry the new ABI and the
  consumer app's device fixture passes on both phones.
- Measured on the fixture and on the 10k-file benchmark: phrase query p50
  ≤ 5 ms at 10k chunks; positional index at most 2.5× today's lexical segment
  size; full index of 10k files ≤ 3 s.

## Current evidence and gaps

Observed today (`PROJECT-STATE.md`, `docs/research/2026-10-luxir-learnings.md`):
BM25 over line-window chunks with line citations, one root per index,
incremental update by content hash, a stdio/loopback JSON-RPC tool server with
four methods. Missing for this use case: positional postings (no phrase,
prefix, proximity, snippets or match offsets); Markdown structure (no headings,
section path or front matter; chunker id not in the manifest, CFT-09); several
roots and per-root authorization in the native path; host-fed documents and a
`pending` state; rename detection; an MCP server (CAP-13 proposed, not built);
tool schemas and a skill document for model apps. See CAP-19.
