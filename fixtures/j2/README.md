# J2: the judged fixture (S5-T1)

Invented content only: the Varnell family of Thistlecombe (Maren, Joss, Pip in
Year 5, Wren in Year 2, Paati their grandmother, Biscuit the dog), Thistlecombe
Primary, Mill Lane, Hollow Woods. No real person, place or product. Phone numbers
are from the ranges set aside for drama.

J2 says where keyword search loses. It holds 265 queries in seven slices,
a held-out title slice (S5-T2), a held-out misspelling slice (S5-T3), held-out
morphology, accent and Tamil slices (S5-T4), a held-out verb-form slice (S5-T5),
a cross-word verb-form slice and a precision-control slice (S5-T8) and named
negatives in three sets (S5-T8 adds a tuning set and a held-out set), graded 0 to
2, over three roots. Its numbers are the baseline later
search tasks are judged against (`fixtures/j2/baseline.json`,
`scripts/j2_gate.py`); see `docs/evaluation.md`, section J2.

Do not edit the files by hand. `python3 fixtures/j2/generate.py` rewrites every
file, `judgments.json` and this README from `content.py`, `queries.py` and
`generate.py`; `tests/test_j2_fixture.py` regenerates into a temporary folder and
compares byte for byte. Every line range is computed from the files. Before it
writes, the generator asserts each query's `checks`: they are what keeps each
miss real. A change to a judgment is a reviewed commit named in its task's Report.

Run it: `python3 scripts/relevance_smoke.py --pack j2` (the Python reference) and
`python3 scripts/j2_run.py --searchd PATH` (the shipped engine), then
`python3 scripts/j2_gate.py RUN.json`.

## Roots and special files

| Root | Files |
| --- | --- |
| `school/` | 30 |
| `home/` | 32 |
| `laptop/` | 26 |

| File | Why |
| --- | --- |
| `home/garden-diary.md` | the long file: a year of daily lines, one section per month |
| `laptop/log/homework-tracker.txt` | a long plain-text log, windowed by line-window-v1; one window holds "dentist appointment" twice |
| `school/trip-permission-museum.md` | CRLF line endings |
| `home/shopping-list.md` | CRLF line endings, no headings |
| `school/class-rules.md` | UTF-8 byte order mark |
| `school/pe-kit.txt` | one line, no final newline |
| `school/empty-notes.txt` | zero bytes |
| `school/newsletter-autumn.md` | decomposed (NFD) Noël |
| `school/letters/letter-home-oct.txt` | ligature ﬁ, as pasted from a PDF |
| `school/notes-from-phone.txt` | full-width digits |
| `school/spelling-lists.md` | Setext headings |
| `school/tamil/tamil-class.md` | Tamil (school root) |
| `home/tamil/பாட்டி-கடிதங்கள்.md` | Tamil, with a Tamil file name (home root) |
| `laptop/tamil/tamil-stories.md` | Tamil (laptop root) |

## Slices

| Slice | Queries | Minimum | What it holds |
| --- | ---: | ---: | --- |
| control | 23 | 20 | what today's engine answers; must stay at rank 1 |
| misspelling | 16 | 15 | one or two letters off; transpositions marked |
| morphology | 13 | 12 | plural, tense and possessive forms |
| accent | 9 | 6 | accents, ß, ligatures, full-width forms, both directions |
| tamil | 13 | 10 | Tamil inflections, both directions, plus suffix guards |
| title | 11 | 10 | the words name the file (stem or folder), not its body |
| phrase | 10 | 8 | the words adjacent in the answer, apart in a distractor |
| negatives | 26 | - | nothing answers; distractors named |
| title-heldout | 8 | 6 | title intent held out from S5-T2's weight; no word of the title slice |
| misspelling-heldout | 12 | 10 | misspellings held out from S5-T3's rule; no typed or meant word of the misspelling slice |
| morphology-heldout | 14 | 12 | plural forms held out from S5-T4's key function, keep-list guards, -ing/-ed, a name-only form |
| accent-heldout | 11 | 10 | accent, width and compatibility forms held out from S5-T4; short words, a merge guard |
| tamil-heldout | 13 | 10 | Tamil inflections held out from S5-T4's suffix list, each rule once, three guards |
| verbform-heldout | 19 | 14 | -ing/-ed/base forms held out from S5-T5's rule; doubled, dropped e, -ied; look-alike guards; held typed words |
| verbform-cross | 6 | 6 | a word whose verb forms (R) reach another word's form; the answer holds its own form (hop and hope, even and evening, tap and tape); judged both sides |
| precision-control | 10 | 8 | what a precision rule must keep at rank 1: stop words in a file name, near spellings, verb forms |
| negatives-tuning | 17 | 15 | S5-T8's negatives for tuning: a stop word in a file name, a near word, a near topic, a cross-word form, Tamil, accent, one word of two held |
| negatives-heldout | 17 | 15 | the same kinds, held out from S5-T8's candidates until each is declared |
| misspelling-short | 13 | 12 | S5-T8 Phase 1c, held out: typed words of 6 or 7 code points two Levenshtein edits off (a swapped pair, a dropped and an added letter, two wrong letters) |
| negatives-short | 4 | 3 | correctly spelt 6 or 7 code point words no file holds, with a near word |

