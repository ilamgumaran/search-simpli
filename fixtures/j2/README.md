# J2: the judged fixture (S5-T1)

Invented content only: the Varnell family of Thistlecombe (Maren, Joss, Pip in
Year 5, Wren in Year 2, Paati their grandmother, Biscuit the dog), Thistlecombe
Primary, Mill Lane, Hollow Woods. No real person, place or product. Phone numbers
are from the ranges set aside for drama.

J2 says where keyword search loses. It holds 109 queries in seven slices
plus named negatives, graded 0 to 2, over three roots. Its numbers are the
baseline later search tasks are judged against (`fixtures/j2/baseline.json`,
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
| `school/` | 27 |
| `home/` | 21 |
| `laptop/` | 20 |

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
| negatives | 14 | - | nothing answers; distractors named |

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
