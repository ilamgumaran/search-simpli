#!/usr/bin/env python3
"""Write the invented mixed-text folder of the text-search judged set (S6-T22, plan step H1).

The folder stands for what a household and a small project keep: notes, lists,
recipes, schedules, logs, tables as CSV and TSV, JSON and YAML data, markup, a
little source code, plain files with no extension, long files and one-line
files, Latin and Tamil script, near duplicates, and files whose name says more
than their text.

**Invented content only.** The Pellow family of 14 Copper Lane, Harrowdean
(Tamsin, Idris, Mira in Year 6, Otto in Year 2, Valli Paati their grandmother,
Pickle the dog) and the Harrowdean Tool Share, a lending library for tools run
by volunteers. No real person, firm or product, and no real place but the
county of Cornwall, where a trip goes. Phone numbers are from the 01632 960xxx
range set aside for drama; web addresses are on `.invalid`.

Two kinds of file: *planted* files, written out below, which hold the answers
the questions in `fixtures/text-search/judgments.json` are judged against; and
*filler* files (a journal, shopping lists, meeting notes, logs, recipes,
spelling lists, inventory rows), drawn from fixed sentence pools with a seeded
`random.Random`, so the folder has the bulk and the distractors a real one has.

Deterministic: the same seed writes the same bytes (`corpus_sha256` below is
recorded in the judgments and checked by `tests/test_text_search_score.py`).
Standard library only.

Usage:

    python3 scripts/gen_text_search_corpus.py OUT_DIR
        # writes the folder; OUT_DIR must not exist or must be empty
    python3 scripts/gen_text_search_corpus.py --digest
        # prints the file count, byte count and corpus_sha256
"""

from __future__ import annotations

import datetime
import hashlib
import random
import sys
from pathlib import Path

SEED = 2211

# ---------------------------------------------------------------------------
# Planted files. Their lines are what the judgments cite.
# ---------------------------------------------------------------------------

PLANTED: dict[str, str] = {}


def plant(path: str, text: str) -> None:
    assert path not in PLANTED, path
    PLANTED[path] = text


plant("home/house/house-notes.md", """\
# House notes

Things anyone looking after 14 Copper Lane needs to know.

## Keys

The spare key under the blue pot by the back step opens the kitchen door only.
The shed key hangs on the hook inside the pantry.

## Water

If a pipe bursts, turn the water off at the stopcock under the kitchen sink.
The outside tap has its own valve in the garage, on the left wall.

## Heating

The boiler is in the airing cupboard; see boiler.md for the service record.
Thermostat schedule: 6:30 to 8:30 and 17:00 to 22:00 on weekdays.

## Bins

Black bin on Thursdays, green bin every other Monday.
""")

plant("archive/house-notes-2024.md", """\
# House notes

Things anyone looking after 14 Copper Lane needs to know.

## Keys

The spare key is in the key safe by the back step; the code is with Tamsin.
The blue pot was moved to the front path in the spring.
The shed key hangs on the hook inside the pantry.

## Water

The stopcock is under the kitchen sink; it was replaced in 2023.
The outside tap has its own valve in the garage, on the left wall.

## Heating

The boiler is in the airing cupboard.
Thermostat schedule: 6:30 to 8:30 and 17:00 to 22:00 on weekdays.

## Bins

Black bin on Thursdays, green bin every other Monday.
""")

plant("home/house/boiler.md", """\
# Boiler

Make: Halvard Combi 28. Installed 2019, in the airing cupboard.

## Service record

- 2024-03-02: serviced by Wenlow Heating, all fine.
- 2025-03-11: serviced by Wenlow Heating, flue seal replaced.
- 2026-03-14: serviced by Wenlow Heating, pressure topped up.

## Next service

Next service due in March 2027. Book in January; they get busy.

## Who to call

Wenlow Heating, ask for Dara Wenlow: 01632 960233. Out of hours: 01632 960234.

## Pressure

The gauge should read between 1 and 1.5 bar when the heating is cold.
""")

plant("inbox/boiler-service-2026-03-14.txt",
      "Done. Paid by card. All fine, pressure topped up, next one in a year.\n")

plant("home/money/receipts-note.md", """\
# Receipts to keep

Keep the receipt for the washing machine until 2028 (five-year guarantee).

## Paid this year

- Wenlow Heating, 14 March: 96 pounds by card for the yearly visit.
- Chimney sweep, 2 September: 70 pounds cash.
- Bike repair for Mira, 20 May: 38 pounds.
""")

plant("home/house/damp-bedroom.md", """\
# Damp in Otto's bedroom

The corner by the window gets black spots every winter.

## What helps

Set the dehumidifier to 55 percent and empty the tank each morning.
Open the window for ten minutes after a shower next door.
Keep the chest of drawers a hand's width off the outside wall.

## Tried and did not help

Anti-mould paint from the hardware shop (2024): the spots came back by February.
""")

plant("home/house/bathroom.md", """\
# Bathroom

The shower tray leaks at the corner seal; reseal it with white silicone.
The extractor fan runs for 15 minutes after the light goes off.
Mould on the ceiling: wipe with diluted bleach, then open the window.
""")

plant("home/house/jobs-autumn.md", """\
# Autumn jobs 2026

- [x] The front door was repainted in Harbour Blue on 9 August.
- [ ] Clear the gutter over the back door before the leaves come down.
- [ ] Bleed the radiators in the front room.
- [x] Chimney swept by Bram Hollis on 2 September; next sweep autumn 2027.
- [ ] Check the loft insulation depth (it should be 270 mm).
""")

plant("home/house/smoke-alarms.md", """\
# Smoke alarms

Three alarms: landing, hall, and a heat alarm in the kitchen.
Change the smoke alarm battery every October, when the clocks go back.
Test button: hold it for five seconds.
""")

plant("home/notes/kitchen-care.md", """\
# Kitchen care

Descale the kettle with citric acid on the first Sunday of each month.
The oven door seal was swapped in July (see orders.md).
Do not put the good knives in the dishwasher.
""")