## What counts as misleading (S5-T8)

Written before any S5-T8 run; `scripts/j2_negatives.py` computes it from a J2
results file. It reads negatives only: the queries of `negatives`,
`negatives-tuning` and `negatives-heldout`, which no file answers.

Each of a negative's first five hits is labelled by what brought it. A hit's words
are the body words of its cited range and the title words of its file (the folders
below the root, then the stem). For each query word, the hit's words it matches
through the query's groups (the Python reference's `core._query_groups` for that
query, so a rule under test is reflected) are labelled:

- **real**: the query word itself, or a word with its fold-groups-v1 key
  (`analyzer_v3.key`), or a verb form of it (`verb_forms.forms`) judged `same` in
  `judgments.json` → `verb_form_judgments`;
- **cross**: a verb form of it judged `cross` there (a form of another word: hop
  and hope, even and evening);
- **near**: a word fuzzy-v1 gave it (a spelling neighbour);
- **stop**: the query word is a stop word (the list below), whatever it matches.

A hit takes the first label of real, cross, near, stop that any of its matches
has; a hit with no match is labelled `other` (reported; none is expected). A hit
labelled stop, near or cross is **misleading**: it is there by a stop word alone,
a spelling neighbour or another word's form. A real-word hit holds a word of the
question, so it is counted apart, not as misleading.

The measure, per set, surface and variant (content, both):

- the mean top-5 hit count: the mean over the set's queries of the hits returned,
  at most five;
- the share of queries whose first hit is misleading;
- the mean misleading hits and, apart, the mean real-word hits in the first five.

No score threshold is defined: a hit counts whatever its score.

The stop words are Lucene's 33 English stop words and `my` (S5-T8 ruling 1 names
it among the common words in file names): `a`, `an`, `and`, `are`, `as`, `at`, `be`, `but`, `by`, `for`, `if`, `in`, `into`, `is`, `it`, `no`, `not`, `of`, `on`, `or`, `such`, `that`, `the`, `their`, `then`, `there`, `these`, `they`, `this`, `to`, `was`, `will`, `with`, `my`.

## Queries

Grade-2 rows only; `judgments.json` holds every row with its note.

