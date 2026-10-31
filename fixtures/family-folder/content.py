"""Invented content for the family-folder fixture (S3-T7).

Every person, school and place here is made up. Text is plain data: generate.py
turns it into files and computes the judgments from it.
"""

from __future__ import annotations

FILES: dict[str, str] = {}

# ---------------------------------------------------------------- school ----

FILES["school/notes.md"] = """\
---
title: Class notes
teacher: Ms Orrin
term: autumn
---

# Class notes

Notes from the weekly letters, kept by Noor for Tavi and Mira.

## Week 6

### Reading

- Finish the chapter about the lighthouse by Thursday.
- Return the library book on Monday.

### Dates

- Swimming kit on Tuesday.
- Photo day is moved to the following week.

## Week 7

### Spelling

Ms Orrin said the spelling test next week will cover the twenty words on
the green sheet. She will read each word twice and give a sentence.
Practise the tricky ones: necessary, separate, island.

### Dates

- Band concert: Friday 6 in the school hall, doors at five. Tell Ms Orrin to count
  me in if you can help with the chairs.
- Parents' tea after the concert in the dining room.
- Maths quiz on Wednesday, times tables up to twelve.

### Homework

- Read for twenty minutes each night.
- Draw the water cycle in the science book.
"""

FILES["school/science-notes.md"] = """\
---
title: Science notes
class: year four
topic: plants and light
---

Science notes
=============

Notes from the plants unit, copied from the board and tidied at home.

How plants make food
--------------------

### Photosynthesis in one line

Plants use light, water and air to make their own food. The big word for
this is photosynthesis. It happens mostly in the leaves.

### What the leaf does

1. Water travels up from the roots through thin tubes in the stem.
2. Air enters through tiny holes underneath the leaf.
3. Sunlight is caught by the green stuff inside the leaf.
4. The plant makes sugar and lets out fresh air.

### Words to remember

- chlorophyll: the green stuff that catches light
- stem: carries water upward
- root: holds the plant and drinks
- stoma: a tiny hole in a leaf

The parts of a flower
---------------------

### Petals and sepals

Petals are bright to attract bees. Sepals are the small green leaves that
protect the bud before it opens.

### Stamen and carpel

The stamen makes pollen. The carpel holds the seeds-to-be. Bees carry
pollen from one flower to the next.

### Questions for Friday

- Why are leaves flat?
- What would happen to a plant kept in a dark cupboard?
- Which part of the flower becomes the fruit?

## Experiments

### The cress test

We grew cress on wet paper in three places: the windowsill, the shelf and
the dark cupboard. After five days the windowsill cress was tall and green.
The cupboard cress was pale and floppy. The shelf cress was in between.

### The celery test

We stood white celery in water with blue colouring. By the next morning
the blue had climbed the stem and reached the leaves. This shows how
water moves upward.

## Vocabulary list

- absorb
- nutrient
- germinate
- seedling
- pollinate
- transparent
"""

FILES["school/spelling-lists.md"] = """\
Spelling lists
==============

Week 6
------

1. believe
2. receive
3. friend
4. weight
5. height

Week 7
------

The test covers these twenty words. Spelling counts for the star chart.

1. necessary
2. separate
3. island
4. peculiar
5. calendar
6. library
7. february
8. definite
9. rhythm
10. guarantee

Week 8
------

To be sent home on Monday.
"""

FILES["school/newsletter-oct.md"] = """\
---
title: October newsletter
sender: Larkfield Primary office
---

# Larkfield Primary newsletter

## Coming up

- Band concert: Friday 6 in the school hall, doors at five.
- Book fair in the library all week.
- Harvest assembly for year four on Thursday.

## Reminders

Please label coats and water bottles. Lost property is emptied at the end
of each half term.

## Clubs

Chess club moves to Wednesday lunchtime. Art club is full; ask Mr Pell
about the waiting list.
"""

