# UC-006 — Find a local document by its contents or filename

Status: Proposed · filename retrieval not implemented

## Outcome and actors

The local folder owner or their LLM tool can find an indexed document even when
the remembered words appear only in its filename. Search returns an actual
stored passage and distinguishes locating a file from finding factual support.
The data owner and operator are the same person; team use retains trusted labels.

## Corpus and questions

Version one covers the existing supported UTF-8 text/source extensions, at
least one indexed body chunk per file, and periodic explicit refresh. It includes
English and Tamil. Empty files, hidden/ignored files, PDFs, Office documents,
images and OCR remain outside filename-result coverage in this version.

1. Content: “Where do the notes explain the water filter?”
2. Filename: “annual budget 2026”, where only `Annual_Budget_2026.md` has those words.
3. Combined: “pump maintenance”, where a relevant filename and a different
   document's body both deserve inspection.
4. Unicode: search the stem of a Tamil filename whose body uses different words.
5. Scoped: find “annual budget” only under `projects/`, with trusted principal labels.
6. Negative: “absentquasar987”; no filename or body contains this token.
7. Unsupported: “invoice” when it exists only as `invoice.pdf`; report the
   format boundary, never imply the PDF body was indexed.

## Tool flow and expectations

Check `index_status` for generation and filename-index capability, select the
proposed `content`, `filename` or `both` search field, then inspect `read_chunk`
for returned anchors. Existing default content search stays unchanged. Filename
matches identify documents; the LLM must read their passages before making
claims. Matching a filename is not evidence that its body answers a question.

BM25/token matching is sufficient for this bounded version. Stemming, fuzzy
matching, exact phrases, embeddings and natural-language intent parsing are not
promised. Path prefixes scope results; directory names are not indexed terms.
No automatic background watcher or OS-wide file search is included.

## Authorization, privacy and failure modes

Principal labels come from the trusted host, not query text. Both channels and
their visible statistics respect authorization and path scope before ranking.
The local index and passage contents stay local unless the owner separately
chooses a remote model. Synthetic evidence may be published; personal folders
and query logs are not committed by default. Retrieved text remains untrusted
data. Removed files disappear only after refresh. An old snapshot without the
filename channel must fail explicitly for filename/both queries.

## Acceptance and evaluation assets

The exact diagnostic gates, migration and stage ownership are in
[CAP-16](../requirements/cap-16-directory-filename-search.md) and its
[task split](../tasks/directory-search.md). All filename fixtures must retrieve
the designated file at top 1; every result must have a real stored span and
explicit match origin. Hidden/absent comparisons, default-content parity and
change/rename/delete cases must pass. A 1,000-file synthetic run measures cost;
real-folder relevance and device budgets remain pending owner data. A synthetic
current-behavior diagnostic is recorded separately, not a production benchmark.
