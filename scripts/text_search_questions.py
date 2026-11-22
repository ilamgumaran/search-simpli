#!/usr/bin/env python3
"""The questions of the text-search judged set and the writer of its judgments (S6-T22, plan step H1).

Each question is written here once, by hand: the question as a person would
type it, the query words a caller would send (when they differ), its kind, and
its answer as *parts*. A part is one thing a good answer must cite; it lists
one or more acceptable line ranges (a near duplicate of a file is an
alternative within a part). A range is given by an anchor, a piece of text that
occurs on exactly one line of the file (or a line number), and an optional end
anchor (the first line at or after the start holding its text); the line
numbers are computed from the generated folder
(`scripts/gen_text_search_corpus.py`), never typed. Each range names the key
words it must hold; `tests/test_text_search_score.py` checks every committed
range against a freshly generated folder.

`checks` keep a question honest: `absent_from_corpus` words occur in no file
(a misspelling, a no-answer word); `absent_from_files` words occur in none of
the files of each part's first range (a word form, a file-name question; a
later range is an alternative answer that may hold the word, as boiler.md does
for name-01). Both are compared as tokens of the repository analyzer by the test.

Rework 1 (after the Verdict): every question carries both forms, `question`
as typed and `query`, the words picked (the same text when none were); a
question that moved kind names its old id in `was`; `stale` ranges are an
older or draft copy that disagrees with the answer; `single_source` is computed
here, not typed.

Usage:

    python3 scripts/text_search_questions.py --write fixtures/text-search/judgments.json
    python3 scripts/text_search_questions.py --check fixtures/text-search/judgments.json
        # exit 1 when the file differs from what this script writes
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import gen_text_search_corpus as corpus_mod  # noqa: E402

SCHEMA = "text-search-judgments-v2"

KINDS = {
    "word": "a word the file holds",
    "word-form": "a different form of a word the file holds (plural, tense, inflection)",
    "misspelt": "a misspelt word; the file holds the right spelling",
    "phrase": "an exact phrase; its words also occur apart in other files",
    "number": "a number, date or code",
    "two-passages": "the answer spans two passages of one file",
    "two-files": "the answer needs two files",
    "filename": "the question is about the file's name, not its text",
    "about": "which files are about X",
    "file-content": "what is in this file",
    "no-answer": "nothing in the folder answers; the right result is nothing",
    # Rework 1 (the verifier's gap list)
    "tamil-latin": "Tamil asked in Latin letters; the file is in Tamil script",
    "synonym": "another word or a paraphrase for what the file says, not a form of its word",
    "table": "a row found by one column's value; the answer is another column of that row",
    "current-copy": "two files disagree; the answer is the current one, the older or draft copy is `stale`",
    "where-is-it": "the file asked for by its type or role (the spreadsheet with the loans)",
}

# The extensions the engine reads today (docs/text-search-score.md; the
# end-to-end test checks this list against the engine's own index).
NEW_KINDS = ("tamil-latin", "synonym", "table", "current-copy", "where-is-it")

READABLE_EXTENSIONS = (
    ".c", ".cpp", ".css", ".go", ".h", ".html", ".java", ".js", ".json", ".md", ".py", ".rs", ".rst",
    ".toml", ".ts", ".txt", ".yaml", ".yml", ".zig",
)


def R(path, anchor, keys=None, end=None):
    return {"path": path, "anchor": anchor, "end": end, "keys": keys}


def Q(qid, kind, question, query=None, parts=(), absent_corpus=(), absent_files=(), note=None,
      was=None, stale=(), added=False):
    return {"id": qid, "kind": kind, "question": question, "query": query, "parts": list(parts),
            "absent_from_corpus": list(absent_corpus), "absent_from_files": list(absent_files), "note": note,
            "was": was, "stale": list(stale), "added": added}


HOUSE = "home/house/"
TS = "toolshare/"
SOURDOUGH = ("home/recipes/sourdough.md", "archive/sourdough-copy.md")


def both_copies(anchor, keys=None):
    return [R(p, anchor, keys) for p in SOURDOUGH]


QUESTIONS = [
    # ---------------------------------------------------------------- word
    Q("word-01", "word", "Where did I write the dehumidifier setting?", "dehumidifier setting",
      [[R(HOUSE + "damp-bedroom.md", "Set the dehumidifier", ["dehumidifier", "55 percent"])]]),
    Q("word-02", "word", "How do I feed the sourdough starter?", "feed sourdough starter",
      [both_copies("Feed the sourdough starter", ["sourdough starter", "50 g"])]),
    Q("word-03", "word", "Which job list mentions the gutter?", "gutter",
      [[R(HOUSE + "jobs-autumn.md", "Clear the gutter", ["gutter"])]]),
    Q("word-04", "word", "What did we plan for the trellis?", "trellis",
      [[R("home/garden/garden-plan-2026.md", "Put the trellis up", ["trellis", "back fence"])]]),
    Q("word-05", "word", "How much is the deposit for power tools?", "deposit power tools",
      [[R(TS + "docs/lending-rules.md", "A refundable deposit", ["deposit", "20 pounds"])]]),
    Q("word-06", "word", "பொங்கல் எப்போது வைப்போம்?", "பொங்கல்",
      [[R("paati/pongal-samayal.md", "புதிய பானையில் பொங்கல்", ["பொங்கல்", "தை முதல் நாள்"]),
        R("paati/naatkaatti-2027.md", "பொங்கல்: ஜனவரி 14", ["பொங்கல்", "ஜனவரி 14"])]],
      note="Tamil: when Paati makes Pongal; the 2027 calendar gives the date"),
    Q("word-07", "word", "How much did the plumber charge?", "plumber charge",
      [[R("home/money/house-costs-2026.csv", "Plumber,kitchen tap", ["plumber", "45.00"])]],
      note="the answer is in a CSV file"),
    Q("word-08", "word", "When did the backup fail on the Tool Share server?", "backup failed",
      [[R(TS + "logs/server-2026-06.log", "ERROR backup failed", ["backup failed", "2026-06-17"])]],
      note="the answer is in a .log file"),
    Q("word-09", "word", "When did we see the hedgehog?", "hedgehog",
      [[R("home/garden/garden-diary-2025.txt", "2025-09-12 Fri", ["2025-09-12", "hedgehog"], end="Hedgehog seen")]],
      note="deep inside a 1,462-line file"),
    Q("word-10", "word", "Which shelf is the lawnmower on?", "lawnmower shelf",
      [[R(TS + "data/inventory.yaml", "name: lawnmower", ["lawnmower", "b3"], end="shelf: B3")]],
      note="YAML data"),
    Q("word-11", "word", "Which file sends the overdue reminder emails?", "overdue reminder",
      [[R(TS + "src/reminders.py", "def send_overdue_reminder", ["send_overdue_reminder"])]],
      note="Python source"),
    Q("word-12", "word", "What did I note about the loft hatch?", "loft hatch",
      [[R("inbox/NOTES", "Loft hatch sticks", ["loft hatch", "left corner"])]],
      note="a file with no extension"),

    # ---------------------------------------------------------------- word-form
    Q("form-01", "word-form", "When did we have the front door repainting done?", "repainting",
      [[R(HOUSE + "jobs-autumn.md", "front door was repainted", ["repainted", "9 august"])]],
      absent_files=["repainting"]),
    Q("form-02", "word-form", "When do the smoke alarm batteries get changed?", "batteries",
      [[R(HOUSE + "smoke-alarms.md", "smoke alarm battery", ["battery", "october"])]],
      absent_files=["batteries"]),
    Q("form-03", "word-form", "What has Mira knitted?", "knitted",
      [[R("home/notes/winter-crafts.md", "knitting needles", ["knitting", "scarf"])]],
      absent_files=["knitted"]),
    Q("form-04", "word-form", "When should the apple tree be pruned?", "pruned",
      [[R("home/garden/garden-plan-2026.md", "Prune the apple tree", ["prune", "february"])]],
      absent_files=["pruned"]),
    Q("form-05", "word-form", "When does Otto have swims?", "swims",
      [[R("home/schedules/otto-week.md", "Swimming 9:15", ["swimming", "9:15"])]],
      absent_files=["swims"]),
    Q("form-06", "word-form", "How do I go about descaling the kettle?", "descaling",
      [[R("home/notes/kitchen-care.md", "Descale the kettle", ["descale", "citric acid"])]],
      absent_files=["descaling"]),
    Q("form-07", "word-form", "தோட்டம் பற்றி பாட்டி என்ன எழுதினார்?", "தோட்டம்",
      [[R("paati/chedigal.md", "தோட்டத்தில்", ["தோட்டத்தில்"])]],
      absent_files=["தோட்டம்"], note="Tamil: the file has the locative form"),
    Q("form-08", "word-form", "Which walk has the geese?", "geese",
      [[R("home/pets/pickle-walks.md", "The goose by the boating lake", ["goose"])]],
      absent_files=["geese"], note="irregular plural"),
    Q("form-09", "word-form", "What did we do about the mice?", "mice",
      [[R(HOUSE + "pests.md", "Mouse droppings", ["mouse", "traps"])]],
      absent_files=["mice"], note="irregular plural"),
    Q("form-10", "word-form", "Which presents still need wrapping?", "wrapping",
      [[R("home/lists/christmas-presents.txt", "Mira: sketchbook", ["sketchbook", "shawl"], end="Paati: shawl")]],
      absent_files=["wrapping"], note="the file name says presents, so only wrapping is sent; Otto's line (wrapped) is the one that needs nothing"),
    Q("form-11", "word-form", "How are the invoices numbered?", "invoices numbered",
      [[R(TS + "docs/treasurer.md", "Each invoice is numbered", ["invoice", "inv-yyyy-nnn"])]],
      absent_files=["invoices"]),
    Q("form-12", "word-form", "Where is the shower leaking?", "leaking",
      [[R(HOUSE + "bathroom.md", "shower tray leaks", ["leaks", "corner seal"])]],
      absent_files=["leaking"]),
    Q("form-13", "word-form", "பள்ளி பற்றி பாட்டி மீராவுக்கு என்ன எழுதினார்?", "பள்ளி",
      [[R("paati/mira-kaditham.md", "பள்ளியில்", ["பள்ளியில்", "பாட்டு"])]],
      absent_files=["பள்ளி"], note="Tamil: the file has the locative form"),

    # ---------------------------------------------------------------- misspelt
    Q("spell-01", "misspelt", "dehumidifer setting", "dehumidifer",
      [[R(HOUSE + "damp-bedroom.md", "Set the dehumidifier", ["dehumidifier"])]],
      absent_corpus=["dehumidifer"], note="one letter dropped"),
    Q("spell-02", "misspelt", "Which reciept do I keep?", "reciept",
      [[R("home/money/receipts-note.md", "Keep the receipt", ["receipt", "washing machine"])]],
      absent_corpus=["reciept"], note="ie/ei swapped"),
    Q("spell-03", "misspelt", "trelis plan", "trelis",
      [[R("home/garden/garden-plan-2026.md", "Put the trellis up", ["trellis"])]],
      absent_corpus=["trelis"], note="one letter dropped"),
    Q("spell-04", "misspelt", "sourdogh baking temperature", "sourdogh",
      [both_copies("Bake at 240 degrees", ["240 degrees"])],
      absent_corpus=["sourdogh"], note="one letter dropped; the baking line answers (the title, judged in v1, answers nothing)"),
    Q("spell-05", "misspelt", "When is physiotherpy?", "physiotherpy",
      [[R("home/health/health-notes.md", "physiotherapy for the knee", ["physiotherapy", "tuesdays"])]],
      absent_corpus=["physiotherpy"], note="one letter dropped"),
    Q("spell-06", "misspelt", "accomodation in Cornwall", "accomodation",
      [[R("home/trips/cornwall-2026.md", "Accommodation: Gull Cottage", ["accommodation", "gull cottage"])]],
      absent_corpus=["accomodation"], note="the common one-m spelling"),
    Q("spell-07", "misspelt", "hedghog in the garden", "hedghog",
      [[R("home/garden/garden-diary-2025.txt", "Hedgehog seen", ["hedgehog"])]],
      absent_corpus=["hedghog"], note="one letter dropped, in a long file"),
    Q("spell-08", "misspelt", "wadrobe shelf pins", "wadrobe",
      [[R(HOUSE + "bedroom-furniture.md", "The wardrobe in the back bedroom", ["wardrobe", "shelf pins"])]],
      absent_corpus=["wadrobe"], note="one letter dropped"),
    Q("spell-09", "misspelt", "school calender half term", "calender",
      [[R("school/calendar-autumn.md", "half term", ["half term"])]],
      absent_corpus=["calender"], note="e for a; the half-term line answers (the intro line, judged in v1, answers nothing)"),
    Q("spell-10", "misspelt", "lawnmover", "lawnmover",
      [[R(TS + "data/inventory.yaml", "name: lawnmower", ["lawnmower"]),
        R(TS + "data/loans-2026.csv", "TS-041,", ["lawnmower"])]],
      absent_corpus=["lawnmover"], note="one letter changed"),
    Q("spell-11", "misspelt", "பொங்கள் சமையல்", "பொங்கள்",
      [[R("paati/pongal-samayal.md", "# பொங்கல் சமையல்", ["பொங்கல்"])]],
      absent_corpus=["பொங்கள்"], note="Tamil: ல் written as ள்"),
    Q("spell-12", "misspelt", "rubarb crumble topping", "rubarb",
      [[R("home/recipes/rhubarb-crumble.md", "Topping:", ["topping", "oats"])]],
      absent_corpus=["rubarb"], note="h dropped; the typed question also says crumble and topping, the query does not"),

    # ---------------------------------------------------------------- phrase
    Q("phrase-01", "phrase", "spare key under the blue pot",
      parts=[[R(HOUSE + "house-notes.md", "spare key under the blue pot", ["spare key under the blue pot"])]],
      note="the near duplicate in archive/ has spare key and blue pot apart"),
    Q("phrase-02", "phrase", "first Tuesday of the month",
      parts=[[R(TS + "docs/committee.md", "first Tuesday of the month", ["first tuesday of the month"])]],
      note="the 2025 copy says second Wednesday; meeting notes are dated Tuesdays"),
    Q("phrase-03", "phrase", "do not tumble dry",
      parts=[[R("home/notes/laundry.md", "do not tumble dry", ["do not tumble dry", "wool"])]],
      note="the next line says fine to tumble dry"),
    Q("phrase-04", "phrase", "bring a packed lunch",
      parts=[[R("school/trip-letter-wetlands.md", "bring a packed lunch", ["bring a packed lunch"])]],
      note="the castle letter says lunch will be provided"),
    Q("phrase-05", "phrase", "turn the water off at the stopcock",
      parts=[[R(HOUSE + "house-notes.md", "turn the water off at the stopcock", ["turn the water off at the stopcock"])]]),
    Q("phrase-06", "phrase", "keep in a cool dry place",
      parts=[[R("home/recipes/spice-mix.md", "Keep in a cool dry place", ["keep in a cool dry place"])]]),
    Q("phrase-07", "phrase", "out of order",
      parts=[[R(TS + "docs/repairs.md", "out of order", ["out of order", "pressure washer"])]],
      note="order is a common word (orders.md, the order book)"),
    Q("phrase-08", "phrase", "மழை பெய்தால்",
      parts=[[R("paati/pongal-samayal.md", "மழை பெய்தால்", ["மழை பெய்தால்"])]],
      note="Tamil: if it rains"),
    Q("phrase-09", "phrase", "rest the dough for an hour",
      parts=[[R("home/recipes/flatbread.md", "rest the dough for an hour", ["rest the dough for an hour"])]]),
    Q("phrase-10", "phrase", "cancelled direct debit",
      parts=[[R("home/money/bank-notes.tsv", "cancelled direct debit", ["cancelled direct debit"])]],
      note="the answer is in a TSV file; the electricity bill also says direct debit"),
    Q("phrase-11", "phrase", "left at the second roundabout",
      parts=[[R("home/trips/directions-to-gull-cottage.txt", "left at the second roundabout", ["left at the second roundabout"])]]),
    Q("phrase-12", "phrase", "no dogs on the beach",
      parts=[[R("home/trips/cornwall-2026.md", "No dogs on the beach", ["no dogs on the beach"])]]),

    # ---------------------------------------------------------------- number
    Q("number-01", "number", "What was order 48213-K?", "48213-K",
      parts=[[R("home/money/orders.md", "48213-K", ["48213-k", "oven door seal"])]]),
    Q("number-02", "number", "What is tool TS-017?", "TS-017",
      parts=[[R(TS + "data/inventory.yaml", "id: TS-017", ["ts-017", "pressure washer"], end="name: pressure washer"),
              R(TS + "docs/repairs.md", "TS-017", ["ts-017", "pressure washer"]),
              R(TS + "data/loans-2026.csv", "TS-017,", ["ts-017", "pressure washer"])]]),
    Q("number-03", "number", "Has INV-2026-014 been paid?", "INV-2026-014",
      parts=[[R(TS + "docs/treasurer.md", "INV-2026-014", ["inv-2026-014", "paid 12 october"])]]),
    Q("number-04", "number", "What is on 17 March?", "17 March",
      parts=[[R("home/health/health-notes.md", "17 March", ["17 march", "hearing test"])]]),
    Q("number-05", "number", "What happened on the server on 2026-06-17?", "server 2026-06-17",
      parts=[[R(TS + "logs/server-2026-06.log", "ERROR backup failed", ["2026-06-17", "error"])]],
      note="the answer is in a .log file"),
    Q("number-06", "number", "Whose number is 01632 960418?", "01632 960418",
      parts=[[R("home/lists/useful-numbers.txt", "960418", ["bram hollis", "01632 960418"]),
              R("home/contacts.tsv", "960418", ["bram hollis", "01632 960418"])]],
      note="CRLF file; contacts.tsv holds the number too (not read today)"),
    Q("number-07", "number", "What is booking GCB-3307?", "GCB-3307",
      parts=[[R("home/trips/cornwall-2026.md", "GCB-3307", ["gcb-3307", "gull cottage"])]]),
    Q("number-08", "number", "What was the 45.00 for?", "45.00",
      parts=[[R("home/money/house-costs-2026.csv", "45.00", ["45.00", "plumber"])]],
      note="the answer is in a CSV file"),
    Q("number-09", "number", "What changed in v2.3.1?", "v2.3.1",
      parts=[[R(TS + "CHANGELOG.md", "## v2.3.1", ["v2.3.1"], end="reminders were sent twice")]]),
    Q("number-10", "number", "Which port is 8086?", "port 8086",
      parts=[[R(TS + "config/server.yaml", "port: 8086", ["8086"])]]),
    Q("number-11", "number", "What is at 10:40 on 21 November?", "10:40 21 November",
      parts=[[R("school/piano-exam.md", "10:40", ["10:40", "piano exam"])]],
      note="the school calendar also has 21 November (photographs)"),
    Q("number-12", "number", "What is due 2026-11-30?", "2026-11-30",
      parts=[[R("home/car/car-notes.md", "MOT due 2026-11-30", ["mot", "2026-11-30"])]]),

    # ---------------------------------------------------------------- two-passages
    Q("span-01", "two-passages", "What time is Otto's swimming and what goes in his bag?", "Otto swimming time bag",
      parts=[[R("home/schedules/otto-week.md", "Swimming 9:15", ["9:15"])],
             [R("home/schedules/otto-week.md", "Goggles, towel", ["goggles", "locker"])]]),
    Q("span-02", "two-passages", "How long does the sourdough prove and how hot is the oven?", "sourdough prove how long oven",
      parts=[both_copies("Prove for 4 hours", ["4 hours"]), both_copies("Bake at 240 degrees", ["240 degrees"])]),
    Q("span-03", "two-passages", "Who is on the Tool Share committee and when does it meet?", "committee members meets",
      parts=[[R(TS + "docs/committee.md", "Chair: Ines Marrow", ["ines marrow", "kofi dunleavy"])],
             [R(TS + "docs/committee.md", "The committee meets on", ["first tuesday", "7:30"])]],
      note="the 2025 copy in archive/ has another chair and another day"),
    Q("span-04", "two-passages", "When were the broad beans sown and when were they picked?", "broad beans sown picked",
      parts=[[R("home/garden/garden-diary-2025.txt", "2025-03-08 Sat", ["2025-03-08", "broad beans"], end="Sowed the first broad beans")],
             [R("home/garden/garden-diary-2025.txt", "2025-06-21 Sat", ["2025-06-21", "broad beans"], end="Picked the first broad beans")]],
      note="the two entries are 104 days apart in a long file"),
    Q("span-05", "two-passages", "When is the MOT and what should the tyre pressure be?", "MOT tyre pressure",
      parts=[[R("home/car/car-notes.md", "MOT due", ["2026-11-30"])],
             [R("home/car/car-notes.md", "Tyre pressure:", ["33 psi"])]]),
    Q("span-06", "two-passages", "What time do we arrive at Gull Cottage and what is the wifi?", "arrive Gull Cottage wifi",
      parts=[[R("home/trips/cornwall-2026.md", "Arrive Saturday 24 October", ["after 4 pm"])],
             [R("home/trips/cornwall-2026.md", "Wifi at the cottage", ["gullnest"])]]),
    Q("span-07", "two-passages", "How long can a tool be borrowed and what happens if it comes back late?", "tool borrowed how long back late",
      parts=[[R(TS + "docs/lending-rules.md", "up to 7 days", ["7 days"])],
             [R(TS + "docs/lending-rules.md", "Late returns pay", ["50p a day"])]]),
    Q("span-08", "two-passages", "When was the boiler last serviced and who do I call?", "boiler serviced call",
      parts=[[R(HOUSE + "boiler.md", "2026-03-14: serviced", ["2026-03-14"]),
              R("inbox/boiler-service-2026-03-14.txt", 1, ["paid by card"], end=1)],
             [R(HOUSE + "boiler.md", "ask for Dara Wenlow", ["01632 960233"]),
              R("home/lists/useful-numbers.txt", "Wenlow Heating:", ["01632 960233"]),
              R("home/contacts.tsv", "Dara Wenlow", ["01632 960233"])]],
      note="the inbox note's file name gives the date of the last service"),
    Q("span-09", "two-passages", "பொங்கலுக்கு என்ன பொருட்கள் வேண்டும், எப்படிச் செய்வது?", "பொங்கல் பொருட்கள் செய்முறை",
      parts=[[R("paati/pongal-samayal.md", "பச்சரிசி ஒரு கோப்பை", ["பச்சரிசி", "வெல்லம்"])],
             [R("paati/pongal-samayal.md", "அரிசியையும் பருப்பையும்", ["வேக வைக்கவும்"])]],
      note="Tamil: what goes into Pongal and how it is made"),
    Q("span-10", "two-passages", "When is half term and when is the Christmas concert?", "half term Christmas concert",
      parts=[[R("school/calendar-autumn.md", "26 to 30 October", ["half term"])],
             [R("school/calendar-autumn.md", "Christmas concert", ["16 december"])]]),
    Q("span-11", "two-passages", "Where are the ladder and the cordless drill kept?", "ladder cordless drill kept",
      parts=[[R(TS + "data/inventory.yaml", "name: ladder", ["ladder", "outside rack"], end="shelf: outside rack")],
             [R(TS + "data/inventory.yaml", "name: cordless drill", ["cordless drill", "a2"], end="shelf: A2")]]),

    # ---------------------------------------------------------------- two-files
    Q("pair-01", "two-files", "How much was the boiler service and when is the next one due?", "boiler service cost next due",
      parts=[[R("home/money/receipts-note.md", "Wenlow Heating, 14 March", ["96 pounds"])],
             [R(HOUSE + "boiler.md", "Next service due", ["march 2027"]),
              R("inbox/boiler-service-2026-03-14.txt", 1, ["next one in a year"], end=1)]]),
    Q("pair-02", "two-files", "What's for dinner on Wednesday and what do I need for it?", "Wednesday dinner ingredients",
      parts=[[R("home/schedules/meal-plan-week-38.md", "Wednesday: lentil dal", ["lentil dal"])],
             [R("home/recipes/lentil-dal.md", "250 g red lentils", ["red lentils"], end="cumin seeds and turmeric")]]),
    Q("pair-03", "two-files", "Which tool is out of order, and is its repair paid for?", "out of order repair paid",
      parts=[[R(TS + "docs/repairs.md", "out of order", ["pressure washer"])],
             [R(TS + "docs/treasurer.md", "INV-2026-014", ["hose", "paid 12 october"])]]),
    Q("word-13", "word", "When is the wetlands trip and what does the letter say to bring?", "wetlands trip date bring",
      parts=[[R("school/trip-letter-wetlands.md", "On Thursday 8 October", ["8 october", "saltmarsh wetlands"]),
              R("school/calendar-autumn.md", "8 October: Year 6 trip", ["8 october", "saltmarsh wetlands"])],
             [R("school/trip-letter-wetlands.md", "bring a packed lunch", ["packed lunch", "waterproof coat"])]],
      was="pair-04", note="the letter alone answers both parts (v1 judged it as two files)"),
    Q("pair-04", "two-files", "Which order was the oven door seal, and when did we fit it?", "oven door seal order fitted",
      parts=[[R("home/money/orders.md", "48213-K", ["48213-k", "oven door seal"])],
             [R("home/notes/kitchen-care.md", "The oven door seal was swapped", ["july"])]],
      added=True, note="new in rework 1 (v1's pair-04 is now word-13)"),
    Q("pair-05", "two-files", "What port does the Tool Share server use and which code reads it?", "server port code",
      parts=[[R(TS + "config/server.yaml", "port: 8086", ["8086"])],
             [R(TS + "src/app.py", "PORT = config", ["port"])]]),
    Q("word-14", "word", "Where is Gull Cottage and how do we get there?", "Gull Cottage where directions",
      parts=[[R("home/trips/cornwall-2026.md", "Accommodation: Gull Cottage", ["porthwenna"]),
              R("home/trips/directions-to-gull-cottage.txt", "Gull Cottage is the white one", ["gull cottage", "harbour"])],
             [R("home/trips/directions-to-gull-cottage.txt", "From the A-road", ["porthwenna turning"], end="green gate")]],
      was="pair-06", note="the directions alone answer both parts (v1 judged it as two files)"),
    Q("word-15", "word", "Who is the chimney sweep and when did he last come?", "chimney sweep last",
      parts=[[R("home/lists/useful-numbers.txt", "Chimney sweep (Bram Hollis)", ["bram hollis"]),
              R(HOUSE + "jobs-autumn.md", "Chimney swept by Bram Hollis", ["bram hollis"]),
              R("home/contacts.tsv", "Bram Hollis", ["bram hollis", "chimney sweep"])],
             [R(HOUSE + "jobs-autumn.md", "Chimney swept by Bram Hollis", ["2 september"]),
              R("home/money/receipts-note.md", "Chimney sweep, 2 September", ["2 september"]),
              R("home/money/house-costs-2026.csv", "Chimney sweep,", ["2026-09-02"])]],
      was="pair-07", note="one line of jobs-autumn.md answers both parts (v1 judged it as two files)"),
    Q("pair-06", "two-files", "Who chairs the Tool Share and what is her phone number?", "Tool Share chair phone number",
      parts=[[R(TS + "docs/committee.md", "Chair: Ines Marrow", ["ines marrow"])],
             [R("home/contacts.tsv", "Ines Marrow", ["01632 960310"])]],
      stale=[R("archive/committee-2025.md", "Chair: Orla Quent", ["orla quent"])],
      added=True, note="new in rework 1 (v1's pair-06 is now word-14); the number is only in contacts.tsv, not read today"),
    Q("pair-07", "two-files", "How much did the new tyres cost and what pressure should they be?", "tyres cost pressure",
      parts=[[R("home/car/tyres-receipt.txt", 1, ["140 pounds"], end=1)],
             [R("home/car/car-notes.md", "Tyre pressure:", ["33 psi"])]],
      added=True, note="new in rework 1 (v1's pair-07 is now word-15)"),
    Q("pair-08", "two-files", "பொங்கலுக்கு என்ன சமைப்பது, அடுத்த பொங்கல் எப்போது?", "பொங்கல் சமையல் நாள்",
      parts=[[R("paati/pongal-samayal.md", "பச்சரிசி ஒரு கோப்பை", ["பச்சரிசி"])],
             [R("paati/naatkaatti-2027.md", "பொங்கல்: ஜனவரி 14", ["ஜனவரி 14"])]],
      note="Tamil: what to cook for Pongal and the date of the next one"),
    Q("pair-09", "two-files", "Which release fixed the reminders going out twice, and what was the issue?", "release fixed reminders going out twice issue",
      parts=[[R(TS + "CHANGELOG.md", "reminders were sent twice", ["issue 31"])],
             [R(TS + "docs/issues.md", "The overdue reminder email went out twice", ["twice", "extended"])]]),
    Q("pair-10", "two-files", "When is Mira's piano exam and which pieces is she playing?", "Mira piano exam pieces",
      parts=[[R("school/piano-exam.md", "Grade 3 piano exam", ["21 november", "10:40"])],
             [R("home/notes/music.md", "Swan Boat Waltz", ["swan boat waltz"])]]),
    Q("pair-11", "two-files", "When is Pickle's booster and what's the vet's number?", "Pickle booster vet number",
      parts=[[R("home/pets/pickle.md", "Booster vaccination", ["12 january 2027"])],
             [R("home/lists/useful-numbers.txt", "Vet, Fennick Vets", ["01632 960552"])]]),

    # ---------------------------------------------------------------- filename
    Q("name-01", "filename", "Find the boiler service note.", "boiler service note",
      parts=[[R("inbox/boiler-service-2026-03-14.txt", 1, ["paid by card"], end=1),
              R(HOUSE + "boiler.md", "## Service record", ["service record", "2026-03-14"], end="2026-03-14: serviced")]],
      absent_files=["boiler", "service"], note="the date is in the name, the text says only 'Done'; boiler.md's service record also answers"),
    Q("name-02", "filename", "Where's my passport renewal checklist?", "passport renewal checklist",
      parts=[[R("inbox/passport-renewal-checklist.txt", 1, ["two photos"], end=1)]],
      absent_files=["passport", "renewal", "checklist"]),
    Q("name-03", "filename", "Open the wifi router note.", "wifi router",
      parts=[[R(HOUSE + "wifi-router.txt", 1, ["password", "reset"], end=1)]],
      absent_files=["wifi", "router"]),
    Q("name-04", "filename", "Find the file for Otto's birthday party.", "Otto birthday party",
      parts=[[R("home/otto-birthday-party-2026.md", 1, ["5 july", "twelve coming"], end=3)]],
      absent_files=["birthday", "party", "otto"]),
    Q("name-05", "filename", "Where's the dentist note?", "dentist",
      parts=[[R("home/health/dentist.txt", 1, ["check-up"], end=1)]],
      absent_files=["dentist"]),
    Q("name-06", "filename", "Find the garage clear-out list.", "garage clearout",
      parts=[[R("home/lists/garage-clearout.txt", 1, ["tip run"], end=1)]],
      absent_files=["garage", "clearout"]),
    Q("name-07", "filename", "தீபாவளி பட்டியல் எங்கே?", "தீபாவளி பட்டியல்",
      parts=[[R("paati/தீபாவளி-பட்டியல்.txt", 1, ["முறுக்கு", "விளக்குகள்"], end=5)]],
      absent_files=["தீபாவளி", "பட்டியல்"], note="Tamil: where is the Deepavali list; a Tamil file name"),
    Q("name-08", "filename", "Find the home insurance renewal.", "home insurance renewal",
      parts=[[R("home/money/home-insurance-renewal.md", "Quote from Larkspur", ["312.40", "1 december"])]],
      absent_files=["insurance", "renewal"]),
    Q("name-09", "filename", "Open the AGM notes.", "AGM",
      parts=[[R(TS + "meetings/agm-2026.md", 1, ["12 march 2026", "accounts approved"], end=4)]],
      absent_files=["agm"]),
    Q("name-10", "filename", "Where is the volunteer rota?", "volunteer rota",
      parts=[[R(TS + "data/volunteer-rota.csv", 1, ["date,desk,repairs"], end=5)]],
      absent_files=["volunteer", "rota"], note="a CSV file"),
    Q("name-11", "filename", "Find the camping packing list.", "camping packing list",
      parts=[[R("home/lists/camping-packing.txt", 1, ["tent", "head torches"], end=5)]],
      absent_files=["camping", "packing", "list"]),
    Q("name-12", "filename", "Find the September electricity bill.", "electricity bill September",
      parts=[[R("home/money/electricity-bill-sept.txt", 1, ["84.17"], end=1)]],
      absent_files=["electricity", "bill", "september"], note="the name has sept, the query September"),

    # ---------------------------------------------------------------- about
    Q("about-01", "about", "Which files are about the bees?", "bees",
      parts=[[R("home/garden/beekeeping-notes.md", "# Beekeeping notes", ["beekeeping"])],
             [R("home/lists/bee-supplies.txt", "Bee suit", ["bee suit"])],
             [R("school/bee-project.md", "# Mira's bee project", ["bee project"])]],
      note="one file says bees, the others bee and beekeeping"),
    Q("about-02", "about", "Which files are about the Cornwall trip?", "Cornwall trip",
      parts=[[R("home/trips/cornwall-2026.md", "# Cornwall, half term 2026", ["cornwall"])],
             [R("home/trips/directions-to-gull-cottage.txt", "From the A-road", ["porthwenna"])],
             [R("home/lists/cornwall-packing.txt", "Cornwall packing", ["cornwall"])]],
      note="the directions never say Cornwall"),
    Q("about-03", "about", "Which files are about Pickle the dog?", "Pickle dog",
      parts=[[R("home/pets/pickle.md", "Pickle is our dog", ["pickle", "dog"])],
             [R("home/pets/pickle-walks.md", "# Pickle's walks", ["pickle"])],
             [R("home/lists/pickle-shopping.txt", "Pickle: dog food", ["pickle", "dog food"])]]),
    Q("about-04", "about", "பாட்டியின் சமையல் குறிப்புகள் எந்தக் கோப்புகளில் உள்ளன?", "சமையல் குறிப்பு",
      parts=[[R("paati/pongal-samayal.md", "# பொங்கல் சமையல்", ["சமையல்"])],
             [R("paati/rasam.md", "பாட்டியின் சமையல் குறிப்பு", ["ரசம்"])],
             [R("paati/kootu.md", "# பூசணிக்காய் கூட்டு", ["கூட்டு"])]],
      note="Tamil: which files hold Paati's recipes; kootu.md never says recipe"),
    Q("about-05", "about", "Which files are about the pressure washer?", "pressure washer",
      parts=[[R(TS + "docs/repairs.md", "Pressure washer (TS-017)", ["pressure washer"])],
             [R(TS + "docs/treasurer.md", "INV-2026-014", ["pressure washer"])],
             [R(TS + "data/inventory.yaml", "name: pressure washer", ["pressure washer"]),
              R(TS + "data/loans-2026.csv", "TS-017,", ["pressure washer"])]],
      note="either tool list (the YAML inventory or the loans CSV) satisfies the third part"),
    Q("about-06", "about", "Which files are about school trips?", "school trip",
      parts=[[R("school/trip-letter-wetlands.md", "# Year 6 trip", ["trip"])],
             [R("school/trip-letter-castle.md", "# Year 2 trip", ["trip"])]]),
    Q("about-07", "about", "Which files are about the car?", "car",
      parts=[[R("home/car/car-notes.md", "# Car notes", ["car"])],
             [R("home/car/tyres-receipt.txt", "Two front tyres", ["tyres"])]],
      note="the receipt never says car; its folder does"),
    Q("about-08", "about", "Which files are about damp and mould?", "damp mould",
      parts=[[R(HOUSE + "damp-bedroom.md", "# Damp in Otto's bedroom", ["damp"])],
             [R(HOUSE + "bathroom.md", "Mould on the ceiling", ["mould"])]]),
    Q("about-09", "about", "Which files are the Tool Share website's code?", "Tool Share website code",
      parts=[[R(TS + "src/app.py", "The Tool Share web app", ["web app"])],
             [R(TS + "src/reminders.py", "Overdue reminders for", ["tool share"])],
             [R(TS + "src/models.py", "Plain records for tools", ["loans"])],
             [R(TS + "site/app.js", "Highlights the tools", ["tool list"])],
             [R(TS + "site/index.html", "<title>", ["harrowdean tool share"])],
             [R(TS + "site/join.html", "<title>", ["join the tool share"])],
             [R(TS + "site/styles.css", 1, ["font-family"], end=1)],
             [R(TS + "site/sitemap.xml", "<urlset>", ["urlset"])]],
      note="the README (not read today) says the website code is in src/ and site/; none says website or code"),
    Q("about-10", "about", "Which files are about sourdough?", "sourdough",
      parts=[both_copies("# Sourdough loaf", ["sourdough"]),
             [R("home/notes/baking-log.txt", "Sourdough loaf 1", ["sourdough"])]]),
    Q("about-11", "about", "Which files are about household bills?", "household bills",
      parts=[[R("home/money/electricity-bill-sept.txt", 1, ["84.17"], end=1)],
             [R("home/money/home-insurance-renewal.md", "Quote from Larkspur", ["312.40"])],
             [R("home/money/house-costs-2026.csv", 1, ["amount"], end=1)]],
      note="no file says household; one name says bill"),

    # ---------------------------------------------------------------- file-content
    Q("content-01", "file-content", "What is in inventory.yaml?", "inventory.yaml",
      parts=[[R(TS + "data/inventory.yaml", 1, ["inventory", "shelf"], end=2)]]),
    Q("content-02", "file-content", "What is in the NOTES file in the inbox?", "inbox NOTES",
      parts=[[R("inbox/NOTES", 1, ["loft hatch", "landing"], end=2)]],
      note="a file with no extension"),
    Q("content-03", "file-content", "What is in budget-2026.csv?", "budget-2026.csv",
      parts=[[R("home/money/budget-2026.csv", 1, ["month,food,energy"], end=1)]],
      note="a CSV file; the header says what it holds"),
    Q("content-04", "file-content", "What is in garden-diary-2025.txt?", "garden-diary-2025.txt",
      parts=[[R("home/garden/garden-diary-2025.txt", 1, ["garden diary 2025", "one entry a day"], end=2)]]),
    Q("content-05", "file-content", "What does reminders.py do?", "reminders.py",
      parts=[[R(TS + "src/reminders.py", 1, ["overdue reminders", "once a day"], end=3)]]),
    Q("content-06", "file-content", "What is in server.yaml?", "server.yaml",
      parts=[[R(TS + "config/server.yaml", 1, ["web server settings"], end=1)]]),
    Q("content-07", "file-content", "kootu.md கோப்பில் என்ன இருக்கிறது?", "kootu.md",
      parts=[[R("paati/kootu.md", 1, ["கூட்டு"], end=3)]],
      note="Tamil: what is in kootu.md; a Latin file name over Tamil text"),
    Q("content-08", "file-content", "What is the Tool Share index.html page?", "index.html",
      parts=[[R(TS + "site/index.html", "<title>", ["harrowdean tool share"])]]),
    Q("content-09", "file-content", "What is in the Tool Share CHANGELOG.md?", "CHANGELOG.md",
      parts=[[R(TS + "CHANGELOG.md", 1, ["changelog"], end=1)]]),
    Q("content-10", "file-content", "What is in otto-week.md?", "otto-week.md",
      parts=[[R("home/schedules/otto-week.md", 1, ["otto's week"], end=1)]]),
    Q("content-11", "file-content", "What is in contacts.tsv?", "contacts.tsv",
      parts=[[R("home/contacts.tsv", 1, ["name", "role", "phone"], end=1)]],
      note="a TSV file"),

    # ---------------------------------------------------------------- no-answer
    Q("none-01", "no-answer", "Where did I put the snorkel?", "snorkel", absent_corpus=["snorkel"]),
    Q("none-02", "no-answer", "When was the trampoline bought?", "trampoline bought", absent_corpus=["trampoline"],
      note="bought occurs in other files"),
    Q("none-03", "no-answer", "When is the piano tuner coming?", "piano tuner", absent_corpus=["tuner"],
      note="near topic: piano occurs (the exam, the journal)"),
    Q("none-04", "no-answer", "What is the burglar alarm code?", "burglar alarm code", absent_corpus=["burglar"],
      note="near topic: smoke alarm, code"),
    Q("none-05", "no-answer", "கிரிக்கெட் போட்டி எப்போது?", "கிரிக்கெட்", absent_corpus=["கிரிக்கெட்"],
      note="Tamil: when is the cricket match"),
    Q("none-06", "no-answer", "Where can we hire a kayak?", "kayak hire", absent_corpus=["kayak"],
      note="near word: hire (room hire)"),
    Q("none-07", "no-answer", "Where did we put the hammock?", "hammock", absent_corpus=["hammock"], added=True,
      note="new in rework 1 (v1's none-07 is now syn-01)"),
    Q("syn-01", "synonym", "When is Mira's orthodontist appointment?", "orthodontist",
      parts=[[R("home/health/dentist.txt", 1, ["brace review", "3 february"], end=1)]],
      absent_corpus=["orthodontist"], was="none-07",
      note="the dentist note's brace review is the appointment (v1 judged it no-answer)"),
    Q("none-08", "no-answer", "How much was the solar panel quote?", "solar panel quote", absent_corpus=["solar"],
      note="near words: panel (a fence panel), quote (the insurance quote)"),
    Q("none-09", "no-answer", "What is tool TS-999?", "TS-999", absent_corpus=["999"],
      note="a code with the shape of real ones"),
    Q("none-10", "no-answer", "When is our wedding anniversary?", "wedding anniversary", absent_corpus=["wedding", "anniversary"]),
    Q("none-11", "no-answer", "When are the flu jabs?", "flu jab", absent_corpus=["flu", "jab", "jabs"]),
    Q("none-12", "no-answer", "When does the library van come?", "library van", absent_corpus=["van"],
      note="near word: library (library day, library books)"),

    # ---------------------------------------------------------------- rework 1: tamil-latin
    Q("tam-01", "tamil-latin", "pongal eppo?", "pongal",
      parts=[[R("paati/naatkaatti-2027.md", "பொங்கல்: ஜனவரி 14", ["ஜனவரி 14"]),
              R("paati/pongal-samayal.md", "புதிய பானையில் பொங்கல்", ["தை முதல் நாள்"])]],
      absent_files=["pongal"], note="when is Pongal; pongal-samayal.md has the word in its file name"),
    Q("tam-02", "tamil-latin", "rasam seyya enna venum?", "rasam",
      parts=[[R("paati/rasam.md", "ரசம் செய்ய", ["புளி", "தக்காளி"])]],
      absent_files=["rasam"], note="what goes into rasam; the file name is rasam.md"),
    Q("tam-03", "tamil-latin", "poosanikkai kootu eppadi seyvathu?", "poosanikkai kootu",
      parts=[[R("paati/kootu.md", "பூசணிக்காய் இருநூறு", ["பாசிப்பருப்பு"], end="தேங்காய் அரைத்து")]],
      absent_files=["poosanikkai", "kootu"], note="how to make the pumpkin kootu; the file name is kootu.md"),
    Q("tam-04", "tamil-latin", "paatti thottathil enna valarkirathu?", "paatti thottam",
      parts=[[R("paati/chedigal.md", "தோட்டத்தில்", ["கத்தரிக்கா"])]],
      absent_files=["paatti", "thottam"], note="what grows in Paati's garden; no Latin word in the file or its name"),
    Q("tam-05", "tamil-latin", "thulasi chedikku eppo thanneer?", "thulasi thanneer",
      parts=[[R("paati/chedigal.md", "துளசி", ["காலையில்"])]],
      absent_files=["thulasi", "thanneer"], note="when to water the tulsi"),
    Q("tam-06", "tamil-latin", "Mira-vukku paatti ezhuthiya kaditham", "Mira paatti kaditham",
      parts=[[R("paati/mira-kaditham.md", "அன்புள்ள மீரா", ["மீரா"], end="முறுக்கு")]],
      absent_files=["kaditham"], note="Paati's letter to Mira; mira and kaditham are in the file name"),
    Q("tam-07", "tamil-latin", "tamil puthaandu 2027 eppo?", "tamil puthaandu 2027",
      parts=[[R("paati/naatkaatti-2027.md", "தமிழ்ப் புத்தாண்டு", ["ஏப்ரல் 14"])]],
      absent_files=["puthaandu"], note="Tamil New Year; 2027 is in the file name and the text"),
    Q("tam-08", "tamil-latin", "pongalukku ethanai koppai pacharisi?", "pongal pacharisi",
      parts=[[R("paati/pongal-samayal.md", "பச்சரிசி ஒரு கோப்பை", ["பச்சரிசி"])]],
      absent_files=["pacharisi"], note="how much raw rice for Pongal"),
    Q("tam-09", "tamil-latin", "deepavali pattiyal", "deepavali pattiyal",
      parts=[[R("paati/தீபாவளி-பட்டியல்.txt", 1, ["முறுக்கு"], end=5)]],
      absent_files=["deepavali", "pattiyal"], note="the Deepavali list; its file name is in Tamil script"),
    Q("tam-10", "tamil-latin", "murukku eppo seyvaanga?", "murukku",
      parts=[[R("paati/mira-kaditham.md", "முறுக்கு", ["அடுத்த முறை"]),
              R("paati/தீபாவளி-பட்டியல்.txt", 1, ["முறுக்கு"], end=1)]],
      absent_files=["murukku"], note="when murukku is made: the letter (next visit) or the Deepavali list"),

    # ---------------------------------------------------------------- rework 1: synonym
    Q("syn-02", "synonym", "Which day is the rubbish collected?", "rubbish collected day",
      parts=[[R(HOUSE + "house-notes.md", "Black bin on Thursdays", ["thursdays"])]],
      absent_files=["rubbish", "collected"], stale=[R("archive/house-notes-2024.md", "Black bin on Thursdays", ["thursdays"])],
      note="bin for rubbish; the 2024 notes say the same"),
    Q("syn-03", "synonym", "How do I shut off the mains?", "shut off mains",
      parts=[[R(HOUSE + "house-notes.md", "stopcock", ["stopcock"])]],
      absent_files=["shut", "mains"], note="the stopcock line; the 2024 notes have it too"),
    Q("syn-04", "synonym", "When is the car's roadworthiness check due?", "car roadworthiness check",
      parts=[[R("home/car/car-notes.md", "MOT due", ["2026-11-30"])]],
      absent_files=["roadworthiness", "check"], note="MOT for the check"),
    Q("syn-05", "synonym", "What do we do about the insects by the back door?", "insects back door",
      parts=[[R(HOUSE + "pests.md", "Ants by the back door", ["chalk line"])]],
      absent_files=["insects"], note="ants for insects; back door also occurs elsewhere"),
    Q("syn-06", "synonym", "When is Otto's ear check?", "Otto ear check",
      parts=[[R("home/health/health-notes.md", "hearing test", ["17 march", "9:20"])]],
      absent_files=["ear", "check"], note="hearing test for ear check"),
    Q("syn-07", "synonym", "What is Pickle's diet?", "Pickle diet",
      parts=[[R("home/pets/pickle.md", "Half a scoop", ["no grapes"])]],
      absent_files=["diet"], stale=[R("archive/pickle-2024.md", "One scoop", ["one scoop"])],
      note="food for diet; the 2024 note is out of date"),
    Q("syn-08", "synonym", "Who looks after the Tool Share's money?", "Tool Share money",
      parts=[[R(TS + "docs/committee.md", "Treasurer: Kofi Dunleavy", ["treasurer", "kofi dunleavy"]),
              R("archive/committee-2025.md", "Treasurer: Kofi Dunleavy", ["treasurer"]),
              R(TS + "docs/treasurer.md", "# Treasurer's notes", ["treasurer"])]],
      absent_files=["money"], note="treasurer for who looks after the money; both committee lists agree on him"),
    Q("syn-09", "synonym", "How much is the Tool Share subscription?", "Tool Share subscription",
      parts=[[R(TS + "site/join.html", "Membership is 10 pounds", ["10 pounds a year"])]],
      absent_files=["subscription"], note="membership for subscription"),
    Q("syn-10", "synonym", "When is Pickle's next jab?", "Pickle jab",
      parts=[[R("home/pets/pickle.md", "Booster vaccination", ["12 january 2027"])]],
      absent_corpus=["jab"], note="booster vaccination for jab"),

    # ---------------------------------------------------------------- rework 1: table
    Q("table-01", "table", "Which order did we send back?", "order sent back",
      parts=[[R("home/money/orders.md", "55102-B", ["garden hose reel", "returned"])]],
      absent_files=["back"], note="Markdown table: the row whose Status is returned, its What"),
    Q("table-02", "table", "When did we order Otto's school shoes?", "Otto school shoes order",
      parts=[[R("home/money/orders.md", "60977-A", ["2026-10-01"])]],
      note="Markdown table: the row by What, its Date"),
    Q("table-03", "table", "Which room is chess club in?", "chess club room",
      parts=[[R("school/clubs-autumn.md", "| Chess |", ["library"])]],
      note="Markdown table: the row by Club, its Room"),
    Q("table-04", "table", "Who runs the Thursday club?", "Thursday club",
      parts=[[R("school/clubs-autumn.md", "| Thursday |", ["mr ashby"])]],
      note="Markdown table: the row by Day, its Runs it; Thursday occurs in many files"),
    Q("table-05", "table", "Which shelf is the hedge trimmer on?", "hedge trimmer shelf",
      parts=[[R(TS + "data/inventory.yaml", "name: hedge trimmer", ["hedge trimmer", "c2"], end="shelf: C2")]],
      note="YAML records: the entry by name, its shelf"),
    Q("table-06", "table", "How many times was the tile cutter lent this year?", "tile cutter lent",
      parts=[[R(TS + "data/loans-2026.csv", "TS-005,", ["tile cutter,1"])]],
      note="CSV (not read today): the row by tool, its loans_2026"),
    Q("table-07", "table", "What does Kit Arden do?", "Kit Arden",
      parts=[[R("home/contacts.tsv", "Kit Arden", ["plumber"]),
              R("home/lists/useful-numbers.txt", "Kit Arden", ["plumber"])]],
      note="TSV (not read today): the row by name, its role; the numbers list says it too"),
    Q("table-08", "table", "What is the energy budget for March?", "energy budget March",
      parts=[[R("home/money/budget-2026.csv", "mar,", ["138"])]],
      note="CSV (not read today): the row by month (mar), its energy column"),
    Q("table-09", "table", "Who is on the desk on 21 November?", "desk 21 November",
      parts=[[R(TS + "data/volunteer-rota.csv", "2026-11-21", ["ines"])]],
      note="CSV (not read today): the row by date, its desk column"),
    Q("table-10", "table", "What did the window cleaner charge?", "window cleaner charge",
      parts=[[R("home/money/house-costs-2026.csv", "2026-01-15,Window cleaner", ["18.00"]),
              R("home/money/house-costs-2026.csv", "2026-10-14,Window cleaner", ["18.00"])]],
      note="CSV (not read today): either row by who, its amount"),

    # ---------------------------------------------------------------- rework 1: current-copy
    Q("cur-01", "current-copy", "How long can tools be borrowed for?", "tools borrowed how long",
      parts=[[R(TS + "docs/lending-rules.md", "up to 7 days", ["7 days"])]],
      stale=[R("archive/lending-rules-2024.md", "up to 14 days", ["14 days"])]),
    Q("cur-02", "current-copy", "When is the next boiler service?", "next boiler service",
      parts=[[R(HOUSE + "boiler.md", "Next service due", ["march 2027"]),
              R("inbox/boiler-service-2026-03-14.txt", 1, ["next one in a year"], end=1)]],
      stale=[R("archive/boiler-2025.md", "Next service due", ["march 2026"])]),
    Q("cur-03", "current-copy", "When is the Christmas concert?", "Christmas concert",
      parts=[[R("school/calendar-autumn.md", "Christmas concert", ["16 december", "2 pm"])]],
      stale=[R("school/calendar-autumn-draft.md", "Christmas concert", ["15 december"])]),
    Q("cur-04", "current-copy", "Who chairs the Tool Share committee?", "committee chair",
      parts=[[R(TS + "docs/committee.md", "Chair: Ines Marrow", ["ines marrow"])]],
      stale=[R("archive/committee-2025.md", "Chair: Orla Quent", ["orla quent"])]),
    Q("cur-05", "current-copy", "When does the Tool Share committee meet?", "committee meet when",
      parts=[[R(TS + "docs/committee.md", "The committee meets on", ["first tuesday", "7:30"])]],
      stale=[R("archive/committee-2025.md", "The committee meets on", ["second wednesday"])]),
    Q("cur-06", "current-copy", "How much food does Pickle get?", "Pickle food how much",
      parts=[[R("home/pets/pickle.md", "Half a scoop", ["morning and evening"])]],
      stale=[R("archive/pickle-2024.md", "One scoop", ["morning only"])]),
    Q("cur-07", "current-copy", "Where are we staying in Cornwall?", "Cornwall staying",
      parts=[[R("home/trips/cornwall-2026.md", "Accommodation: Gull Cottage", ["gull cottage", "booked"])]],
      stale=[R("home/trips/cornwall-2026-draft.md", "Two cottages to choose from", ["heron barn"])]),
    Q("cur-08", "current-copy", "When do we arrive in Cornwall?", "arrive Cornwall",
      parts=[[R("home/trips/cornwall-2026.md", "Arrive Saturday 24 October", ["saturday 24 october"])]],
      stale=[R("home/trips/cornwall-2026-draft.md", "Arrive Friday 23 October", ["friday 23 october"])]),
    Q("cur-09", "current-copy", "Where is the spare key?", "spare key",
      parts=[[R(HOUSE + "house-notes.md", "spare key under the blue pot", ["blue pot"])]],
      stale=[R("archive/house-notes-2024.md", "The spare key is in the key safe", ["key safe"])]),

    # ---------------------------------------------------------------- rework 1: where-is-it
    Q("where-01", "where-is-it", "Where is the spreadsheet with the loans?", "spreadsheet loans",
      parts=[[R(TS + "data/loans-2026.csv", 1, ["id,tool,loans_2026"], end=1)]],
      absent_files=["spreadsheet"], note="a CSV file (not read today); loans is in its name"),
    Q("where-02", "where-is-it", "Which script does the backup?", "backup script",
      parts=[[R(TS + "scripts/backup.sh", 1, ["nightly copy"], end=3)]],
      absent_files=["backup"], note="a shell script (not read today); backup is in its name"),
    Q("where-03", "where-is-it", "Where is the server log for June?", "server log June",
      parts=[[R(TS + "logs/server-2026-06.log", 1, ["2026-06-01"], end=1)]],
      absent_files=["june"], note="a .log file (not read today); June is 06 in its name"),
    Q("where-04", "where-is-it", "Where is the Tool Share website's stylesheet?", "website stylesheet",
      parts=[[R(TS + "site/styles.css", 1, ["font-family"], end=2)]],
      absent_files=["website", "stylesheet"], note="styles.css; neither word in the file"),
    Q("where-05", "where-is-it", "Which Python file defines the loan record?", "python loan record",
      parts=[[R(TS + "src/models.py", 1, ["plain records"], end=1)]],
      absent_files=["python"], note="models.py; the docstring says records and loans"),
    Q("where-06", "where-is-it", "Where is the Tool Share site map?", "site map",
      parts=[[R(TS + "site/sitemap.xml", "<urlset>", ["urlset"])]],
      absent_files=["map"], note="an XML file (not read today); sitemap is one word in its name"),
    Q("where-07", "where-is-it", "Where is the family budget spreadsheet?", "budget spreadsheet",
      parts=[[R("home/money/budget-2026.csv", 1, ["month,food,energy"], end=1)]],
      absent_files=["spreadsheet"], note="a CSV file (not read today)"),
    Q("where-08", "where-is-it", "Where is the list of phone numbers?", "phone numbers list",
      parts=[[R("home/lists/useful-numbers.txt", 1, ["useful numbers"], end=1),
              R("home/contacts.tsv", 1, ["phone"], end=1)]],
      absent_files=["list"], note="the numbers list, or contacts.tsv (not read today)"),
    Q("where-09", "where-is-it", "Where is the to-do list?", "to-do list",
      parts=[[R("home/TODO", 1, ["ring bram"], end=3)]],
      absent_files=["list"], note="a file named TODO, no extension (not read today)"),
    Q("where-10", "where-is-it", "Where are the smart plug timers?", "smart plug timers",
      parts=[[R("home/house/smart-plugs.json", 1, ["plugs"], end=7)]],
      absent_files=["timers"], note="a JSON file"),
]


def lines_of(data: bytes) -> list[str]:
    """1-based lines: split at \\n, a trailing \\r dropped, a final line without a terminator counted."""
    text = data.decode("utf-8")
    if text.startswith("﻿"):
        text = text[1:]
    parts = text.split("\n")
    if parts and parts[-1] == "":
        parts.pop()
    return [p[:-1] if p.endswith("\r") else p for p in parts]


def locate(lines: list[str], anchor, path: str) -> int:
    if isinstance(anchor, int):
        if not 1 <= anchor <= len(lines):
            raise ValueError(f"{path}: line {anchor} out of range 1..{len(lines)}")
        return anchor
    hits = [n for n, line in enumerate(lines, 1) if anchor in line]
    if len(hits) != 1:
        raise ValueError(f"{path}: anchor {anchor!r} is on {len(hits)} lines, not exactly one")
    return hits[0]


def locate_end(lines: list[str], anchor, start: int, path: str) -> int:
    """An end anchor: a line number, or the first line at or after `start` holding the text."""
    if isinstance(anchor, int):
        return locate(lines, anchor, path)
    for n in range(start, len(lines) + 1):
        if anchor in lines[n - 1]:
            return n
    raise ValueError(f"{path}: end anchor {anchor!r} not found at or after line {start}")


def resolve_range(corpus: dict[str, bytes], qid: str, r: dict) -> dict:
    if r["path"] not in corpus:
        raise ValueError(f"{qid}: no file {r['path']}")
    lines = lines_of(corpus[r["path"]])
    start = locate(lines, r["anchor"], r["path"])
    end = locate_end(lines, r["end"], start, r["path"]) if r["end"] is not None else start
    if end < start:
        raise ValueError(f"{qid}: {r['path']} end {end} before start {start}")
    return {"path": r["path"], "start_line": start, "end_line": end, "keys": r["keys"] or [r["anchor"]]}


def readable(path: str) -> bool:
    name = path.rsplit("/", 1)[-1]
    return "." in name and name[name.rindex("."):].lower() in READABLE_EXTENSIONS


def file_counts(corpus: dict[str, bytes]) -> dict[str, int]:
    """For every analyzer token: how many readable files hold it, exact copies counted once."""
    from src.search_platform.core import tokenize  # the repository analyzer, no stemming

    seen: set[bytes] = set()
    counts: dict[str, int] = {}
    for path in sorted(corpus):
        data = corpus[path]
        if not readable(path) or data in seen:
            continue
        seen.add(data)
        for tok in set(tokenize(data.decode("utf-8"))):
            counts[tok] = counts.get(tok, 0) + 1
    return counts


def single_source(query: str, counts: dict[str, int]) -> bool:
    """True when the rarest query token that occurs in a readable file occurs in exactly one."""
    from src.search_platform.core import tokenize

    present = [counts[tok] for tok in tokenize(query) if counts.get(tok, 0) > 0]
    return bool(present) and min(present) == 1


def resolve(corpus: dict[str, bytes]) -> list[dict]:
    out = []
    counts = file_counts(corpus)
    for q in QUESTIONS:
        assert q["kind"] in KINDS, q["id"]
        parts = []
        files = []
        for part in q["parts"]:
            ranges = [resolve_range(corpus, q["id"], r) for r in part]
            for r in ranges:
                if r["path"] not in files:
                    files.append(r["path"])
            parts.append({"ranges": ranges})
        query = q["query"] if q["query"] is not None else q["question"]
        row = {"id": q["id"], "kind": q["kind"], "question": q["question"], "query": query}
        if q["was"]:
            row["was"] = q["was"]
        if q["added"] or (q["kind"] in NEW_KINDS and not q["was"]):
            row["added"] = "rework-1"
        row["files"] = files
        row["parts"] = parts
        if q["stale"]:
            row["stale"] = [resolve_range(corpus, q["id"], r) for r in q["stale"]]
        row["single_source"] = bool(files) and single_source(query, counts)
        checks = {}
        if q["absent_from_corpus"]:
            checks["absent_from_corpus"] = q["absent_from_corpus"]
        if q["absent_from_files"]:
            checks["absent_from_files"] = q["absent_from_files"]
        if checks:
            row["checks"] = checks
        if q["note"]:
            row["note"] = q["note"]
        out.append(row)
    ids = [row["id"] for row in out]
    assert len(ids) == len(set(ids)), "duplicate ids"
    return out


def judgments() -> dict:
    corpus = corpus_mod.build_corpus()
    questions = resolve(corpus)
    counts = {kind: sum(1 for q in questions if q["kind"] == kind) for kind in KINDS}
    return {
        "schema": SCHEMA,
        "version": 2,
        "pack": "text-search",
        "corpus": {
            "generator": "scripts/gen_text_search_corpus.py",
            "seed": corpus_mod.SEED,
            "files": len(corpus),
            "bytes": sum(len(v) for v in corpus.values()),
            "corpus_sha256": corpus_mod.corpus_digest(corpus),
        },
        "conventions": {
            "lines": "1-based; a line ends at \\n or \\r\\n; a final line without a terminator counts",
            "forms": "every question is sent twice: `question` as typed, and `query`, the words a caller would pick (the same text when none were picked)",
            "was": "the id the question had in version 1, when it moved kind",
            "added": "rework-1 for a question that version 1 did not have",
            "stale": "ranges of an older or draft copy that disagrees with the answer; returning them is not an answer",
            "single_source": "the rarest query token that any readable file holds is held by exactly one (repository analyzer, no stemming, exact copies counted once; readable = an extension the engine reads today)",
            "parts": "every part is one thing a complete answer cites; any one of a part's ranges satisfies it",
            "files": "every path named in any part; `files` is empty exactly for no-answer questions",
            "range_inside_passage": "a range is found when a returned passage has the same path and start_line <= range start and range end <= end_line",
            "keys": "each key occurs, case-folded, in the text of the range's lines joined by newlines",
            "checks": "absent_from_corpus: no file holds the word as a token; absent_from_files: no file of a part's first range holds it as a token (repository analyzer); a later range is an alternative that may hold it",
        },
        "kinds": {kind: {"what": what, "questions": counts[kind]} for kind, what in KINDS.items()},
        "questions": questions,
    }


def render() -> str:
    return json.dumps(judgments(), ensure_ascii=False, indent=2) + "\n"


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[0] not in ("--write", "--check"):
        print(__doc__.split("Usage:")[1], file=sys.stderr)
        return 2
    target = Path(argv[1])
    text = render()
    if argv[0] == "--write":
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        print(f"wrote {target}: {len(judgments()['questions'])} questions")
        return 0
    if not target.is_file() or target.read_text(encoding="utf-8") != text:
        print(f"{target} differs from what scripts/text_search_questions.py writes", file=sys.stderr)
        return 1
    print(f"{target}: up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
