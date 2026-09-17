# Vendored source: simpli-helper app text fixtures (S1-T1)

Copied from `~/workspace/simpli-helper/packages/vizhi_core/test/fixtures/`
(text/markdown only) for the golden `line-window-v1` chunker conformance run
against non-fixture, non-Search-Simpli text. All content is invented test
material written for the app's own test suite; nothing here is real family
data, a photo, or OCR output.

Copied:
- `context/corpus.txt` — a short invented reading passage.
- `context/persona/*.md` — short invented persona-voice instruction snippets.
- `learn/*.md` — invented grade 4-6 practice-set samples (see `learn/README.md`
  there for what they mirror).
- `tutoring/rubric.md` — an invented scoring rubric for a model-comparison
  fixture.

Deliberately **not** copied, even though they are `.txt`/`.md`: `family/`,
`memory/` (named for the family/session-memory wall this repo does not touch),
`ocr/*.txt` and `video/*.txt` (OCR/video-transcript derived, excluded by the
task's "no OCR" rule even in text form), and `safety/*.txt` (adversarial
safety-classifier prompts — invented, but not representative "app text" and
not appropriate to redistribute in a public search-fixture corpus).

Re-vendor by re-running the same copy if the app's fixtures change; there is
no automation here, matching how `fixtures/knowledge` etc. are hand-maintained
in this repo.