FILES["school/pickup-rules.md"] = """\
# Pick-up and drop-off

## Morning

Gates open at ten to nine. Drop-off is at the side gate. Children walk in
by themselves from the red line.

## Afternoon pick-up

Year four is collected from the playground. Please wait by the oak tree
until the bell.

## Lost property

Lost property is kept in the blue box by the office.
"""

FILES["school/supplies.md"] = """\
# Supplies

## Every day

- water bottle
- reading book
- pencil case with two pencils

## Art

- old shirt
- a clean jar for brushes
- one cardboard box, any size

## Rooms

The art table is the long one by the window. Do not move it.
"""

FILES["school/timetable.md"] = """\
# Year four timetable

## Monday

- Maths
- Reading
- Games

## Tuesday

- Swimming
- Science
- Art

## Wednesday

- Maths quiz
- Chess club at lunch
- Music

## Thursday

- Harvest assembly
- Writing
- Computing

## Friday

- Spelling test
- Band practice
- Golden time
"""

FILES["school/trip-permission.md"] = """\
---
title: Trip permission
destination: Greyrock Farm
---

# Trip permission slip

The class visits Greyrock Farm in the spring. Please return the permission
slip with five pounds for the bus.

## What to bring

- packed lunch in a bag that can be thrown away
- wellington boots
- a raincoat, even if it looks sunny

## Medicines

Tell Ms Orrin about any allergies before the trip.
"""

FILES["school/reading-log.md"] = """\
# Reading log

## Tavi

- The Lighthouse Cat: finished, liked the storm chapter
- Tales from Mossbank: started

## Mira

- Moon Garden: nearly finished
- A Field Guide to Puddles: read it twice
"""

FILES["school/maths-facts.md"] = """\
# Maths facts

## Times table practice

Learn the nines with fingers: put down the finger for the number you are
multiplying, and read the tens on the left and the ones on the right.

## Sevens

- 7 x 6 = 42
- 7 x 7 = 49
- 7 x 8 = 56

## Fractions

A half is two quarters. A quarter is two eighths.
"""

FILES["school/geography-coast.md"] = """\
---
title: The coast project
class: year four
---

# The coast project

## Tides

The sea comes in and goes out twice a day. The tide table in the
harbour office lists high and low water for every day of the month.

### Reading a tide table

Each row has a day, a time for high water and a time for low water. The
heights are in metres. A spring tide is the biggest of the month.

## Harbour words

- quay: where boats tie up
- breakwater: a wall that stops waves
- buoy: a floating marker

## Rockpools

Look for limpets, barnacles and anemones. Put every animal back where you
found it.
"""

FILES["school/lunch-menu.md"] = """\
# Lunch menu

## Week one

- Monday: pasta bake
- Tuesday: fish fingers
- Wednesday: roast chicken
- Thursday: vegetable curry
- Friday: pizza

## Week two

- Monday: shepherd's pie
- Tuesday: jacket potato
"""

FILES["school/art-club.md"] = """\
# Art club

Art club meets on Mondays after school in room six. This term the group
makes clay lanterns.

## Sign-up

Ask Mr Pell for a form. The club is full, but the waiting list is open.
"""

FILES["school/homework-routine.txt"] = """\
Homework routine

Monday: maths sheet
Tuesday: reading and one page of spelling practice
Wednesday: no homework, chess club
Thursday: science drawing
Friday: nothing. Rest.

Tip from Ms Orrin: spelling practice works best in short bursts.
"""

FILES["school/contacts.txt"] = """\
School office: open from eight to four.
Class teacher: Ms Orrin
Art club: Mr Pell
Caretaker: Mrs Dunmore (for lost property)
"""

# ------------------------------------------------------------------ home ----

