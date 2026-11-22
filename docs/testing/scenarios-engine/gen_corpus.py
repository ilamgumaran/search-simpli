#!/usr/bin/env python3
"""Write the invented household folder the engine scenarios run against.

Usage: python3 -I gen_corpus.py <empty-or-absent-folder> [--scale N <folder>]

Everything here is invented: the names, the places, the numbers. The folder
holds every kind of file the scenario list asks for: notes, lists, recipes,
logs, CSV, JSON, YAML, markup, source, files with no extension, English and
Tamil, long and one-line files, nested folders, odd names (spaces, non-ASCII,
an upper-case extension), an empty file, binary bytes, a file over the 10 MiB
cap, a CRLF file, a BOM file, symlinks (to a file, to a folder, dangling),
dot-folders and an ignored node_modules.

`--scale N <folder>` instead writes N generated notes for the moderate-scale
scenarios (deterministic, a 3,000-word invented vocabulary plus a few planted
words).
"""
import os
import random
import sys


def write(root, rel, text, mode="w", encoding="utf-8", newline=None):
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if mode == "wb":
        with open(path, "wb") as handle:
            handle.write(text)
    else:
        with open(path, mode, encoding=encoding, newline=newline) as handle:
            handle.write(text)


GARDEN = """# Garden plan for spring

## Beds

The north bed gets tomatoes and basil. The south bed gets beans along the fence.
Marigolds go at the corners to keep the aphids away.

## Compost

Turn the compost bin every Saturday. Coffee grounds and eggshells go in;
no meat, no dairy. The bin by the shed is nearly full.

## Watering

Water early in the morning. The hose timer runs for twenty minutes.
"""

PLUMBER = """Plumber visit, 2026-03-14
Mr. Fenwick from Bluepipe Plumbing came about the leaky faucet in the upstairs bathroom.
He replaced the cartridge and the washer. Cost: $142.50, paid by card.
Next check: the water heater anode rod, due in March 2027.
Call 555-0142 if the drip comes back.
"""

LENTIL = """# Red lentil soup

Serves four. Takes forty minutes.

## Ingredients

- 1 cup red lentils, rinsed
- 1 onion, chopped
- 2 carrots, diced
- 1 teaspoon cumin
- 4 cups vegetable stock
- juice of half a lemon

## Method

Fry the onion until soft. Add the carrots and cumin and stir for a minute.
Add the lentils and the stock, bring to a boil, then simmer for twenty-five minutes.
Blend half of the soup and stir it back in. Finish with lemon juice.
"""

DOSAI = """# தோசை (dosai)

## மாவு (batter)

இரண்டு கப் அரிசி, அரை கப் உளுந்து. இரவு முழுவதும் ஊற வைக்கவும்.
Soak two cups of rice and half a cup of urad dal overnight, then grind.

## சுடுவது (cooking)

தோசைக்கல்லை நன்றாக சூடாக்கவும். ஒரு கரண்டி மாவை ஊற்றி மெல்லியதாக பரப்பவும்.
Heat the griddle well, pour a ladle of batter and spread it thin.
Serve with தேங்காய் சட்னி (coconut chutney) and sambar.
"""

RASAM = """ரசம் செய்முறை
புளியை வெந்நீரில் கரைக்கவும்.
தக்காளி, மிளகு, சீரகம், பூண்டு சேர்த்து கொதிக்க விடவும்.
கடைசியில் கொத்தமல்லி தூவவும்.
"""

POEM = """நிலா நிலா ஓடி வா
நில்லாமல் ஓடி வா
மலை மேலே ஏறி வா
மல்லிகைப் பூ கொண்டு வா
"""

GROCERIES = """Groceries for the week
milk
eggs (a dozen)
sourdough bread
bananas
AA batteries for the smoke alarm
dish soap
oat flakes
"""

PACKING = """Packing list — beach trip
sunscreen
two towels
the striped umbrella
snorkel and mask
flip-flops
a paperback for the train
"""

