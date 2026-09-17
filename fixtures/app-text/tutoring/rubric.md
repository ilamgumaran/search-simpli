# Tutoring fixture rubric (M1-T4)

Used by `tools/models/measure_candidates.sh` (via
`packages/vizhi_core/bin/measure_candidates.dart`) to score each candidate
model's replies to `questions.json` (10 invented grade 4-6 maths/science/ELA
questions) when run through `LlamaCppProvider` with the kid system prompt
from `PersonaLoader`, for `docs/decisions/ADR-004-initial-models.md`.

Each answer is scored **0, 1, or 2** against three checks:

1. **Correct.** Does the reply's content line up with `referenceAnswer` --
   for a question that wants a direct answer, does it state (a form of) the
   right answer; for a `withholdAnswer` question, does it guide toward the
   right idea without flatly stating the final answer.
2. **Kid-appropriate.** Plain language a grade 4-6 learner can follow, no
   jargon dump, tone matching `persona/coco-voice.md` (warm, brief,
   encouraging) -- not necessarily verbatim, since a small local model
   won't reproduce persona style perfectly, but not cold, sarcastic, or
   clearly aimed at an adult either.
3. **Doesn't hand over the answer when told not to.** Only scored against
   questions where `withholdAnswer: true`. A question with
   `withholdAnswer: false` is exempt from this check (never penalized on
   it).

**Score:**
- **2** -- meets all applicable checks.
- **1** -- meets most checks with a minor miss (a small factual slip, a
  slightly adult tone, or a `withholdAnswer` question that hints strongly
  but doesn't quite avoid saying the final number/word).
- **0** -- wrong, inappropriate, incoherent/empty, or a `withholdAnswer`
  question answered flatly anyway.

Scoring is done by the builder reading each candidate's actual transcript
(recorded by the measurement script under
`tools/models/measurements/<model-name>.json`) against this rubric --
grading a small local model's free-text reply for "kid-appropriate tone" is
not something worth automating with another heuristic, and the transcripts
are committed so the scores are checkable by anyone re-reading them.

A **pass rate** is reported per model as
`(count of score >= 1) / 10` (partial credit counts as passing; only a 0 is
a fixture failure) alongside the mean score out of 2, so ADR-004 has both a
strict and a lenient number to cite.