plant("home/money/orders.md", """\
# Orders

| Date | Order | What | Status |
| --- | --- | --- | --- |
| 2026-07-03 | 48213-K | replacement oven door seal | delivered |
| 2026-08-19 | 55102-B | garden hose reel | returned |
| 2026-10-01 | 60977-A | school shoes for Otto, size 12 | delivered |
""")

plant("home/house/pests.md", """\
# Pests

Mouse droppings behind the fridge in November; two traps set, peanut butter works best.
Ants by the back door in June: chalk line across the step.
""")

plant("home/house/bedroom-furniture.md", """\
# Bedroom furniture

The wardrobe in the back bedroom came flat-packed; the spare shelf pins are in the bag taped inside the door.
Mira's bed slats: two were glued in 2025.
""")

plant("home/house/wifi-router.txt",
      "Password is on the sticker underneath. If the lights go orange, hold the reset for 10 seconds.\n")

plant("home/notes/laundry.md", """\
# Laundry

Wool jumpers: cold wash, do not tumble dry, dry flat on the rack.
School polo shirts: 40 degrees, fine to tumble dry on low.
Pickle's bed cover: 60 degrees, on its own.
""")

plant("home/notes/winter-crafts.md", """\
# Winter crafts

Mira's knitting needles are in the blue tin on the bookcase. She is making a scarf for Paati.
Otto's clay animals dry on the windowsill for two days before painting.
""")

plant("home/health/health-notes.md", """\
# Health notes

Idris: physiotherapy for the knee, Tuesdays at 4 at the Fennick clinic.
17 March: Otto's hearing test at the Fennick clinic, 9:20.
Mira: eye test every two years; next one in spring.
""")

plant("home/health/dentist.txt",
      "Next check-up 3 February, 8:40. Mira needs the brace review then. Bring the referral letter.\n")

plant("home/notes/music.md", """\
# Music

Mira's grade 3 piano pieces: Swan Boat Waltz, Rain on the Shed Roof, and the scales in D and B flat.
Otto wants recorder lessons after Christmas.
""")

plant("school/piano-exam.md", """\
# Piano exam

Grade 3 piano exam: Saturday 21 November at 10:40, Harrowdean Music Rooms.
Arrive fifteen minutes early to warm up.
""")

plant("home/trips/cornwall-2026.md", """\
# Cornwall, half term 2026

## Getting there

Arrive Saturday 24 October after 4 pm; the owner leaves the key in the box by the door.
See directions-to-gull-cottage.txt for the last few miles.

## Accommodation

Accommodation: Gull Cottage, Porthwenna, booked for 3 nights, booking reference GCB-3307.
Wifi at the cottage: network GullNest, password on the fridge.

## Beach

No dogs on the beach between May and September; in October Pickle can come.

## Food

The farm shop in Porthwenna closes at 5 on Sundays.
""")

plant("home/trips/directions-to-gull-cottage.txt", """\
From the A-road, take the Porthwenna turning.
At the first roundabout go straight on; go left at the second roundabout, by the garage.
After the chapel, the lane drops to the harbour; Gull Cottage is the white one with the green gate.
Park on the left; the lane is too narrow to turn.
""")

plant("home/lists/cornwall-packing.txt",
      "Cornwall packing: wetsuits, Pickle's lead and towel, board games, wellies, the travel kettle.\n")

plant("home/lists/camping-packing.txt", """\
tent, pegs and mallet
head torches x4
sleeping mats
stove and gas
matches in a jar
""")

# Exported from a phone: CRLF line endings.
plant("home/lists/useful-numbers.txt", "\r\n".join([
    "Useful numbers",
    "Chimney sweep (Bram Hollis) 01632 960418",
    "Vet, Fennick Vets: 01632 960552",
    "Plumber (Kit Arden): 01632 960771",
    "Wenlow Heating: 01632 960233",
    "School office: 01632 960100",
]) + "\r\n")

plant("home/pets/pickle.md", """\
# Pickle

Pickle is our dog, a wire-haired terrier cross, born 3 May 2021.

## Vet

Fennick Vets, Dr Sana Ilves. Number in useful-numbers.txt.
Booster vaccination due 12 January 2027.

## Food

Half a scoop morning and evening; no grapes, no onions.
""")

plant("home/pets/pickle-walks.md", """\
# Pickle's walks

Morning: round Fennick Park, 25 minutes.
The goose by the boating lake hissed at Pickle on Sunday; go the other way round.
Evening: along Saltmarsh Road and back.
""")

plant("home/lists/pickle-shopping.txt",
      "Pickle: dog food (large bag), poo bags, chew sticks, flea drops.\n")

plant("home/car/car-notes.md", """\
# Car notes

Small grey hatchback, bought 2022.

## MOT

MOT due 2026-11-30; book at Copper Lane Motors.

## Tyres

Tyre pressure: 33 psi front, 30 psi rear (35 front when loaded for Cornwall).

## Insurance

Renews in April; policy with Larkspur Mutual.
""")

plant("home/car/tyres-receipt.txt",
      "Two front tyres fitted, 14 June, 140 pounds, Copper Lane Motors.\n")

plant("home/money/home-insurance-renewal.md", """\
# Larkspur Mutual quote

Quote from Larkspur Mutual: 312.40 a year for buildings and contents. Renew by 1 December.
""")

plant("home/money/electricity-bill-sept.txt",
      "Amount 84.17, paid 2 October by direct debit. Meter read 41,207.\n")

plant("home/money/bank-notes.tsv", "\n".join([
    "date\tnote",
    "2026-01-05\tmoved savings to the Larkspur account",
    "2026-02-01\tcancelled direct debit to Fennick Gym",
    "2026-03-20\tnew card arrived, old one cut up",
    "2026-06-11\tstanding order for Tool Share membership set up",
]) + "\n")

plant("home/schedules/otto-week.md", """\
# Otto's week (autumn term)

## Monday

Reading book back to school.

## Tuesday

After-school club until 4:30.

## Wednesday

PE: kit in the bag.

## Thursday

Library day.

## Friday

Spelling test.

## Saturday

Swimming 9:15 at Fennick Leisure Centre, lane 2 group.

## Sunday

Nothing planned.

## Swimming bag

Goggles, towel, a pound coin for the locker, and a snack for after.
""")