FURNACE_LOG = """2026-01-05 furnace filter replaced (MERV 8)
2026-02-11 thermostat batteries changed
2026-03-02 pilot light went out, relit
2026-04-19 furnace filter replaced (MERV 8)
"""

BUDGET_CSV = """month,category,amount
2026-01,electricity,142.50
2026-01,water,38.10
2026-02,electricity,131.75
2026-02,internet,59.99
"""

INSURANCE_JSON = """{
  "policy": "HX-20417",
  "insurer": "Lanternfield Mutual",
  "renewal": "2026-09-30",
  "covers": ["roof", "water damage", "theft"],
  "deductible": 500
}
"""

READING_YAML = """reader: Pip
books:
  - title: The Lighthouse Keeper's Cat
    pages: 212
    finished: 2026-02-20
  - title: Rivers of the North
    pages: 96
    finished: 2026-03-08
"""

STATION_PY = '''"""Weather station reader for the backyard sensor."""

import json


def read_temperature(sensor_path):
    """Return the temperature in Celsius from the sensor file."""
    with open(sensor_path) as handle:
        raw = handle.read().strip()
    return int(raw) / 1000.0


def humidity_alert(humidity_percent):
    return humidity_percent > 80
'''

SENSOR_C = """#include <stdio.h>

/* Read the rain gauge tick counter. */
int rain_gauge_ticks(void) {
    return 42;
}
"""

STATION_TOML = """[station]
name = "backyard"
interval_seconds = 300
"""

INDEX_HTML = """<!doctype html>
<html><head><title>Backyard weather</title></head>
<body><h1>Backyard weather</h1><p>Rainfall this week: 12 mm.</p></body></html>
"""

STYLE_CSS = """body { font-family: serif; background: #fdf6e3; }
"""

README_NOEXT = """READ ME FIRST
The spare house key is with the neighbour at number 12.
The wifi router is in the hall cupboard.
"""

MAKEFILE = """all:
\tpython3 main.py
"""

CAFE = """# Café notes

The café on Elm Street does a good flat white. Closed on Mondays.
Résumé of the visit: quiet, good for reading.
"""

CRLF = "Car service notes\r\nOil change at 45,000 km\r\nTyre rotation booked for April\r\n"

BOM = "﻿Birthday ideas\nA kite for the park\nA puzzle with a thousand pieces\n"

UPPER = """SCHOOL CALENDAR NOTES
Parent evening on Thursday at six.
"""

WORD_FORMS = """Running club notes
Pip ran three laps on Monday. Tobin runs every morning.
The runners meet by the library. Running shoes need replacing.
The children were swimming at the pool; Pip swims well now.
"""

MISSPELL = """Vacuum cleaner manual
Empty the dust canister after each use. Replace the filter every three months.
"""

DEEP = """# Deep note

The emergency candle box is in the attic, behind the suitcase.
"""

SHELL = """Odd characters note
Use the $HOME key and the `backtick` cable. 50% off; a&b; C++ guide; [draft]; it's "quoted".
Price: 3*4=12. Path: a|b. Email: info@example.org
"""