FILES["home/recipes/bread.md"] = """\
---
title: Weekend bread
serves: one loaf
---

# Weekend bread

## Ingredients

- 500 g strong flour
- 7 g salt
- 7 g dried yeast
- 320 ml warm water

## Method

1. Mix the flour, salt and yeast in a big bowl.
2. Pour in the water and stir until it comes together.
3. Knead for ten minutes, then cover the bowl and wait until the dough rests and doubles in size.
4. Tip it out, shape it into a round and slash the top with a knife.
5. Bake for thirty minutes until it sounds hollow when tapped.

## Notes

Mira likes to add a handful of seeds at step two.
"""

FILES["home/recipes/soup.md"] = """\
# Lentil soup

## Ingredients

- 1 cup red lentils
- 1 onion
- 2 carrots
- stock

## Method

Soften the onion, add the carrots and lentils, cover with stock and simmer
for twenty minutes. Blend if the children prefer it smooth.
"""

FILES["home/recipes/pancakes.md"] = """\
# Pancakes

## Batter

Whisk one egg with a cup of flour and a cup of milk. The batter rests for
fifteen minutes while the pan heats.

## Tossing

Practice with a spare one first.
"""

FILES["home/trips/seaside-weekend.md"] = """\
---
title: Seaside weekend
place: Gullcove
---

# Seaside weekend

## Plan

- Leave after breakfast on Saturday.
- Check the tide table at the harbour before choosing a beach.
- Fish and chips at the quay.

## Packing

- towels
- a bucket
- sun cream
- the good camera

## Rockpooling

Low water is the time for rockpools. Take a field guide, a small net and
a tub with a lid. Photograph the animals, then put them back.
"""

FILES["home/garden.md"] = """\
# Garden

## Pond

The little pond by the shed has frogs and a family of snails. In spring
there is frogspawn. We put a plank in so hedgehogs can climb out.

## Vegetables

- beans along the fence
- potatoes in the tall bag
- lettuce in the shade

## Sunshine

Even the shady corner gets enough light for ferns. The beans need the
sun, since their leaves do photosynthesis all day.
"""

FILES["home/budget-notes.md"] = """\
# Budget notes

## Monthly

- Rent and bills come first.
- Groceries: set a weekly limit.
- Pocket money on Fridays.

## Savings

Aim for one small treat a month and one bigger goal a year.
"""

FILES["home/house-rules.md"] = """\
# House rules

## Mornings

- Beds made before breakfast.
- Shoes by the door.

## Evenings

- Screens off at eight.
- Everyone helps clear the table.
- Reading in bed until half past eight.

## Quiet hours

After nine the house is quiet.
"""

FILES["home/birthday-plans.md"] = """\
---
title: Birthday plans
who: Mira
---

# Birthday plans

## Guest list

- cousins
- friends from the swimming club
- Grandpa Anbu, who says count me in for the cake

## Food

A lemon cake and sandwiches cut into triangles.

## Games

Treasure hunt around the garden, with clues hidden under flowerpots.
"""

FILES["home/chores.md"] = """\
# Chores

## Daily

- feed the cat
- water the plants

## Weekly

- bins on Thursday
- change the bed sheets on Saturday
"""

FILES["home/tamil-notes.md"] = """\
# தமிழ் குறிப்புகள்

## பள்ளி

பள்ளி விடுமுறை வெள்ளிக்கிழமை தொடங்குகிறது.
கணிதம் வீட்டுப்பாடம் முடிக்க வேண்டும்.

## வீடு

அம்மா சமையலறையில் ரொட்டி செய்கிறார்.
நாளை நூலகத்திற்குச் செல்வோம்.

## கடற்கரை

கடற்கரைக்கு ஞாயிற்றுக்கிழமை செல்லலாம்; அலை அட்டவணை பார்க்கவும்.
பள்ளி விடுமுறை முடிந்ததும் மீண்டும் செல்வோம்.
"""

FILES["home/repeated-tokens.md"] = """\
# Repeated words

Typing slips collected by the proofreading club.

## Slips

- Remember to bring the the permission slip.
- We went to to the park.
- This is is a test of the the system.

## Fixed

Remember to bring the permission slip.
"""