plant("home/schedules/meal-plan-week-38.md", """\
# Meals, week 38

- Monday: jacket potatoes and beans
- Tuesday: fish fingers
- Wednesday: lentil dal with rice (recipe in recipes/lentil-dal.md)
- Thursday: leftovers
- Friday: pizza night
""")

plant("home/recipes/lentil-dal.md", """\
# Lentil dal

## Ingredients

- 250 g red lentils
- 1 onion, 3 cloves garlic, a thumb of ginger
- 1 tin chopped tomatoes
- 1 teaspoon each of cumin seeds and turmeric

## Method

1. Rinse the lentils until the water runs clear.
2. Fry the onion, garlic and ginger; add the spices for a minute.
3. Add the lentils, tomatoes and 700 ml water; simmer for 25 minutes.
""")

SOURDOUGH = """\
# Sourdough loaf

## The starter

Feed the sourdough starter the night before: 50 g flour, 50 g water.

## Dough

Mix 500 g strong flour, 350 g water, 100 g starter and 10 g salt.
Prove for 4 hours at room temperature, folding every half hour.

## Baking

Bake at 240 degrees in the lidded pot for 20 minutes, then 20 minutes lid off.
"""
plant("home/recipes/sourdough.md", SOURDOUGH)
plant("archive/sourdough-copy.md", SOURDOUGH)

plant("home/notes/baking-log.txt", """\
Sourdough loaf 1: flat, starter too young.
Loaf 2: better rise, pale crust.
Loaf 3: good crust, open crumb; keep this timing.
""")

plant("home/recipes/rhubarb-crumble.md", """\
# Rhubarb crumble

600 g rhubarb, cut into finger lengths, with 80 g sugar and the zest of an orange.
Topping: 150 g flour, 100 g butter, 75 g oats, 50 g sugar.
Bake at 190 degrees for 35 minutes.
""")

plant("home/recipes/flatbread.md", """\
# Flatbread

300 g flour, 200 ml warm water, a pinch of salt, a spoon of oil.
Mix, knead for five minutes, then rest the dough for an hour under a damp cloth.
Cook each round in a dry pan for a minute a side.
""")

plant("home/recipes/spice-mix.md", """\
# Spice mix for roast vegetables

Two spoons cumin, one of coriander, one of smoked paprika, half of chilli.
Keep in a cool dry place for up to three months.
""")

plant("home/garden/garden-plan-2026.md", """\
# Garden plan 2026

## Back fence

Put the trellis up along the back fence for the climbing beans.

## Fruit

Prune the apple tree in February, before the buds break.

## Beds

Onions and garlic in bed 1; potatoes in bed 2; squash in bed 3.
""")

plant("home/garden/beekeeping-notes.md", """\
# Beekeeping notes

The bees in the top hive swarmed on 2 June; the swarm was caught in the plum tree.
Winter feed: sugar syrup in October, fondant from December.
""")

plant("home/lists/bee-supplies.txt",
      "Bee suit (Mira's size), smoker fuel, frames x10, sugar for winter feed.\n")

plant("school/bee-project.md", """\
# Mira's bee project

Why do bees dance? Mira watched the top hive for a week and drew the waggle dance.
Due Friday 13 November.
""")

plant("school/calendar-autumn.md", """\
# School calendar, autumn term 2026

Calendar from the school office, Harrowdean Primary.

## First half

- 3 September: term starts
- 8 October: Year 6 trip to Saltmarsh Wetlands
- 26 to 30 October: half term

## Second half

- 21 November: school photographs
- 16 December: Christmas concert, 2 pm, school hall
- 18 December: term ends at 1.30
""")

plant("school/trip-letter-wetlands.md", """\
# Year 6 trip: Saltmarsh Wetlands

Dear parents and carers,

On Thursday 8 October Year 6 will visit Saltmarsh Wetlands to study birds.
Please bring a packed lunch in a bag that can be thrown away, and a waterproof coat.
The coach leaves at 8:45 and returns by 3:15.
""")

plant("school/trip-letter-castle.md", """\
# Year 2 trip: Harrow Castle

Dear parents and carers,

On Tuesday 10 November Year 2 will visit Harrow Castle.
Lunch will be provided by the school kitchen; please send a coat and sensible shoes.
""")

plant("home/otto-birthday-party-2026.md", """\
# 5 July

Twelve coming. Cake from Larch Bakery. Pass-the-parcel, then the garden treasure hunt.
""")

plant("home/lists/garage-clearout.txt",
      "Tip run: paint tins, old bike, broken chair, the cracked paddling pool.\n")

plant("home/lists/christmas-presents.txt", """\
Otto: bike lights (bought, wrapped)
Mira: sketchbook and pens (bought)
Paati: shawl (to order)
""")

plant("inbox/passport-renewal-checklist.txt",
      "Two photos, signed on the back. Old one goes in the envelope. Form posted?\n")

plant("inbox/NOTES", """\
Loft hatch sticks in damp weather; push the left corner first.
Measure the landing for a new runner.
""")

plant("home/TODO", """\
- ring Bram
- order printer ink
- return library books
""")

plant("home/money/house-costs-2026.csv", "\n".join([
    "date,who,what,amount",
    "2026-01-15,Window cleaner,front and back,18.00",
    "2026-02-09,Hardware shop,draught strip,12.50",
    "2026-04-02,Plumber,kitchen tap washer,45.00",
    "2026-05-20,Bike shop,Mira's brakes,38.00",
    "2026-09-02,Chimney sweep,yearly sweep,70.00",
    "2026-10-14,Window cleaner,front and back,18.00",
]) + "\n")