| Id | Slice | Mode | Query | Answer (grade 2) |
| --- | --- | --- | --- | --- |
| c01 | control | knowledge | `volcano project due date` | `school/volcano-project.md` 11-15 |
| c02 | control | knowledge | `swimming kit tuesday` | `school/class-notes-wren.md` 5-8 |
| c03 | control | knowledge | `school play start time` | `school/school-play.md` 5-9 |
| c04 | control | find:words | `relay team` | `school/sports-day.md` 5-8 |
| c05 | control | knowledge | `library book due back` | `school/class-notes-pip.md` 20-23 |
| c06 | control | knowledge | `screen time school nights` | `home/house-rules.md` 3-6 |
| c07 | control | knowledge | `fish chips friday` | `school/lunch-menu.md` 21-23 |
| c08 | control | knowledge | `dentist appointment` | `laptop/notes/dentist.md` 3-5 |
| c09 | control | knowledge | `wifi password` | `home/fridge-notes.md` 3-6 |
| c10 | control | knowledge | `half term dates` | `school/term-dates.md` 5-8 |
| c11 | control | knowledge | `recorder practice minutes` | `home/music/recorder-practice.md` 3-6 |
| c12 | control | knowledge | `wednesday pickup` | `laptop/school-run-rota.md` 11-13 |
| c13 | control | knowledge | `biscuit dog food` | `home/pets/biscuit-the-dog.md` 8-10 |
| c14 | control | knowledge | `spelling words week 9` | `school/spelling-lists.md` 12-16 |
| c15 | control | knowledge | `பூனை கதை` | `laptop/tamil/tamil-stories.md` 5-7 |
| c16 | control | knowledge | `café opening hours` | `home/weekend-plans.md` 3-7 |
| c17 | control | find:phrase | `bring a packed lunch` | `school/trip-permission-museum.md` 9-11 |
| c18 | control | find:prefix | `fossil*` | `school/dinosaur-topic.md` 17-21 |
| c19 | control | knowledge | `paati phone number` | `home/phone-numbers.txt` 1-7 |
| c20 | control | knowledge | `shopping list eggs flour` | `home/shopping-list.md` 3-8 |
| c21 | control | knowledge | `class rules hands up` | `school/class-rules.md` 5-8 |
| c22 | control | knowledge | `tomato seedlings potted` | `home/garden-diary.md` 84-84 |
| c23 | control | find:words | `pe kit thursday` | `school/pe-kit.txt` 1-1 |
| m01 | misspelling | knowledge | `dinosoar bones` | `school/dinosaur-topic.md` 6-10 |
| m02 | misspelling | knowledge | `multiplicaton tables` | `school/maths-practice.md` 5-8 |
| m03 | misspelling | knowledge | `volcanoe project` | `school/volcano-project.md` 5-9 |
| m04 | misspelling | knowledge | `fractoins homework` | `school/maths-homework.md` 3-7 |
| m05 | misspelling | knowledge | `freind birthday party` | `home/birthday-party-wren.md` 5-11 |
| m06 | misspelling | find:words | `wendesday pickup` | `laptop/school-run-rota.md` 11-13 |
| m07 | misspelling | knowledge | `libary books` | `school/class-notes-pip.md` 20-23 |
| m08 | misspelling | knowledge | `bean hieght` | `school/science-homework.md` 16-21 |
| m09 | misspelling | knowledge | `wierd noise car` | `laptop/notes/car-garage.md` 3-6 |
| m10 | misspelling | knowledge | `recyling bins` | `home/fridge-notes.md` 8-10 |
| m11 | misspelling | knowledge | `dinosuar` | `school/dinosaur-topic.md` 1-4 |
| m12 | misspelling | knowledge | `febuary` | `school/term-dates.md` 10-12 |
| m13 | misspelling | knowledge | `play rehersal times` | `school/school-play.md` 11-15 |
| m14 | misspelling | knowledge | `swimming goggels` | `school/class-notes-wren.md` 5-8 |
| m15 | misspelling | knowledge | `sciense fair` | `school/science-fair.md` 3-14 |
| m16 | misspelling | knowledge | `pancaeks recipe` | `home/recipes/pancakes.md` 12-17 |
| o01 | morphology | knowledge | `dinosaurs teeth` | `school/dinosaur-topic.md` 12-15 |
| o02 | morphology | knowledge | `pony ride` | `laptop/plans/half-term-plans.md` 3-6 |
| o03 | morphology | knowledge | `teachers names` | `school/contacts.txt` 1-9 |
| o04 | morphology | knowledge | `biscuit's lead` | `home/pets/biscuit-the-dog.md` 21-23 |
| o05 | morphology | knowledge | `planting tulips` | `home/garden-diary.md` 313-313 |
| o06 | morphology | knowledge | `football practice cancelled` | `laptop/club-timetable.md` 13-16 |
| o07 | morphology | knowledge | `feeds biscuit` | `home/chores.md` 7-10 |
| o08 | morphology | knowledge | `spelling tests` | `school/class-notes-pip.md` 25-28 |
| o09 | morphology | knowledge | `strawberries` | `home/garden-diary.md` 187-187 |
| o10 | morphology | knowledge | `craft boxes` | `home/chores.md` 20-23 |
| o11 | morphology | knowledge | `skip rope` | `home/chores.md` 20-23 |
| o12 | morphology | knowledge | `painted pots` | `school/art/year5-pottery.md` 8-11 |
| o13 | morphology | knowledge | `paati's recipes` | `home/recipes/rasam.md` 1-3 |
| a01 | accent | knowledge | `cafe menu` | `home/weekend-plans.md` 3-7 |
| a02 | accent | knowledge | `naïve character book` | `school/reading-log-pip.md` 13-17 |
| a03 | accent | knowledge | `fruhling` | `school/german-club.md` 5-7 |
| a04 | accent | knowledge | `room 12` | `school/notes-from-phone.txt` 1-5 |
| a05 | accent | knowledge | `ｇｏｇｇｌｅｓ` | `school/class-notes-wren.md` 5-8 |
| a06 | accent | knowledge | `field trip date` | `school/letters/letter-home-oct.txt` 1-16 |
| a07 | accent | knowledge | `ﬂute` | `home/music/recorder-practice.md` 8-10 |
| a08 | accent | knowledge | `noël concert` | `school/newsletter-autumn.md` 29-33 |
| a09 | accent | knowledge | `strasse` | `school/german-club.md` 9-11 |
| t01 | tamil | knowledge | `புத்தகங்கள்` | `school/tamil/tamil-class.md` 9-11 |
| t02 | tamil | knowledge | `யானை` | `laptop/tamil/tamil-stories.md` 9-11 |
| t03 | tamil | knowledge | `கடைக்கு` | `home/tamil/பாட்டி-கடிதங்கள்.md` 5-7 |
| t04 | tamil | knowledge | `மரம் கதை` | `laptop/tamil/tamil-stories.md` 13-15 |
| t05 | tamil | knowledge | `நூலகத்தில்` | `home/tamil/பாட்டி-கடிதங்கள்.md` 13-15 |
| t06 | tamil | knowledge | `பாட்டி வீடு` | `school/tamil/tamil-class.md` 25-27 |
| t07 | tamil | knowledge | `பழங்கள்` | `home/tamil/பாட்டி-கடிதங்கள்.md` 17-19 |
| t08 | tamil | knowledge | `தேர்வுக்கு` | `school/tamil/tamil-class.md` 13-15 |
| t09 | tamil | knowledge | `பாடல்` | `school/tamil/tamil-class.md` 21-23 |
| t10 | tamil | knowledge | `பள்ளிக்கு` | `school/tamil/tamil-class.md` 5-7 |
| g1 | tamil | knowledge | `காலை` | `school/tamil/tamil-class.md` 5-7 |
| g2 | tamil | knowledge | `நாளை` | `home/tamil/பாட்டி-கடிதங்கள்.md` 33-35 |
| g3 | tamil | knowledge | `தேர்வு` | `school/tamil/tamil-class.md` 13-15 |
| ti01 | title | knowledge | `science homework` | `school/science-homework.md` 1-34 |
| ti02 | title | knowledge | `maths homework` | `school/maths-homework.md` 1-20 |
| ti03 | title | knowledge | `pocket money` | `home/money/pocket-money.md` 1-16 |
| ti04 | title | knowledge | `birthday party` | `home/birthday-party-wren.md` 1-23 |
| ti05 | title | knowledge | `camping list` | `laptop/packing-lists/camping.md` 1-15 |
| ti06 | title | knowledge | `swimming lessons` | `school/swimming-lessons/autumn-term.md` 1-7 |
| ti07 | title | knowledge | `art club` | `school/art-club/autumn-projects.md` 1-16 |
| ti08 | title | knowledge | `reading list` | `laptop/reading-list.md` 1-14 |
| ti09 | title | knowledge | `school uniform` | `laptop/notes/uniform.md` 1-5 |
| ti10 | title | knowledge | `பாட்டி கடிதங்கள்` | `home/tamil/பாட்டி-கடிதங்கள்.md` 1-35 |
| ti11 | title | knowledge | `football` | `laptop/clubs/football/match-days.md` 1-5 |
| p01 | phrase | knowledge | `hot chocolate` | `home/recipes/winter-drinks.md` 3-6 |
| p02 | phrase | knowledge | `solar system model` | `laptop/projects/pip-planet-model.md` 3-6 |
| p03 | phrase | knowledge | `times tables test` | `school/maths-practice.md` 10-13 |
| p04 | phrase | knowledge | `ice cream` | `home/birthday-party-wren.md` 13-17 |
| p05 | phrase | knowledge | `car boot sale` | `home/weekend/sale-in-the-field.md` 1-5 |
| p06 | phrase | knowledge | `fish fingers` | `school/lunch-menu.md` 13-15 |
| p07 | phrase | knowledge | `hot dog` | `home/pets/biscuit-the-dog.md` 16-19 |
| p08 | phrase | find:words | `hot chocolate` | `home/recipes/winter-drinks.md` 3-6 |
| p09 | phrase | find:phrase | `hot chocolate` | `home/recipes/winter-drinks.md` 3-6 |
| p10 | phrase | knowledge | `after school club` | `laptop/club-timetable.md` 22-24 |
| cn1 | negatives | knowledge | `piano lessons` | none |
| cn2 | negatives | knowledge | `volcano trip` | none |
| mn1 | negatives | knowledge | `dinosuar museum` | none |
| mn2 | negatives | knowledge | `skateing lessons` | none |
| on1 | negatives | knowledge | `dinosaur eggs hatching` | none |
| on2 | negatives | knowledge | `painting the fence` | none |
| an1 | negatives | knowledge | `crêpe recipe` | none |
| an2 | negatives | knowledge | `résumé letter` | none |
| tn1 | negatives | knowledge | `ரயில் பயணம்` | none |
| tn2 | negatives | knowledge | `கடற்கரை அலைகள்` | none |
| tin1 | negatives | knowledge | `music homework` | none |
| tin2 | negatives | knowledge | `garden plans` | none |
| pn1 | negatives | knowledge | `ice skating` | none |
| pn2 | negatives | knowledge | `cream tea` | none |
| th01 | title-heldout | knowledge | `garden diary` | `home/garden-diary.md` 1-397 |
| th02 | title-heldout | knowledge | `house rules` | `home/house-rules.md` 1-14 |
| th03 | title-heldout | knowledge | `kids questions` | `laptop/kids-questions.md` 1-15 |
| th04 | title-heldout | knowledge | `november calendar` | `home/calendar-november.md` 1-7 |
| th05 | title-heldout | knowledge | `holiday` | `home/holiday/seaside-packing.md` 1-9 |
| th06 | title-heldout | knowledge | `ideas` | `laptop/ideas/kitchen-science.md` 1-4 |
| th07 | title-heldout | knowledge | `music` | `home/music/recorder-practice.md` 1-15 |
| th08 | title-heldout | knowledge | `health` | `home/health/doctor-visits.md` 1-9 |
| thn1 | negatives | knowledge | `holiday photos` | none |
| thn2 | negatives | knowledge | `music exam` | none |
| mh01 | misspelling-heldout | knowledge | `hot choclate` | `home/recipes/winter-drinks.md` 3-6 |
| mh02 | misspelling-heldout | knowledge | `football tournamnet` | `home/calendar-november.md` 6-6 |
| mh03 | misspelling-heldout | knowledge | `dentist thrusday` | `laptop/notes/dentist.md` 3-5 |
| mh04 | misspelling-heldout | knowledge | `my wislist` | `laptop/wishlist.md` 1-8 |
| mh05 | misspelling-heldout | knowledge | `wifi pasword` | `home/fridge-notes.md` 3-6 |
| mh06 | misspelling-heldout | knowledge | `sandwitches and cake` | `home/birthday-party-wren.md` 13-17 |
| mh07 | misspelling-heldout | knowledge | `saving for a mikroscope` | `home/money/pocket-money.md` 13-16 |
| mh08 | misspelling-heldout | knowledge | `neccesary spelling` | `school/spelling-lists.md` 6-10 |
| mh09 | misspelling-heldout | knowledge | `saturday brekfest` | `home/recipes/pancakes.md` 3-3 |
| mh10 | misspelling-heldout | knowledge | `lost caot` | `laptop/emails-to-school.md` 13-16 |
| mh11 | misspelling-heldout | knowledge | `paper lantren` | `school/art-club/autumn-projects.md` 14-16 |
| mh12 | misspelling-heldout | knowledge | `send the invitiations` | `home/birthday-party-wren.md` 5-11 |
| mhn1 | negatives | knowledge | `tournamnet tickets` | none |
| mhn2 | negatives | knowledge | `lantren sale` | none |
| oh01 | morphology-heldout | knowledge | `puppy` | `laptop/notes/jottings.md` 1-7 |
| oh02 | morphology-heldout | knowledge | `pastries` | `home/household.md` 1-7 |
| oh03 | morphology-heldout | knowledge | `watch` | `laptop/notes/jottings.md` 9-15 |
| oh04 | morphology-heldout | knowledge | `peaches` | `laptop/notes/jottings.md` 1-7 |
| oh05 | morphology-heldout | knowledge | `domino` | `laptop/notes/jottings.md` 17-23 |
| oh06 | morphology-heldout | knowledge | `comic heroes` | `laptop/notes/jottings.md` 25-31 |
| oh07 | morphology-heldout | knowledge | `gloves` | `home/household.md` 9-15 |
| oh08 | morphology-heldout | knowledge | `glasses` | `laptop/notes/jottings.md` 33-38 |
| oh09 | morphology-heldout | knowledge | `news` | `home/household.md` 17-22 |
| oh10 | morphology-heldout | knowledge | `means` | `school/noticeboard.md` 23-28 |
| oh11 | morphology-heldout | knowledge | `knitting` | `home/household.md` 9-15 |
| oh12 | morphology-heldout | knowledge | `cycled` | `laptop/notes/jottings.md` 40-45 |
| oh13 | morphology-heldout | knowledge | `danced maypole` | `school/noticeboard.md` 1-7 |
| oh14 | morphology-heldout | knowledge | `seal` | `home/days-out/seals.md` 1-6 |
| ohn1 | negatives | knowledge | `fox cubs` | none |
| ohn2 | negatives | knowledge | `hero costume` | none |
| ah01 | accent-heldout | knowledge | `fete` | `school/noticeboard.md` 9-14 |
| ah02 | accent-heldout | knowledge | `zoë` | `school/noticeboard.md` 1-7 |
| ah03 | accent-heldout | knowledge | `role` | `school/noticeboard.md` 9-14 |
| ah04 | accent-heldout | knowledge | `déjà` | `school/noticeboard.md` 16-21 |
| ah05 | accent-heldout | knowledge | `creme brulee` | `school/noticeboard.md` 16-21 |
| ah06 | accent-heldout | knowledge | `chapter iv` | `laptop/notes/bedtime-stories.md` 21-25 |
| ah07 | accent-heldout | knowledge | `coffee morning` | `school/noticeboard.md` 37-44 |
| ah08 | accent-heldout | knowledge | `2nd` | `school/noticeboard.md` 46-51 |
| ah09 | accent-heldout | knowledge | `fußball` | `school/noticeboard.md` 23-28 |
| ah10 | accent-heldout | knowledge | `smorrebrod` | `home/household.md` 30-35 |
| ah11 | accent-heldout | knowledge | `méla` | `laptop/notes/bedtime-stories.md` 1-5 |
| ahn1 | negatives | knowledge | `pâté recipe` | none |
| ahn2 | negatives | knowledge | `chapter v` | none |
| tah01 | tamil-heldout | knowledge | `படங்கள்` | `home/tamil/tamil-jottings.md` 20-25 |
| tah02 | tamil-heldout | knowledge | `பறவை` | `home/tamil/tamil-jottings.md` 1-6 |
| tah03 | tamil-heldout | knowledge | `நண்பர்கள்` | `home/tamil/tamil-jottings.md` 20-25 |
| tah04 | tamil-heldout | knowledge | `கிராமத்தில்` | `home/tamil/tamil-jottings.md` 1-6 |
| tah05 | tamil-heldout | knowledge | `நகரம்` | `home/tamil/tamil-jottings.md` 1-6 |
| tah06 | tamil-heldout | knowledge | `தங்கைக்கு` | `home/tamil/tamil-jottings.md` 20-25 |
| tah07 | tamil-heldout | knowledge | `பெட்டியில்` | `home/tamil/tamil-jottings.md` 37-41 |
| tah08 | tamil-heldout | knowledge | `குருவி` | `home/tamil/tamil-jottings.md` 37-41 |
| tah09 | tamil-heldout | knowledge | `குளம்` | `home/tamil/tamil-jottings.md` 1-6 |
| tah10 | tamil-heldout | knowledge | `தம்பிக்கு` | `home/tamil/tamil-jottings.md` 20-25 |
| tag1 | tamil-heldout | knowledge | `வேலை` | `home/tamil/tamil-jottings.md` 8-12 |
| tag2 | tamil-heldout | knowledge | `முடிவு` | `home/tamil/tamil-jottings.md` 27-30 |
| tag3 | tamil-heldout | knowledge | `நாங்கள்` | `home/tamil/tamil-jottings.md` 37-41 |
| tahn1 | negatives | knowledge | `படம் கண்காட்சி` | none |
| tahn2 | negatives | knowledge | `வேலை நேரம்` | none |
| vh01 | verbform-heldout | knowledge | `sack hopping` | `school/year2-blog.md` 1-5 |
| vh02 | verbform-heldout | knowledge | `wobbled` | `laptop/notes/weekend-jobs.md` 1-5 |
| vh03 | verbform-heldout | knowledge | `tidied` | `laptop/notes/weekend-jobs.md` 7-10 |
| vh04 | verbform-heldout | knowledge | `stir porridge` | `laptop/notes/weekend-jobs.md` 12-15 |
| vh05 | verbform-heldout | knowledge | `scrubbed` | `laptop/notes/weekend-jobs.md` 22-25 |
| vh06 | verbform-heldout | knowledge | `juggling` | `laptop/notes/weekend-jobs.md` 27-30 |
| vh07 | verbform-heldout | knowledge | `buried` | `school/year2-blog.md` 24-27 |
| vh08 | verbform-heldout | knowledge | `drip` | `home/family-log.md` 1-5 |
| vh09 | verbform-heldout | knowledge | `knead dough` | `laptop/notes/weekend-jobs.md` 32-35 |
| vh10 | verbform-heldout | knowledge | `sketching` | `school/year2-blog.md` 19-22 |
| vh11 | verbform-heldout | knowledge | `drummed` | `school/year2-blog.md` 13-17 |
| vh12 | verbform-heldout | knowledge | `diving` | `laptop/notes/weekend-jobs.md` 42-45 |
| vg1 | verbform-heldout | knowledge | `herring` | `home/family-log.md` 7-11 |
| vg2 | verbform-heldout | knowledge | `outing` | `home/family-log.md` 19-23 |
| vg3 | verbform-heldout | knowledge | `pasted` | `home/family-log.md` 31-35 |
| vg4 | verbform-heldout | knowledge | `wedding` | `home/family-log.md` 42-46 |
| vg5 | verbform-heldout | knowledge | `petting` | `home/family-log.md` 54-57 |
| vt1 | verbform-heldout | knowledge | `sledging hill` | `home/family-log.md` 64-67 |
| vt2 | verbform-heldout | knowledge | `paddling canoe` | `laptop/notes/weekend-jobs.md` 47-50 |
| vhn1 | negatives | knowledge | `diving board` | none |
| vhn2 | negatives | knowledge | `tidying rota` | none |
| x01 | verbform-cross | knowledge | `hops` | `home/clover.md` 1-5 |
| x02 | verbform-cross | knowledge | `hoping` | `laptop/snow.md` 1-4 |
| x03 | verbform-cross | knowledge | `evenings` | `laptop/chess.md` 1-5 |
| x04 | verbform-cross | knowledge | `even` | `school/counters.md` 1-5 |
| x05 | verbform-cross | knowledge | `tapping` | `home/plumbing.md` 1-4 |
| x06 | verbform-cross | knowledge | `taping` | `home/parcels.md` 1-4 |
| pc01 | precision-control | knowledge | `this and that` | `home/this-and-that.md` 1-4 |
| pc02 | precision-control | knowledge | `end of the pier` | `home/end-of-the-pier.md` 1-4 |
| pc03 | precision-control | knowledge | `owl and the moon` | `home/owl-and-the-moon.md` 1-5 |
| pc04 | precision-control | knowledge | `my flowers` | `home/my-flowers.md` 1-4 |
| pc05 | precision-control | knowledge | `stationary` | `laptop/errands.md` 1-4 |
| pc06 | precision-control | knowledge | `trampolene` | `laptop/errands.md` 6-9 |
| pc07 | precision-control | knowledge | `sissors` | `laptop/errands.md` 11-14 |
| pc08 | precision-control | knowledge | `oiling` | `laptop/errands.md` 16-19 |
| pc09 | precision-control | knowledge | `chopped` | `laptop/errands.md` 21-24 |
| pc10 | precision-control | knowledge | `sprinkling` | `laptop/errands.md` 26-29 |
| nt01 | negatives-tuning | knowledge | `the dragon` | none |
| nt02 | negatives-tuning | knowledge | `my rocket` | none |
| nt03 | negatives-tuning | knowledge | `king of the jungle` | none |
| nt04 | negatives-tuning | knowledge | `skiing` | none |
| nt05 | negatives-tuning | knowledge | `sailing` | none |
| nt06 | negatives-tuning | knowledge | `curling` | none |
| nt07 | negatives-tuning | knowledge | `radiator leak` | none |
| nt08 | negatives-tuning | knowledge | `hutch roof` | none |
| nt09 | negatives-tuning | knowledge | `caring` | none |
| nt10 | negatives-tuning | knowledge | `biting midges` | none |
| nt11 | negatives-tuning | knowledge | `mating season` | none |
| nt12 | negatives-tuning | knowledge | `மழை குடை` | none |
| nt13 | negatives-tuning | knowledge | `திருவிழா பட்டாசு` | none |
| nt14 | negatives-tuning | knowledge | `piñata` | none |
| nt15 | negatives-tuning | knowledge | `soufflé` | none |
| nt16 | negatives-tuning | knowledge | `porch swing` | none |
| nt17 | negatives-tuning | knowledge | `straw maze` | none |
| nh01 | negatives-heldout | knowledge | `the wizard` | none |
| nh02 | negatives-heldout | knowledge | `my hamster` | none |
| nh03 | negatives-heldout | knowledge | `land of giants` | none |
| nh04 | negatives-heldout | knowledge | `sewing` | none |
| nh05 | negatives-heldout | knowledge | `golfing` | none |
| nh06 | negatives-heldout | knowledge | `surfing` | none |
| nh07 | negatives-heldout | knowledge | `goat cheese` | none |
| nh08 | negatives-heldout | knowledge | `harbour ferry` | none |
| nh09 | negatives-heldout | knowledge | `hating` | none |
| nh10 | negatives-heldout | knowledge | `shedding fur` | none |
| nh11 | negatives-heldout | knowledge | `canned` | none |
| nh12 | negatives-heldout | knowledge | `நிலா விண்கலம்` | none |
| nh13 | negatives-heldout | knowledge | `குரங்கு தோப்பு` | none |
| nh14 | negatives-heldout | knowledge | `jalapeño` | none |
| nh15 | negatives-heldout | knowledge | `fiancé` | none |
| nh16 | negatives-heldout | knowledge | `ladder rungs` | none |
| nh17 | negatives-heldout | knowledge | `kite competition` | none |
| ms01 | misspelling-short | knowledge | `center` | `home/calendar-november.md` 3-3 |
| ms02 | misspelling-short | knowledge | `bugdet` | `laptop/budget-autumn.md` 1-14 |
| ms03 | misspelling-short | knowledge | `appels` | `home/shopping-list.md` 7-7 |
| ms04 | misspelling-short | knowledge | `diagarm` | `school/volcano-project.md` 17-21 |
| ms05 | misspelling-short | knowledge | `chairty` | `school/newsletter-autumn.md` 44-47 |
| ms06 | misspelling-short | knowledge | `bonfrie` | `home/family-log.md` 25-29 |
| ms07 | misspelling-short | knowledge | `bukett` | `home/family-log.md` 1-5 |
| ms08 | misspelling-short | knowledge | `allredy` | `school/noticeboard.md` 16-21 |
| ms09 | misspelling-short | knowledge | `galerry` | `school/noticeboard.md` 46-51 |
| ms10 | misspelling-short | knowledge | `dokter` | `home/health/doctor-visits.md` 1-9 |
| ms11 | misspelling-short | knowledge | `jakkit` | `home/family-log.md` 19-23 |
| ms12 | misspelling-short | knowledge | `chikkin` | `school/lunch-menu.md` 9-11 |
| ms13 | misspelling-short | knowledge | `fivtean` | `home/music/recorder-practice.md` 3-6 |
| msn1 | negatives-short | knowledge | `parrot` | none |
| msn2 | negatives-short | knowledge | `walrus` | none |
| msn3 | negatives-short | knowledge | `tractor` | none |
| msn4 | negatives-short | knowledge | `beaver` | none |