FILES["home/no-final-newline.txt"] = (
    "Packing list for the picnic\n"
    "blanket\n"
    "apples\n"
    "a kite that has seen better days"
)

FILES["home/empty.txt"] = ""

FILES["home/bills.txt"] = """\
Electricity: pay on the first.
Water: pay on the fifteenth.
Internet: automatic.
"""

# CRLF file: written with Windows line endings by generate.py.
CRLF_FILES = {
    "home/crlf-shopping.md": """\
---
title: Shopping list
list: weekly
---

# Shopping list

## Fruit and vegetables

- apples
- carrots
- bananas

## Baking

1. flour
2. yeast
3. seeds

## Treats

- clementines
"""
}

# BOM file: written with a UTF-8 byte order mark by generate.py.
BOM_FILES = {
    "home/bom-checklist.md": """\
---
title: Moving-day checklist
---

# Moving-day checklist

## Before

- label the boxes
- tell the school office

## After

- find the kettle
- find the tea
"""
}

# ---------------------------------------------------------------- laptop ----

FILES["laptop/project-ideas.md"] = """\
---
title: Project ideas
owner: Dev
---

# Project ideas

Things the family might build over the winter.

## Robot club

A small rover that follows a line on the floor.

- Parts: two motors, a battery pack, a light sensor
- First goal: drive in a square

### Software

Start with a loop that reads the sensor and turns left or right.

## Garden camera

A camera that photographs the vegetable bed each morning.

### Parts

- an old phone
- a weatherproof box

## Weather station

Measure rain, wind and temperature, and plot a week at a time.

## Reading app

A page that keeps track of what each child has read.
"""

FILES["laptop/photosynthesis-draft.md"] = """\
---
title: Photosynthesis explainer draft
status: draft
---

# Photosynthesis explainer

A short page for the school fair stall.

## Big idea

Photosynthesis lets plants turn light into sugar.

## Demonstration

Float a leaf disc in water. When it rises, the leaf has made bubbles of
air. Photosynthetic cells do this when the light is bright.

## Questions

- What does a plant need?
- Where does the air come from?
"""

FILES["laptop/meeting-notes.md"] = """\
# Family meeting

## Agenda

- weekend plans
- who cooks on Thursday

## Decisions

Dev says count me in for the Saturday trip. Noor will check the tide table
and book the car.

### Snippet kept for later

```sh
echo "pack the bags"
```
"""

FILES["laptop/reading-notes.md"] = """\
# Reading notes

## The Lighthouse Cat

A cat guards a lighthouse through a long winter. Tavi's favourite part is
the storm chapter.

## Tales from Mossbank

Short stories about a village by a marsh.
"""

FILES["laptop/archive/house-rules-old.md"] = FILES["home/house-rules.md"]

FILES["laptop/reports/term-summary.md"] = """\
# Term summary

## Tavi

Working well in maths. Reading is a strength. Spelling needs steady practice.

## Mira

Confident in science. Enjoys art club.
"""

FILES["laptop/ideas/robot-club.md"] = """\
# Robot club

## Meeting times

Wednesdays at lunch in the computing room.

## Kit list

- laptop
- screwdriver
- two AA batteries
"""

FILES["laptop/todo.txt"] = """\
Print the permission slip.
Back up the photos.
Write the spelling list on cards.
"""

# The long fenced block (over 1,600 codepoints) lives in maths-script.md; generate.py
# builds the body so the text stays deterministic and the length is checked there.
MATHS_SCRIPT_HEAD = """\
# Maths script

A small program that prints times tables for the children.

## Headings inside code are not headings

The block below contains lines that begin with a hash sign. They are
comments, not headings.

## The program

"""

MATHS_SCRIPT_TAIL = """\

## Notes

Run it with a number between two and twelve.

### Next step

Add a quiz mode.
"""