def make_household(root):
    write(root, "notes/garden-plan.md", GARDEN)
    write(root, "notes/plumber visit.txt", PLUMBER)
    write(root, "notes/café notes.md", CAFE)
    write(root, "notes/crlf-car.txt", CRLF, newline="")
    write(root, "notes/birthday-bom.txt", BOM)
    write(root, "notes/running club.txt", WORD_FORMS)
    write(root, "notes/vacuum.txt", MISSPELL)
    write(root, "notes/odd chars.txt", SHELL)
    write(root, "recipes/lentil soup.md", LENTIL)
    write(root, "recipes/dosai.md", DOSAI)
    write(root, "recipes/ரசம்.txt", RASAM)
    write(root, "tamil/கவிதை.txt", POEM)
    write(root, "lists/groceries.txt", GROCERIES)
    write(root, "lists/packing list — beach trip.txt", PACKING)
    write(root, "logs/furnace.log", FURNACE_LOG)
    write(root, "money/budget-2026.csv", BUDGET_CSV)
    write(root, "money/insurance.json", INSURANCE_JSON)
    write(root, "school/reading-log.yaml", READING_YAML)
    write(root, "school/CALENDAR.TXT", UPPER)
    write(root, "project/weather-station/main.py", STATION_PY)
    write(root, "project/weather-station/sensor.c", SENSOR_C)
    write(root, "project/weather-station/config.toml", STATION_TOML)
    write(root, "project/weather-station/web/index.html", INDEX_HTML)
    write(root, "project/weather-station/web/style.css", STYLE_CSS)
    write(root, "project/weather-station/Makefile", MAKEFILE)
    write(root, "README", README_NOEXT)
    write(root, "a/b/c/d/e/f/deep.md", DEEP)
    write(root, "empty.txt", "")
    # One line of about 20 KB, no newline at the end; the planted word is near the end.
    words = ("lantern harbour pebble meadow kettle " * 600).strip()
    write(root, "one-line.txt", words + " zephyrwhistle")
    # A long diary: 5,000 lines; a planted sentence at line 4,321.
    lines = []
    for i in range(1, 5001):
        if i == 4321:
            lines.append("Day 4321: found the lost brass compass under the porch steps.")
        else:
            lines.append("Day %d: walked the dog, watered the ferns, wrote a letter." % i)
    write(root, "long/diary.md", "# Diary\n\n" + "\n".join(lines) + "\n")
    # Binary bytes behind a .txt name (invalid UTF-8) and a true binary.
    write(root, "binary/scan.txt", bytes(range(256)) * 8, mode="wb")
    write(root, "binary/data.bin", bytes(range(256)) * 4, mode="wb")
    # A file over the 10 MiB default cap.
    chunk = "archive line with the word overflowtoken and some filler text\n"
    big = chunk * (11 * 1024 * 1024 // len(chunk) + 1)
    write(root, "big/archive.txt", big)
    # Ignored: a dot-folder and node_modules.
    write(root, ".private/hidden.txt", "hiddenword should never be found\n")
    write(root, "node_modules/pkg/index.js", "// nodemodword\n")
    # Symlinks: to a file, to a folder, dangling.
    os.symlink("lists/groceries.txt", os.path.join(root, "link-to-groceries.txt"))
    os.symlink("recipes", os.path.join(root, "link-to-recipes"))
    os.symlink("does-not-exist.txt", os.path.join(root, "dangling.txt"))


VOCAB_SEED = 20261122


def make_scale(root, count):
    rng = random.Random(VOCAB_SEED)
    syllables = ["ka", "lo", "mi", "ren", "to", "va", "shi", "pu", "del", "an", "or", "is", "ve", "mu", "ta"]
    vocab = sorted({"".join(rng.choice(syllables) for _ in range(rng.randint(2, 4))) for _ in range(6000)})[:3000]
    common = ["the", "a", "and", "to", "of", "in", "for", "with", "on", "at"]
    for i in range(count):
        folder = "box%02d/shelf%02d" % (i % 50, (i // 50) % 20)
        n_lines = rng.randint(5, 40)
        out = ["# Note %d" % i, ""]
        for _ in range(n_lines):
            words = [rng.choice(vocab) if rng.random() < 0.7 else rng.choice(common) for _ in range(rng.randint(6, 14))]
            out.append(" ".join(words) + ".")
        if i == 7777:
            out.append("The quartzfinch receipt is in this note.")
        write(root, "%s/note-%05d.md" % (folder, i), "\n".join(out) + "\n")


def main(argv):
    if len(argv) == 4 and argv[1] == "--scale":
        root = argv[3]
        if os.path.exists(root) and os.listdir(root):
            sys.exit("refusing: %s is not empty" % root)
        os.makedirs(root, exist_ok=True)
        make_scale(root, int(argv[2]))
        return
    if len(argv) != 2:
        sys.exit(__doc__)
    root = argv[1]
    if os.path.exists(root) and os.listdir(root):
        sys.exit("refusing: %s is not empty" % root)
    os.makedirs(root, exist_ok=True)
    make_household(root)


if __name__ == "__main__":
    main(sys.argv)