BUDGET_ROWS = ["month,food,energy,transport,school,savings"]
for _m, _name in enumerate(["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]):
    BUDGET_ROWS.append(f"{_name},{410 + 7 * _m},{150 - 6 * _m if _m < 6 else 120 + 5 * (_m - 6)},{60 + (_m % 3) * 5},{25 + (_m % 4) * 10},{100}")
plant("home/money/budget-2026.csv", "\n".join(BUDGET_ROWS) + "\n")

plant("home/contacts.tsv", "\n".join([
    "name\trole\tphone",
    "Bram Hollis\tchimney sweep\t01632 960418",
    "Kit Arden\tplumber\t01632 960771",
    "Dara Wenlow\theating\t01632 960233",
    "Ines Marrow\tTool Share chair\t01632 960310",
]) + "\n")

# --- the Tool Share project -------------------------------------------------

plant("toolshare/README", """\
Harrowdean Tool Share

A lending library for tools, run by volunteers from the Copper Lane hall.
The website code is in src/ and site/; the data files are in data/.
""")

plant("toolshare/docs/lending-rules.md", """\
# Lending rules

## How long

Tools can be borrowed for up to 7 days; ask at the desk to extend.

## Deposits

A refundable deposit of 20 pounds is taken for power tools.

## Late returns

Late returns pay 50p a day, capped at 5 pounds; three late returns and borrowing stops for a month.
""")

plant("toolshare/docs/committee.md", """\
# Committee

## Members

Chair: Ines Marrow. Treasurer: Kofi Dunleavy. Secretary: Tamsin Pellow.

## Meetings

The committee meets on the first Tuesday of the month at the Copper Lane hall, 7:30 pm.
Members may come and listen; ask the secretary for the agenda.
""")

plant("archive/committee-2025.md", """\
# Committee

## Members

Chair: Orla Quent. Treasurer: Kofi Dunleavy. Secretary: Tamsin Pellow.

## Meetings

The committee meets on the second Wednesday of the month at the Copper Lane hall, 7 pm.
""")

plant("toolshare/docs/treasurer.md", """\
# Treasurer's notes

Each invoice is numbered INV-YYYY-NNN in the order it is raised.

## 2026

- INV-2026-013: Copper Lane hall, room hire for the spring, 120.00, paid 4 April.
- INV-2026-014: Fennick Hardware, new hose for the pressure washer, 23.50, paid 12 October.
- INV-2026-015: printing of the autumn leaflet, 41.00, unpaid.
""")

plant("toolshare/docs/repairs.md", """\
# Repairs

- Pressure washer (TS-017): out of order until the new hose arrives.
- Hedge trimmer (TS-022): blade sharpened, back in use.
- Cordless drill (TS-008): holds charge for ten minutes only; a new pack is on order.
""")

plant("toolshare/docs/issues.md", """\
# Known issues

## 31: overdue reminders sent twice

Reported 2 May. The overdue reminder email went out twice when a loan was extended. Fixed, see the changelog.

## 34: search box ignores accents

Open. A search for "cafe" does not find the Cafe Corner drop-off point.
""")

plant("toolshare/CHANGELOG.md", """\
# Changelog

## v2.3.1 (2026-05-04)

- Fix: reminders were sent twice after a loan was extended (issue 31).

## v2.3.0 (2026-04-12)

- New: the loans page shows the deposit taken.
- New: volunteers can mark a tool as being repaired.

## v2.2.0 (2026-01-20)

- New: borrowers get a receipt by email.
""")

plant("toolshare/src/reminders.py", '''\
"""Overdue reminders for the Harrowdean Tool Share.

Runs once a day; emails each borrower whose loan is past its due date.
"""

from datetime import date

from models import Loan, send_email

GRACE_DAYS = 1


def send_overdue_reminder(loan: Loan, today: date | None = None) -> bool:
    """Email one borrower about one overdue loan, once per extension."""
    today = today or date.today()
    if (today - loan.due).days < GRACE_DAYS:
        return False
    if loan.reminded_for == loan.extension:
        return False
    send_email(loan.borrower, f"Please bring back {loan.tool_name}.")
    loan.reminded_for = loan.extension
    return True
''')

plant("toolshare/src/app.py", '''\
"""The Tool Share web app: loans, returns and the tool list."""

import yaml

with open("config/server.yaml", encoding="utf-8") as handle:
    config = yaml.safe_load(handle)

PORT = config["server"]["port"]
HOST = config["server"].get("host", "127.0.0.1")


def main() -> None:
    from server import serve
    serve(HOST, PORT)


if __name__ == "__main__":
    main()
''')

plant("toolshare/src/models.py", '''\
"""Plain records for tools, borrowers and loans."""

from dataclasses import dataclass
from datetime import date


@dataclass
class Loan:
    tool_name: str
    borrower: str
    due: date
    extension: int = 0
    reminded_for: int = -1


def send_email(to: str, body: str) -> None:
    print(f"mail to {to}: {body}")
''')

plant("toolshare/config/server.yaml", """\
# Tool Share web server settings
server:
  host: 0.0.0.0
  port: 8086
  workers: 2
mail:
  from: loans@toolshare.invalid
  reminder_hour: 7
""")

plant("toolshare/pyproject.toml", """\
[project]
name = "toolshare"
version = "2.3.1"
requires-python = ">=3.10"
dependencies = ["pyyaml"]
""")

plant("toolshare/Makefile", """\
run:
\tcd src && python3 app.py

test:
\tcd src && python3 -m unittest
""")

plant("toolshare/scripts/backup.sh", """\
#!/bin/sh
# Nightly copy of the loans database to the hall's second disk.
cp data/loans.db /mnt/second/loans-$(date +%F).db
""")

plant("toolshare/site/index.html", """\
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Harrowdean Tool Share</title>
<link rel="stylesheet" href="styles.css">
</head>
<body>
<h1>Harrowdean Tool Share</h1>
<p>Borrow a tool for a week from the Copper Lane hall. Saturdays 10 to 12, Wednesdays 6 to 8.</p>
<p><a href="tools.html">See the tool list</a> or <a href="join.html">join</a>.</p>
<script src="app.js"></script>
</body>
</html>
""")

plant("toolshare/site/join.html", """\
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Join the Tool Share</title></head>
<body>
<h1>Join</h1>
<p>Membership is 10 pounds a year. Bring proof of address to the desk.</p>
</body>
</html>
""")

plant("toolshare/site/app.js", """\
// Highlights the tools that are out on loan in the tool list.
document.querySelectorAll('[data-status="out"]').forEach(function (row) {
  row.classList.add('on-loan');
});
""")

plant("toolshare/site/styles.css", """\
body { font-family: sans-serif; margin: 2rem; }
.on-loan { color: #888; }
""")

plant("toolshare/site/sitemap.xml", """\
<?xml version="1.0" encoding="UTF-8"?>
<urlset>
  <url><loc>https://toolshare.invalid/</loc></url>
  <url><loc>https://toolshare.invalid/tools.html</loc></url>
  <url><loc>https://toolshare.invalid/join.html</loc></url>
</urlset>
""")

plant("toolshare/meetings/agm-2026.md", """\
# 12 March 2026

Present: Ines, Kofi, Tamsin and nine members.
Votes: accounts approved; fees unchanged; a second Saturday opening from May.
""")

plant("toolshare/data/volunteer-rota.csv", "\n".join([
    "date,desk,repairs",
    "2026-11-07,Ines,Kofi",
    "2026-11-14,Tamsin,Kofi",
    "2026-11-21,Ines,Wilf",
    "2026-11-28,Tamsin,Wilf",
]) + "\n")

# --- Tamil ------------------------------------------------------------------

plant("paati/pongal-samayal.md", """\
# பொங்கல் சமையல்

## தேவையான பொருட்கள்

பச்சரிசி ஒரு கோப்பை, பாசிப்பருப்பு அரை கோப்பை, வெல்லம் ஒன்றரை கோப்பை.
நெய் நான்கு கரண்டி, முந்திரி பத்து, ஏலக்காய் மூன்று.

## செய்முறை

அரிசியையும் பருப்பையும் கழுவி, நான்கு கோப்பை தண்ணீரில் வேக வைக்கவும்.
வெல்லத்தைக் கரைத்து வடிகட்டி, வெந்த அரிசியில் சேர்க்கவும்.

## குறிப்பு

தை முதல் நாள் காலையில் புதிய பானையில் பொங்கல் வைப்போம்.
மழை பெய்தால் வீட்டுக்குள்ளே அடுப்பு வைப்போம்.
""")

plant("paati/naatkaatti-2027.md", """\
# 2027 நாட்காட்டி

பொங்கல்: ஜனவரி 14, வியாழன்.
தமிழ்ப் புத்தாண்டு: ஏப்ரல் 14, புதன்.
""")

plant("paati/rasam.md", """\
# ரசம்

பாட்டியின் சமையல் குறிப்பு: ரசம் செய்ய புளி, தக்காளி, மிளகு, சீரகம் தேவை.
புளியை இரண்டு கோப்பை நீரில் கரைத்து, தக்காளியுடன் கொதிக்க வைக்கவும்.
""")

plant("paati/kootu.md", """\
# பூசணிக்காய் கூட்டு

பூசணிக்காய் இருநூறு கிராம், பாசிப்பருப்பு கால் கோப்பை, தேங்காய் துருவல் இரண்டு கரண்டி.
பருப்பை வேக வைத்து, காயுடன் சேர்த்து, தேங்காய் அரைத்து ஊற்றவும்.
""")

plant("paati/chedigal.md", """\
# பாட்டியின் செடிகள்

தோட்டத்தில் கத்தரிக்காயும் வெண்டைக்காயும் நன்றாக வளர்கின்றன.
துளசிச் செடிக்கு காலையில் தண்ணீர் ஊற்ற வேண்டும்.
""")

plant("paati/mira-kaditham.md", """\
# மீராவுக்கு ஒரு கடிதம்

அன்புள்ள மீரா,
நீ பள்ளியில் தமிழ்ப் பாட்டு பாடினாய் என்று கேட்டு மகிழ்ந்தேன்.
அடுத்த முறை வரும்போது முறுக்கு செய்து தருகிறேன்.
""")

plant("paati/தீபாவளி-பட்டியல்.txt", """\
முறுக்கு
அதிரசம்
புதிய உடைகள்
விளக்குகள் இருபது
பட்டாசு வேண்டாம்
""")

# --- Rework 1: older or draft copies that disagree with the current file ------
# Added for the `current-copy` kind. Planted text only, so the RNG draws of the
# filler below (and every file of the first version) are unchanged.

ADDED_IN_REWORK_1 = (
    "home/trips/cornwall-2026-draft.md",
    "archive/lending-rules-2024.md",
    "archive/boiler-2025.md",
    "school/calendar-autumn-draft.md",
    "archive/pickle-2024.md",
    "school/clubs-autumn.md",
)

plant("home/trips/cornwall-2026-draft.md", """\
# Cornwall, half term 2026

## Getting there

Arrive Friday 23 October in the evening; collect the key from the farm shop.

## Accommodation

Two cottages to choose from: Gull Cottage or Heron Barn.
""")

plant("archive/lending-rules-2024.md", """\
# Lending rules

## How long

Tools can be borrowed for up to 14 days.

## Deposits

A refundable deposit of 10 pounds is taken for power tools.
""")

plant("archive/boiler-2025.md", """\
# Boiler

Make: Halvard Combi 28. Installed 2019, in the airing cupboard.

## Service record

- 2024-03-02: serviced by Wenlow Heating, all fine.
- 2025-03-11: serviced by Wenlow Heating, flue seal replaced.

## Next service

Next service due in March 2026.
""")

plant("school/calendar-autumn-draft.md", """\
# School calendar, autumn term 2026 (draft)

## Second half

- 21 November: school photographs
- 15 December: Christmas concert, 6 pm, St Aldric's church
""")

plant("archive/pickle-2024.md", """\
# Pickle

## Food

One scoop in the morning only; a chew in the evening.
""")

# A Markdown table, for the `table` kind: a row found by one column, the answer
# in another. (The other tables of the folder are CSV and TSV, not read today.)
plant("school/clubs-autumn.md", """\
# After-school clubs, autumn term 2026

| Day | Club | Room | Runs it |
| --- | --- | --- | --- |
| Monday | Chess | Library | Mr Okafor |
| Tuesday | Choir | Music room | Ms Brennan |
| Wednesday | Coding | ICT suite | Mrs Duval |
| Thursday | Football | Field | Mr Ashby |
""")

# ---------------------------------------------------------------------------
# Filler, drawn with a seeded RNG from fixed pools.
# ---------------------------------------------------------------------------

WEATHER = [
    "Sunny and cold.", "Grey and mild.", "Rain most of the day.", "Windy; the fence panel rattled.",
    "Frost first thing, bright later.", "Drizzle on and off.", "Warm and still.", "Fog until noon.",
]
JOURNAL = [
    "Walked Pickle round the park before school.",
    "The washing stayed on the rack all day.",
    "Otto read two chapters of his library book.",
    "Mira had a friend round after school.",
    "Pasta for tea; Otto ate the peas for once.",
    "Tamsin worked late at the office.",
    "Idris fixed the squeaky gate.",
    "Paati phoned in the evening and asked about school.",
    "Quiet day at home.",
    "Swept the yard and put the bins out.",
    "Mira practised piano for half an hour.",
    "Long queue at the post office.",
    "Bought stamps and a card for Paati.",
    "Frost on the car windscreen; Idris was late.",
    "Otto lost a glove on the way home.",
    "Did the big shop on Saturday morning.",
    "Tool Share desk in the afternoon; four loans out.",
    "Mira finished her library book and started another.",
    "Early night for everyone.",
    "Played cards after tea.",
    "Cleaned out the fridge.",
    "Otto's tooth came out at breakfast.",
    "Picked up a parcel from the corner shop.",
    "Pickle rolled in something on the walk; bath night.",
]
GARDEN_TASKS = [
    "Weeded the onion bed.", "Turned the compost.", "Watered the pots.", "Nothing done; too wet.",
    "Cut the grass.", "Tied in the sweet peas.", "Picked a handful of raspberries.",
    "Swept leaves off the path.", "Mulched the roses.", "Checked the water butt.",
    "Planted out the lettuces.", "Netted the strawberries.", "Dug over bed 3.",
    "Pricked out the tomato seedlings.", "Raked the lawn.", "Deadheaded the dahlias.",
]
SHOPPING = [
    "milk", "bread", "eggs", "butter", "apples", "bananas", "porridge oats", "rice", "pasta",
    "tinned tomatoes", "onions", "carrots", "potatoes", "cheese", "yoghurt", "tea bags",
    "coffee", "washing-up liquid", "toilet roll", "frozen peas", "chicken thighs", "lemons",
    "cucumber", "peppers", "spinach", "orange juice", "crackers", "jam", "flour", "sugar",
]
MEETING_ITEMS = [
    "Loans this month were up on last month.",
    "The spare key for the hall cupboard is with Kofi.",
    "Volunteers wanted for the Saturday desk.",
    "New shelving for the garden tools is agreed.",
    "The leaflet goes to the printer next week.",
    "Two tools came back damaged; the borrowers paid for the parts.",
    "Kofi reported the bank balance; no concerns.",
    "The hall rent rises in the new year.",
    "A school asked to borrow tools for a garden day.",
    "The sign-in book is nearly full; buy a new one.",
    "Tea and biscuits money is short again.",
    "The tool list on the website is out of date.",
]
LOG_EVENTS = [
    "INFO request GET /tools.html 200",
    "INFO request GET / 200",
    "INFO loan created",
    "INFO loan returned",
    "INFO reminder run: 0 sent",
    "INFO reminder run: 2 sent",
    "WARN slow request GET /loans 1.8 s",
    "INFO request POST /join 302",
    "INFO nightly copy done",
]
TOOLS = [
    "hammer drill", "jigsaw", "orbital sander", "spirit level", "stud finder", "tile cutter",
    "wallpaper steamer", "garden fork", "spade", "loppers", "wheelbarrow", "leaf blower",
    "socket set", "pipe wrench", "staple gun", "glue gun", "mitre saw", "circular saw",
    "workbench", "sash clamps", "carpet cleaner", "paint sprayer", "angle grinder",
    "router table", "bolt cutters", "post hole digger", "tree pruner", "hedge shears",
    "edging iron", "lawn aerator", "cement mixer", "trolley jack", "multimeter",
    "soldering iron", "heat gun", "sewing machine", "dehumidifier unit", "tent",
]
SHELVES = ["A1", "A2", "A3", "B1", "B2", "B3", "C1", "C2", "C3", "D1", "D2"]
DISHES = [
    ("Tomato soup", ["tomatoes", "onion", "stock", "basil"]),
    ("Pancakes", ["flour", "eggs", "milk", "butter"]),
    ("Fish pie", ["white fish", "potatoes", "milk", "peas"]),
    ("Vegetable curry", ["potatoes", "cauliflower", "coconut milk", "curry paste"]),
    ("Shepherd's pie", ["lamb mince", "carrots", "potatoes", "stock"]),
    ("Banana bread", ["bananas", "flour", "sugar", "eggs"]),
    ("Leek and potato soup", ["leeks", "potatoes", "stock", "cream"]),
    ("Egg fried rice", ["rice", "eggs", "spring onions", "soy sauce"]),
    ("Apple cake", ["apples", "flour", "butter", "cinnamon"]),
    ("Chickpea stew", ["chickpeas", "tomatoes", "spinach", "cumin"]),
    ("Flapjacks", ["oats", "butter", "golden syrup", "sugar"]),
    ("Macaroni cheese", ["macaroni", "cheese", "milk", "mustard"]),
    ("Carrot salad", ["carrots", "raisins", "lemon", "sesame seeds"]),
    ("Scones", ["flour", "butter", "milk", "sultanas"]),
]
METHOD_STEPS = [
    "Heat the oven first.", "Chop everything before you start.", "Stir now and then.",
    "Taste and add salt at the end.", "Leave it to cool before slicing.",
    "Serve warm.", "It keeps two days in the fridge.", "Double it for guests.",
]
SPELLING_WORDS = [
    "because", "different", "favourite", "island", "knowledge", "library", "minute",
    "naughty", "ordinary", "particular", "peculiar", "question", "remember", "sentence",
    "separate", "special", "straight", "strength", "suppose", "surprise", "therefore",
    "though", "through", "various", "weight", "woman", "women", "answer", "appear",
    "arrive", "believe", "bicycle", "breath", "breathe", "build", "busy", "calendar",
    "caught", "centre", "century", "certain", "circle", "complete", "consider",
]
ONE_LINERS = [
    "Call the school about Otto's coat.",
    "Library books due back Friday.",
    "Ask Kofi for the hall cupboard key.",
    "Paint colour for the hall: Pale Oat, two tins.",
    "Mira's sketchbook is A4, not A5.",
    "Meter read in the morning.",
    "Order more printer paper.",
    "Wilf can do the Saturday desk on the 21st.",
    "Picture hooks are in the second kitchen drawer.",
    "Return the cake tin to next door.",
    "The bike pump lives in the shed now.",
    "Spare bulbs: bayonet, 60 W equivalent.",
]
HANDBOOK_TOPICS = [
    "Opening the hall", "Signing in", "Checking a tool out", "Taking a tool back",
    "Cleaning returns", "Charging batteries overnight", "Locking up", "First aid box",
    "Lost property", "Talking to new members", "When a tool is broken", "Cash box",
    "Leaflets and posters", "The tool list", "Safety talk for power tools",
    "Children at the desk", "Parking", "Fire exits", "Keys", "Year-end stocktake",
]
HANDBOOK_SENTENCES = [
    "Two volunteers are on the desk at all times.",
    "Write each loan in the book as well as on the laptop.",
    "Check the tool works before it goes out.",
    "If in doubt, ask the chair.",
    "Wipe the handles with a cloth before a tool goes back on the shelf.",
    "Power tools go out with their case and the manual.",
    "Members show their card at the desk.",
    "Put returned tools on the trolley, not straight on the shelf.",
    "Note any damage in the book with the date.",
    "The last volunteer out turns off the lights and the heater.",
]


def journal_files(rng: random.Random) -> dict[str, str]:
    out = {}
    day = datetime.date(2026, 1, 3)
    while day <= datetime.date(2026, 11, 20):
        lines = [f"# {day.strftime('%A')} {day.day} {day.strftime('%B %Y')}", "", rng.choice(WEATHER)]
        lines += rng.sample(JOURNAL, rng.randint(2, 5))
        out[f"journal/{day.isoformat()}.md"] = "\n".join(lines) + "\n"
        day += datetime.timedelta(days=rng.choice([3, 4, 4, 5]))
    return out


def garden_diary(rng: random.Random) -> str:
    planted = {
        datetime.date(2025, 3, 8): "Sowed the first broad beans in bed 2, two rows.",
        datetime.date(2025, 6, 21): "Picked the first broad beans; a colander full.",
        datetime.date(2025, 9, 12): "Hedgehog seen under the compost bin at dusk.",
    }
    lines = ["Garden diary 2025, 14 Copper Lane.",
             "One entry a day: the date, the weather and what was done.", ""]
    day = datetime.date(2025, 1, 1)
    while day.year == 2025:
        lines.append(f"{day.isoformat()} {day.strftime('%a')}")
        lines.append(f"  weather: {rng.choice(WEATHER).rstrip('.').lower()}, {rng.randint(-2, 26)}C")
        lines.append("  " + planted.get(day, rng.choice(GARDEN_TASKS)))
        lines.append("")
        day += datetime.timedelta(days=1)
    return "\n".join(lines)


def shopping_lists(rng: random.Random) -> dict[str, str]:
    out = {}
    for week in range(1, 47, 2):
        items = rng.sample(SHOPPING, rng.randint(6, 12))
        out[f"home/lists/shopping-2026-w{week:02d}.txt"] = "\n".join(items) + "\n"
    return out


def meetings(rng: random.Random) -> dict[str, str]:
    out = {}
    for month in range(1, 12):
        if month == 3:
            continue  # March was the AGM (planted)
        first = datetime.date(2026, month, 1)
        tuesday = first + datetime.timedelta(days=(1 - first.weekday()) % 7)
        lines = [f"# Committee meeting, {tuesday.day} {tuesday.strftime('%B %Y')}", "",
                 "Present: Ines, Kofi, Tamsin" + rng.choice(["", ", Wilf", ", Wilf, Odile"]) + ".", "",
                 "## Notes", ""]
        lines += ["- " + item for item in rng.sample(MEETING_ITEMS, rng.randint(3, 5))]
        lines += ["", "## Next meeting", "", "Same place, same time."]
        out[f"toolshare/meetings/2026-{month:02d}-committee.md"] = "\n".join(lines) + "\n"
    return out


def server_logs(rng: random.Random) -> dict[str, str]:
    out = {}
    for month in range(1, 13):
        lines = []
        for day in range(1, 29):
            for _ in range(rng.randint(2, 4)):
                stamp = f"2026-{month:02d}-{day:02d} {rng.randint(0, 23):02d}:{rng.randint(0, 59):02d}:{rng.randint(0, 59):02d}"
                lines.append(f"{stamp} {rng.choice(LOG_EVENTS)}")
            if month == 6 and day == 17:
                lines.append("2026-06-17 03:12:44 ERROR backup failed: disk quota exceeded on the second disk")
        out[f"toolshare/logs/server-2026-{month:02d}.log"] = "\n".join(lines) + "\n"
    for month in range(1, 7):
        lines = [f"Desk visits, 2026-{month:02d}"]
        for day in range(1, 29, 3):
            lines.append(f"2026-{month:02d}-{day:02d}: {rng.randint(3, 19)} visits, {rng.randint(1, 9)} loans")
        out[f"toolshare/logs/desk-2026-{month:02d}.txt"] = "\n".join(lines) + "\n"
    return out


def inventory(rng: random.Random) -> tuple[str, str]:
    planted = {
        8: ("cordless drill", "A2"),
        17: ("pressure washer", "C1"),
        22: ("hedge trimmer", "C2"),
        30: ("ladder (3-section)", "outside rack"),
        41: ("lawnmower (electric)", "B3"),
    }
    tools = list(TOOLS)
    rng.shuffle(tools)
    yaml_lines = ["# Harrowdean Tool Share inventory: every tool, its id and its shelf.",
                  "# Kept by the volunteers; one entry per tool.", "tools:"]
    csv_lines = ["id,tool,loans_2026"]
    pool = iter(tools)
    for number in range(1, 44):
        name, shelf = planted.get(number) or (next(pool), rng.choice(SHELVES))
        ident = f"TS-{number:03d}"
        yaml_lines += [f"  - id: {ident}", f"    name: {name}", f"    shelf: {shelf}"]
        csv_lines.append(f"{ident},{name},{rng.randint(0, 30)}")
    return "\n".join(yaml_lines) + "\n", "\n".join(csv_lines) + "\n"


def recipes(rng: random.Random) -> dict[str, str]:
    out = {}
    for title, ingredients in DISHES:
        slug = title.lower().replace("'", "").replace(" ", "-")
        lines = [f"# {title}", "", "## Ingredients", ""]
        lines += [f"- {rng.choice(['1', '2', '200 g', '300 g', 'a handful of', '500 ml'])} {item}" for item in ingredients]
        lines += ["", "## Method", ""]
        lines += [f"{i}. {step}" for i, step in enumerate(rng.sample(METHOD_STEPS, 3), 1)]
        out[f"home/recipes/{slug}.md"] = "\n".join(lines) + "\n"
    return out


def spelling(rng: random.Random) -> dict[str, str]:
    out = {}
    for week in range(1, 13):
        words = rng.sample(SPELLING_WORDS, 8)
        out[f"school/spelling/week-{week:02d}.txt"] = f"Spelling, week {week}\n" + "\n".join(words) + "\n"
    return out


def reading_log(rng: random.Random) -> str:
    books = ["The Lantern Fox", "Owl Hill", "Captain Pudding", "The Salt Road", "Twelve Kites",
             "A Boat Called Plum", "The Clockmaker's Cat", "Under the Pier"]
    lines = ["Reading log, Otto, 2026"]
    day = datetime.date(2026, 1, 5)
    while day <= datetime.date(2026, 11, 13):
        lines.append(f"{day.isoformat()}  {rng.choice(books)}, pages {rng.randint(1, 60)} to {rng.randint(61, 120)}")
        day += datetime.timedelta(days=2)
    return "\n".join(lines) + "\n"


def handbook(rng: random.Random) -> str:
    lines = ["# Volunteer handbook", "", "Everything a new desk volunteer needs, section by section.", ""]
    for topic in HANDBOOK_TOPICS:
        lines += [f"## {topic}", ""]
        for _ in range(rng.randint(2, 4)):
            lines.append(" ".join(rng.sample(HANDBOOK_SENTENCES, rng.randint(2, 4))))
            lines.append("")
    return "\n".join(lines)


def one_liners() -> dict[str, str]:
    return {f"inbox/note-{i + 1:02d}.txt": line + "\n" for i, line in enumerate(ONE_LINERS)}


def smart_plugs() -> str:
    return """{
  "plugs": [
    {"name": "hall lamp", "on": "17:30", "off": "23:00"},
    {"name": "fish tank light", "on": "08:00", "off": "20:00"},
    {"name": "front room heater", "on": null, "off": null}
  ]
}
"""


def loans_summary(rng: random.Random) -> str:
    rows = [f'    {{"month": "2026-{m:02d}", "loans": {rng.randint(20, 60)}, "late": {rng.randint(0, 6)}}}'
            for m in range(1, 11)]
    return '{\n  "summary": [\n' + ",\n".join(rows) + "\n  ]\n}\n"


def build_corpus(seed: int = SEED) -> dict[str, bytes]:
    """Every file of the folder, path -> bytes, sorted by path."""
    rng = random.Random(seed)
    files: dict[str, str] = dict(PLANTED)

    def add(path: str, text: str) -> None:
        assert path not in files, path
        files[path] = text

    for group in (journal_files(rng), shopping_lists(rng), meetings(rng), server_logs(rng),
                  recipes(rng), spelling(rng), one_liners()):
        for path, text in group.items():
            add(path, text)
    add("home/garden/garden-diary-2025.txt", garden_diary(rng))
    yaml_text, csv_text = inventory(rng)
    add("toolshare/data/inventory.yaml", yaml_text)
    add("toolshare/data/loans-2026.csv", csv_text)
    add("school/reading-log.txt", reading_log(rng))
    add("toolshare/docs/handbook.md", handbook(rng))
    add("home/house/smart-plugs.json", smart_plugs())
    add("toolshare/data/loans-summary.json", loans_summary(rng))
    # Near duplicate of a generated list: one item changed.
    first = files["home/lists/shopping-2026-w01.txt"]
    add("archive/shopping-2026-w01-copy.txt", first.replace(first.splitlines()[0], "oat milk", 1))
    return {path: files[path].encode("utf-8") for path in sorted(files)}


def corpus_digest(corpus: dict[str, bytes]) -> str:
    h = hashlib.sha256()
    for path in sorted(corpus):
        h.update(path.encode("utf-8") + b"\0" + corpus[path] + b"\0")
    return h.hexdigest()


def write_corpus(out_dir: Path, seed: int = SEED) -> dict[str, bytes]:
    out_dir = Path(out_dir)
    if out_dir.exists() and any(out_dir.iterdir()):
        raise SystemExit(f"refusing to write into a folder that is not empty: {out_dir}")
    corpus = build_corpus(seed)
    for path, data in corpus.items():
        target = out_dir / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    return corpus


def main(argv: list[str]) -> int:
    if argv == ["--digest"]:
        corpus = build_corpus()
        print(f"files={len(corpus)} bytes={sum(map(len, corpus.values()))} corpus_sha256={corpus_digest(corpus)}")
        return 0
    if len(argv) != 1 or argv[0].startswith("-"):
        print(__doc__.split("Usage:")[1], file=sys.stderr)
        return 2
    corpus = write_corpus(Path(argv[0]))
    print(f"wrote {len(corpus)} files, {sum(map(len, corpus.values()))} bytes, corpus_sha256={corpus_digest(corpus)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
