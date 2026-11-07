"""Invented content for the J2 judged fixture (S5-T1).

Every person, school, town and place here is made up: the Varnell family of
Thistlecombe (Maren, Joss, Pip in Year 5, Wren in Year 2, Paati their
grandmother, Biscuit the dog), Thistlecombe Primary (Mr Quarrie, Ms Lune), Mill
Lane, Mill Field, Hollow Woods, the Toy Museum. Phone numbers are from the
ranges set aside for drama. Text is plain data: generate.py turns it into files
and computes the judgments from it; queries.py holds the judged queries.

Words that a judged query must miss are kept out of the files on purpose (see
the `checks` in queries.py, asserted by generate.py): edit a file here and run
the generator; it stops if a check no longer holds.
"""

from __future__ import annotations

import datetime

FILES: dict[str, str] = {}
CRLF_FILES: dict[str, str] = {}
BOM_FILES: dict[str, str] = {}
NO_FINAL_NEWLINE: dict[str, str] = {}

# ---------------------------------------------------------------- school ----

FILES["school/science-homework.md"] = """\
---
title: Bean diary
class: Year 5
---

# Bean diary

Mr Quarrie wants a diary of one bean, from seed to plant. This is the science
part of the term, and the diary goes back on the last Friday before the break.

## Planting day

We put a bean in a jar with wet kitchen roll. Pip chose the fattest bean.
Wren is planting a bean too, in a yoghurt pot on the windowsill.

## Measuring

Every two days, measure the height of the shoot with a ruler and write it in
the table in millimetres. Start from the top of the seed and go to the tip of
the shoot. If the shoot bends, lay a piece of string along it and then measure
the string. Draw the leaves when they open and count them.

## What we noticed

- Day 2: the skin split and a white root came out.
- Day 4: the root went down even when we turned the jar.
- Day 6: a green shoot came up towards the window.
- Day 8: two leaves opened.

## Questions to answer

1. Why does the root grow down?
2. Why does the shoot lean towards the light?
3. What would happen without water?
"""

FILES["school/maths-homework.md"] = """\
# Fractions sheet

## This week

Pip's sheet for this week is on fractions: halves, quarters and eighths of
shapes and of numbers. Colour the shapes first, then do the number questions.
Show the working in the box under each question. It goes back on Wednesday.

## Tips from Mr Quarrie

- A fraction is a part of a whole.
- The bottom number says how many equal parts there are.
- The top number says how many parts we take.
- From the maths book, page 14.

## Answers to check

1. Half of 20 is 10.
2. A quarter of 20 is 5.
3. Three quarters of 20 is 15.
"""

FILES["school/newsletter-autumn.md"] = """\
# Thistlecombe Primary autumn newsletter

News for families from the head teacher's office.

## Homework club

Homework club helps with science homework and maths homework on Thursdays.

## Swimming

Swimming lessons start for Year 2 this term.

## Uniform

School uniform: please label every jumper. Spare uniform is in the office.

## Reading list

The winter reading list is on the noticeboard.

## Staff news

We welcome two new teachers to Year 3 and Year 6.

## Science week

Science week ends with a volcano demo in the hall.

## Noe\u0308l carol concert

The Noe\u0308l carol concert is on Wednesday 17 December at six. Every class
sings one carol and the choir sings three. Tickets are free; seats are not
saved, so come early.

## Band

The band concert is in March. Instruments go home over the break.

## Clubs

The chess club meets after lunch on Mondays. Every school day there is a
club of some kind, so ask at the office.

## Lost property

The lost property box is by the hall doors. Unnamed coats go to the charity
bag at the end of each month.

## Parking

Please do not park on the zigzag lines at the gate. The car park at the
church is free before nine.

## Dates for the diary

- Photo day: Tuesday 25 November.
- Christmas jumper day: Friday 12 December.
- Last day of term: Friday 19 December, finish at two.
"""

FILES["school/class-notes-pip.md"] = """\
---
title: Year 5 class notes
teacher: Mr Quarrie
---

# Year 5 class notes

Notes from Mr Quarrie's weekly letters, kept by Maren.

## Week 6

- Bring a named water bottle every day.
- Class assembly practice on Thursday.

## Week 7

- Times for parents' evening go out on Monday.
- Bring a cardboard tube for the art table.

## Week 8

- Return the library book by Monday; it is due back then.
- New class reader handed out on Tuesday.

## Spelling

The spelling test is every Friday. Ten words from the sheet, and Mr Quarrie
reads each one twice.

## Week 9

- Volcano model due soon: keep working on it at home.
- Our classroom moves upstairs next week; the old room becomes the music room.

## Week 10

- Bring a coat on Friday for the outdoor lesson.
- Spare socks in the PE bag, please.
"""

FILES["school/class-notes-wren.md"] = """\
# Year 2 class notes

Notes from Ms Lune's weekly letters.

## Reminders

Swimming kit on Tuesday: costume, towel and goggles in a named bag. Long hair
tied back.

## Phonics

This week's sounds are ai, ee and oa. Practise them with the flash cards.

## Next term

Swimming will resume after the October holiday, at the same time.

## Show and tell

Wren may bring one thing from home on Friday for show and tell.
"""

FILES["school/spelling-lists.md"] = """\
Spelling lists
==============

Lists from Year 5, one per week. Learn them for the test on Friday.

Week 8
------

Spelling words for week 8: island, separate, necessary, early, earth, heard,
height, guard, guide, grammar.

Week 9
------

Spelling words for week 9: knowledge, library, material, medicine, minute,
natural, naughty, notice, occasion, opposite. Week 9 has the hardest ones.

Week 10
-------

Spelling words for week 10: particular, peculiar, perhaps, popular, position,
possess, possession, potatoes, pressure, probably.
"""

FILES["school/volcano-project.md"] = """\
# Volcano project

Pip's project for the Earth and space topic.

## What to make

Make a model volcano from scrunched paper and flour paste on a board. Paint it
brown and grey, then put a small cup in the top for the eruption. The eruption
is bicarbonate of soda and vinegar with a drop of red food colouring.

## Due date

The volcano project is due on Friday 14 November. Due date means the model and
the poster both come in that morning, and the poster names three real kinds of
eruption.

## Poster checklist

- a title
- a labelled diagram: crater, vent, magma chamber, lava
- three facts in your own words
"""

FILES["school/dinosaur-topic.md"] = """\
# Our dinosaur topic

Year 2 learns about the dinosaur age this term. Wren's group made
a timeline along the classroom wall.

## Bones and skeletons

A dinosaur skeleton is put back together from bones found in rock. The museum
team numbers every piece so the bones go back in the right order. Some
skeletons are mostly plaster, made to fill the gaps.

## Teeth

A meat-eating dinosaur had sharp teeth with tiny saw edges. A plant-eating
dinosaur had flat teeth for grinding leaves. Teeth grew again when one fell out.

## Fossils

Fossils are the shapes of living things left in rock. A fossil can be a bone,
a footprint or a leaf. Fossil hunters split rocks along their layers; the
oldest fossils are in the deepest layers.

## Words to learn

skeleton, extinct, layer, rock, footprint, claw
"""

FILES["school/maths-practice.md"] = """\
# Maths practice

Practice ideas for Year 5 from Mr Quarrie.

## Why we learn them

Knowing the multiplication tables by heart makes long division, fractions and
area much quicker. The aim is every fact up to 12 x 12 in under three seconds.

## Times tables test

The times tables test is on Friday mornings. Fifty questions in five minutes,
mixed tables, and the score goes in the reading record.

## Games

- Fizz buzz in the car.
- Snap with multiplication cards.
- Beat the clock on the kitchen timer.
"""

CRLF_FILES["school/trip-permission-museum.md"] = """\
# Toy Museum trip

## About the trip

The Year 5 trip is to the Toy Museum in the old mill. Trip date: Thursday 20
November. The coach leaves at nine and the trip ends back at school at three.
The trip costs nothing; a donation is welcome.

## What to bring

Please bring a packed lunch in a bag with your name on it, a coat and a drink.

## Permission

Sign and return the slip by Monday.
"""

FILES["school/letters/letter-home-oct.txt"] = """\
Thistlecombe Primary
Letter home, October

Dear parents and carers,

Year 5 will go on a \ufb01eld trip to Hollow Woods on Tuesday 18 November.
The day was moved because the \ufb01rst choice clashed with the swimming gala.
Please return the slip to the school of\ufb01ce by Friday.

Children will need wellies, a waterproof coat and a packed lunch. We will
walk the nature trail, look for signs of autumn and make a leaf map.

If you can help on the day, please tell the of\ufb01ce.

With thanks,
Mr Quarrie
"""

FILES["school/lunch-menu.md"] = """\
# School lunch menu

The menu changes every term. A vegetarian choice is served every day.

## Monday

Pasta bake with garden peas. Fruit pot.

## Tuesday

Roast chicken with carrots and gravy. Rice pudding.

## Wednesday

Fish fingers with peas and potato wedges. Yoghurt.

## Thursday

Vegetable curry with rice. Flapjack.

## Friday

Fish and chips with ketchup. Fruit jelly.
"""

FILES["school/german-club.md"] = """\
# German club

Mr Quarrie runs German club on Tuesday lunchtimes.

## Words for spring

Frühling means spring. Grün means green. Die Blume means the flower.

## Street words

Straße means street. Die Ampel means the traffic lights.

## Numbers

eins, zwei, drei, vier, fünf
"""

FILES["school/reading-log-pip.md"] = """\
# Pip's reading log

## Book 1

The Lantern Fox by Della Marsh. The main character is a fox who carries a
lantern for lost travellers. Pages 1 to 80.

## Book 2

Seven Doors Down by Hal Ennis. The main character is a girl who finds a door
in every house on her street. Finished in a week.

## Book 3

The Naive Snail by Ottoline Brack. The snail is a bit naive and believes
everything the crow tells him, until the crow tries to sell him a hat. My
favourite character is the crow, because the crow is funny.

## Reading at home

Twenty minutes of reading every night, signed by a grown-up.
"""

FILES["school/tamil/tamil-class.md"] = """\
# தமிழ் வகுப்பு

Tamil class notes, Saturday mornings in the community hall.

## School time

பள்ளி காலை எட்டரை மணிக்குத் தொடங்கும். நாங்கள் எட்டு மணிக்கு வீட்டிலிருந்து புறப்படுவோம்.

## Library

ஒவ்வொரு வெள்ளிக்கிழமையும் ஒரு புத்தகம் எடுக்கலாம். புத்தகம் ஒரு வாரத்தில் திரும்பித் தர வேண்டும்.

## Exam

தமிழ் தேர்வு அடுத்த திங்கள்கிழமை. எழுத்துகளும் சொற்களும் படிக்க வேண்டும்.

## Lessons

இந்த வாரப் பாடங்கள்: உயிர் எழுத்துகள், மெய் எழுத்துகள், சிறிய சொற்கள்.

## Songs

இந்த வாரம் இரண்டு பாடல்கள் கற்றோம். ஒன்று மழை பற்றியது, மற்றொன்று நிலா பற்றியது.

## My family

என் பாட்டியின் வீடு கடலுக்கு அருகில் உள்ளது. ரென்னின் பிறந்த நாள் டிசம்பரில் வரும்.
"""

FILES["school/term-dates.md"] = """\
# School year

Thistlecombe Primary, this school year.

## Autumn term

Autumn term dates: 3 September to 19 December. Half term dates: 27 to 31
October, back on Monday 3 November.

## Spring term

Spring term: 5 January to 27 March. February break: 16 to 20 February.

## Summer term

Summer term: 13 April to 21 July.
"""

FILES["school/school-play.md"] = """\
# School play

The Year 5 and Year 6 play this year is The Lantern Fox, adapted by Ms Lune.

## The evening

The play is on Thursday 11 December. Doors open at half past five and the play
will start at six; it runs for about an hour, with a short break in the middle.
Arrive in good time to find a seat.

## Rehearsal

Rehearsal times: Mondays and Wednesdays after lunch, plus two full runs in the
hall in the last week. Pip is the fox and needs her lines learnt by the first
of December.

## Costumes

Pip needs an orange jumper and a tail made at home. Wren is helping with the
posters.
"""

FILES["school/sports-day.md"] = """\
# Sports day

Sports day is on the field behind the school, weather permitting.

## Relay

Pip is in the relay team with Juno, Kit and Oskar. The relay is the last race
of the afternoon.

## Food stall

The PTA runs a hot dog stall and a cake stall. Bring coins, not notes.

## Lunch

A packed lunch is fine, or order a school lunch by Wednesday.
"""

FILES["school/swimming-lessons/autumn-term.md"] = """\
# Autumn term

Wren's group goes to Brook Street pool on Tuesday afternoons. The coach leaves
at one and comes back at half past two. Lessons last forty minutes in the
small pool, with two teachers in the water and one on the side. Badges for
five metres, ten metres and floating on your back are given out in the last
week. Bring a hat if the hair is long, and a snack for the coach back.
"""

FILES["school/art-club/autumn-projects.md"] = """\
# Autumn projects

Projects for this term, one a fortnight.

## Leaf prints

Roll paint on a leaf and press it on paper. The club uses the craft paper and
the craft glue from the art cupboard.

## Clay hedgehog

Pinch a ball of clay into a hedgehog shape and push in matchsticks for spines.

## Paper lantern

Fold, cut and glue a lantern; a battery light goes inside, never a candle.
"""

FILES["school/art/year5-pottery.md"] = """\
# Year 5 pottery

## This week

Each child made a thumb pot from red clay. The pot dries on the shelf for a
week before anything else happens.

## Next week

Next week we paint the pot we made, and then the teacher puts on a clear glaze
and fires it in the kiln.
"""

FILES["school/contacts.txt"] = """\
School contacts

Class teacher for Pip (Year 5): Mr Quarrie
Class teacher for Wren (Year 2): Ms Lune
Head teacher: Mrs Ashdown
School office: Mrs Fellbright, 01632 960200

Write the child's name and class on every form and every envelope.
Absence line: press 1 and leave the child's name and the reason.
"""

NO_FINAL_NEWLINE["school/pe-kit.txt"] = "PE kit on Thursday: shorts, T-shirt and trainers, earrings out."

FILES["school/empty-notes.txt"] = ""

BOM_FILES["school/class-rules.md"] = """\
# Class rules

Our Year 5 class made these together in September.

## In the classroom

Class rules for the classroom: hands up before you speak, and keep your hands
to yourself. Listen when someone else is talking.

## In the playground

Play fair, take turns on the climbing frame and line up when the bell rings.
"""

FILES["school/notes-from-phone.txt"] = """\
Notes typed on the phone at the gate

Year 5 classroom: Room \uff11\uff12, upstairs next to the music room.
Coats on the pegs outside, bags under the bench.
Pickup from the side door after the move.
"""

FILES["school/science-fair.md"] = """\
# Science fair

## Science fair rules

1. Work in pairs or alone; groups of three need a note from the teacher.
2. Every project needs a question, a guess, a test and a result.
3. No flames, no mains electricity and no animals.
4. Anything wet goes on a tray.
5. A grown-up helps with anything sharp.
6. Labels must be big enough to read from a metre away.
7. Bring the project in on the morning; collect it at home time.
8. Judges look for a fair test: change one thing at a time.
9. Write down what went wrong as well as what went right.
10. Have fun and be ready to explain it in your own words.

## Ideas

- Which paper towel soaks up the most water?
- Do seeds sprout faster in the dark?
"""

# ------------------------------------------------------------------ home ----

FILES["home/recipes/pancakes.md"] = """\
# Pancakes

Saturday breakfast. This recipe makes eight.

## Ingredients

- 100 g plain flour
- 2 eggs
- 300 ml milk
- a pinch of salt

## Method

1. Whisk the flour, eggs and milk until smooth.
2. Rest the batter for ten minutes.
3. Cook the pancakes in a hot pan, one ladle at a time.
4. Flip when the edges go golden.
"""

FILES["home/recipes/rasam.md"] = """\
# Rasam

Paati's recipe for rasam, written down by Maren on the phone.

## Method

1. Soak a small ball of tamarind in warm water and squeeze it out.
2. Crush two tomatoes, pepper, cumin and garlic.
3. Boil it all with the tamarind water and a pinch of turmeric.
4. Finish with mustard seeds and curry leaves fried in ghee.
"""

FILES["home/recipes/winter-drinks.md"] = """\
# Winter drinks

## Hot chocolate

Hot chocolate for four: warm a pint of milk in a pan, whisk in three spoons of
cocoa and two of sugar, and pour it into mugs before it boils.

## Warm apple juice

Warm the apple juice with a cinnamon stick and a slice of orange.
"""

FILES["home/weekend-plans.md"] = """\
# Weekend plans

## Café on Mill Lane

The café on Mill Lane opens at eight. Opening hours: eight till four on
Saturdays, closed on Sundays. The café menu has toast, soup and three kinds
of cake.

## Winter fair

Thistlecombe winter fair on Saturday 29 November at the village hall.

## Walks

Hollow Woods loop if it is dry, the canal path if it is wet.
"""

FILES["home/pets/biscuit-the-dog.md"] = """\
# Biscuit

## About Biscuit

Biscuit is our dog. Biscuit is three. Biscuit sleeps in the kitchen and Biscuit
barks at the post.

## Food

Biscuit has dog food twice a day: one scoop at seven and one at five.

## Treats

Chew bones on Sundays only. No bones from the table, ever.

## Hot days

On hot days keep the dog in the shade, and walk the dog early. When it is
hot, carry water for him and never leave him in the car.

## Lead

Biscuit's lead hangs on the hook by the back door.
"""

FILES["home/chores.md"] = """\
# Chores

## Bins

Take the bins out on the right night and bring the bins in the next morning.

## Pets

Pip: feed Biscuit before school. Wren: fill the water bowl and brush his coat
on Sundays.

## Setting the tables

Lay the kitchen and garden tables for dinner, and wipe the tables after.

## Garden jobs

Water the plant pots on the patio and stack the empty pots by the shed.

## Where things live

The craft box is under the stairs. The skipping rope lives in the shed, on
the hook by the door. Batteries are in the kitchen drawer.
"""

CRLF_FILES["home/shopping-list.md"] = """\
Shopping list

This week:
- eggs
- flour
- milk
- apples
- rice

Later:
- birthday candles
- wrapping paper
"""

FILES["home/birthday-party-wren.md"] = """\
# Wren turns seven

Saturday 13 December, two till four, at home. The party theme is the sea.

## Friends to invite

- Ada (cousin)
- Juno, Kit and Oskar from Year 2
- Mila from the pool

Each friend takes home a shell. Send the invitations by 28 November.

## Food

- ice cream cake
- sandwiches
- fruit kebabs

## Games

- pass the parcel
- musical statues
- sleeping lions
"""

_GARDEN_FILLER = [
    "rain all morning and the water butt is full",
    "frost on the lawn until ten",
    "swept the path and the front step",
    "a robin sat on the spade handle",
    "raked leaves into the wire cage",
    "weeded the long bed by the wall",
    "cold wind from the north",
    "sun by the middle of the day",
    "two sparrows at the feeder",
    "watered the herbs on the step",
    "a frog by the little pond",
    "cut back the lavender",
    "mulched the roses with compost",
    "cloudy and still all day",
    "dug over the corner bed",
    "turned the compost heap",
    "filled the bird bath",
    "a hedgehog under the hedge at dusk",
    "light drizzle in the evening",
    "mowed the grass short",
    "tied up the climbing rose",
    "picked up windfall apples",
    "cleaned the greenhouse glass",
    "the shed roof leaked a little",
    "a blackbird singing on the gate",
    "trimmed the hedge along the lane",
]

_GARDEN_PLANTED = {
    (3, 14): "potted the tomato seedlings on into bigger trays by the window",
    (5, 9): "the bean poles went up and the runner bean row is sown",
    (6, 18): "picked the first strawberry of the year and netted the strawberry bed",
    (8, 22): "Joss mended the fence by the shed",
    (10, 12): "we planted the tulip bulbs by the gate, twenty of them",
}

_MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August",
           "September", "October", "November", "December"]


def _garden_diary() -> str:
    out = ["# Garden diary", "", "One line a day, mostly by Joss.", ""]
    for number, month in enumerate(_MONTHS, start=1):
        out.append(f"## {month}")
        out.append("")
        days = 28 if number == 2 else 30
        for day in range(1, days + 1):
            line = _GARDEN_PLANTED.get((number, day))
            if line is None:
                line = _GARDEN_FILLER[(number * 31 + day * 7) % len(_GARDEN_FILLER)]
            out.append(f"- {day} {month}: {line}.")
        out.append("")
    return "\n".join(out)


FILES["home/garden-diary.md"] = _garden_diary()

FILES["home/money/pocket-money.md"] = """\
# Saving jar

Pip gets three pounds each Saturday and Wren gets two. Half goes in the saving
jar on the kitchen shelf and half can be spent. Money from Paati goes in the jar
too.

## Jobs that earn extra

- washing the car: fifty pence
- sorting the recycling: twenty pence
- matching the socks: ten pence

## What they are saving for

- Pip: a skateboard
- Wren: a microscope
"""

FILES["home/tamil/பாட்டி-கடிதங்கள்.md"] = """\
# Paati's letters

Letters from Paati, copied out by Maren.

## Shop

தெரு முனையில் ஒரு புதிய கடை திறந்தது. அங்கே காய்கறியும் பழமும் வாங்கலாம்.

## Sea

நேற்று மாலை கடல் அமைதியாக இருந்தது. அலைகள் சிறியவை.

## Library

நூலகம் சனிக்கிழமை மூடப்படும். ஞாயிறு அன்று திறந்திருக்கும்.

## Garden

தோட்டத்தில் இந்த ஆண்டு நிறைய பழம் வந்தது. மாமரம் நன்றாக வளர்ந்தது.

## Temple festival

கோயில் திருவிழாவில் தேர் ஊர்வலம் நடந்தது. மேளம் சத்தமாக ஒலித்தது.

## Wren's football

ரென் கால்பந்து விளையாடும்போது காலில் அடிபட்டது என்று கேள்விப்பட்டேன். இப்போது கால் வலி குறைந்ததா?

## Books sent

உங்களுக்காக மூன்று புத்தகங்கள் அனுப்பினேன். ஒன்று ஆதாவுக்கு.

## Visit

நாளை நான் உங்கள் வீட்டுக்கு வருவேன். இனிப்பு கொண்டு வருவேன்.
"""

FILES["home/house-rules.md"] = """\
# House rules

## Screens

Screen time on school nights: thirty minutes after reading, and none after
seven. Weekends are an hour each day.

## Bedtime

Wren at seven, Pip at eight. Books in bed are fine.

## Kind words

We say sorry, we say thank you, and we knock on closed doors.
"""

FILES["home/phone-numbers.txt"] = """\
Phone numbers

Paati's phone number: 01632 960418
Maren: 07700 900123
Joss: 07700 900456
School office: 01632 960200
Vet on Mill Lane: 01632 960311
"""

FILES["home/fridge-notes.md"] = """\
# Fridge notes

## Wifi

Wifi name: VarnellHome. Wifi password: puffin-lantern-42, also on the back of
the router.

## Bins

The recycling bins go out on Wednesday night; the black bin on Thursday.

## Shopping

Get chocolate for the cake. The oven runs hot, so bake it lower and check it
early. More chocolate buttons for the top, and buy tulips for Paati.
"""

FILES["home/music/recorder-practice.md"] = """\
# Recorder

## Every day

Recorder practice: fifteen minutes every day, after tea, scales first and then
the piece for the week.

## Flute next year

Pip can start flute lessons next year if she keeps up the recorder.

## Pieces

- Hot Cross Buns
- Merrily We Roll Along
"""

FILES["home/calendar-november.md"] = """\
# November

- Sat 8: Ada's birthday party at the leisure centre, two o'clock.
- Wed 12: library visit with Wren's class; bring the reading record.
- Sun 16: Paati on the phone at four.
- Sat 22: Pip's football tournament.
- Fri 28: invitations go out.
"""

FILES["home/holiday/seaside-packing.md"] = """\
# Seaside

Packing for the long weekend by the sea.

- sunscreen and hats
- buckets and spades
- two towels each
- the windbreak
- a kite
"""

FILES["home/weekend/sale-in-the-field.md"] = """\
# Sunday morning

Car boot sale at Mill Field, Sunday from seven. We are selling the old toys,
the outgrown bikes and the jigsaws. Bring the car early to get a good pitch,
and park the car facing out. The car needs to be empty by six on Saturday.
"""

FILES["home/health/doctor-visits.md"] = """\
# Doctor visits

## Wren

Ear check in October; all clear. Next check in the spring.

## Pip

Eye test in September; glasses for reading only.
"""

FILES["home/pets/fish-tank.md"] = """\
# Fish tank

Wash your fingers after feeding the fish. Two pinches of flakes in the
morning, none at night. Change a third of the water every Sunday.
"""

FILES["home/roof-and-heating.md"] = """\
# Roof and heating

The solar panels went on the roof in May. The heating system is new too, and
the fitter showed us how the system works. Model number on the boiler: VX-40.
"""

# ---------------------------------------------------------------- laptop ----

FILES["laptop/plans/half-term-plans.md"] = """\
# The week off

## Farm day

Hollow Farm on Tuesday: the ponies give rides at eleven, and the goats are fed
at two. Wellies and old coats.

## Rainy day ideas

- the Toy Museum
- baking
- the library story hour
"""

FILES["laptop/school-run-rota.md"] = """\
# School run rota

## Monday

Monday pickup: Maren at a quarter past three.

## Tuesday

Tuesday pickup: Joss, then straight to the library.

## Wednesday

Wednesday pickup: Joss. Wren has gym club until four.

## Thursday

Thursday pickup: Maren, with the neighbours' twins.

## Friday

Friday: no pickup. We ride bikes home together if it is dry.
"""

FILES["laptop/budget-autumn.md"] = """\
# Autumn budget

## House

Heating, food, the car insurance in November.

## Kids

Pocket money for the kids: five pounds a week. The pocket money comes out on
Saturday morning.

## Saving

Holiday pot: twenty pounds a week.
"""

FILES["laptop/emails-to-school.md"] = """\
# Emails to school (drafts)

## Absence

Dear Mr Quarrie, Pip was off sick on Monday with a cold and is back today.
Kind regards, Maren Varnell.

## Club place

Dear office, could Wren have a place at gym club on Wednesdays from next
month? Thank you, Joss Varnell.

## Lost coat

Dear Ms Lune, Wren's blue coat went missing on Thursday. It has her initials
inside the collar. Thank you.
"""

FILES["laptop/notes/dentist.md"] = """\
# Dentist

## Next appointment

Dentist appointment: Thursday 4 December, ten past nine, Mill Lane surgery.

## Brushing teeth

Brush teeth twice a day for two minutes. Teeth first, then a rinse; Wren's
teeth need a softer brush.
"""

FILES["laptop/tamil/tamil-stories.md"] = """\
# கதைகள்

Stories Paati told, written down by Maren.

## The cat

ஒரு பூனை பால் குடிக்க சமையலறைக்கு வந்தது. இது பூனை கதை, ரென்னுக்கு மிகவும் பிடிக்கும்.

## Elephants

காட்டில் யானைகள் ஆற்றில் தண்ணீர் குடித்தன. சிறிய யானைகள் அம்மாவின் பின்னால் நடந்தன.

## Monkey

ஒரு குரங்கு மரத்தில் ஏறியது. பல மரங்கள் இருந்தன; குரங்கு ஒவ்வொன்றிலும் தாவியது. இது ஒரு சிறிய கதை.

## New house

புதிய வீடு. எங்கள் புதிய வீடு பெரியது.

## The journey

நீண்ட பயணம் முடிந்ததும் எல்லோரும் தூங்கினோம்.
"""

FILES["laptop/kids-questions.md"] = """\
# Questions the kids asked

Written down so we can look them up together.

## Pip

- Why is the sky blue in the day and orange at sunset?
- How old is the oldest fossil anyone has found?
- How do bees know the way home?

## Wren

- Do fish sleep?
- Where does the moon go in the day?
- Why do cats purr?
"""

FILES["laptop/reading-list.md"] = """\
# Books for the winter

Books to try before spring, for Pip and Wren. Pip's reading level is gold band.

## Books to borrow

- The Lantern Fox
- Seven Doors Down
- Books about space, any

## Books to buy

- a bird guide for the garden
- a joke book for the car
"""

FILES["laptop/club-timetable.md"] = """\
---
title: Club timetable
term: autumn
---

# Club timetable

## Football

Football practice on Tuesdays at Mill Field. Football practice kit: shin pads
and a water bottle.

## Changes this week

Football practice is off on Saturday: they are cancelling because the pitch is
flooded, and the coach will text about next week.

## Art club

Art club: Thursdays, quarter past three to quarter past four, in the hall.

## After school club

After school club runs until six every day. Book a place by noon the day before.

## Chess

Chess on Mondays at lunchtime, for Year 4 and up.
"""

FILES["laptop/projects/pip-planet-model.md"] = """\
# Planet model

## What to make

Make a solar system model with eight painted balls on wires, hanging from a
coat hanger, in the right order from the sun.

## Project notes

The project box is in the hall. The project shelf at school has the paint. The
project marks are for neatness and for facts.
"""

FILES["laptop/meeting-notes-pta.md"] = """\
# PTA meeting notes

## Screen time talk

A talk on screen time for parents is planned for January in the library. Bring
questions.

## Hall bookings

The hall is free for a sound test on Friday. Booking times are on the board in
the office, and the tables must be stacked at the end of every booking.

## Fundraising

The cake stall at sports day raised ninety pounds. The winter fair needs
helpers for the tombola.

## Next meeting

Tuesday 2 December, seven o'clock, in the staff room.
"""

FILES["laptop/recipes-to-try.txt"] = """\
Recipes to try

- strawberries and cream for the summer party
- lemon drizzle cake
- scrape the ice out of the freezer before the big batch of soup
- flapjacks with honey
- the recipes from the library cookbook
"""

FILES["laptop/archive/old-term-dates.md"] = """\
# Old term dates

Last year's calendar, kept for reference.

## Autumn

October holiday: 28 October to 1 November. Term ended on 19 December.
"""


def _homework_tracker() -> str:
    lines = ["Homework tracker", "Pip and Wren, autumn term", ""]
    day = datetime.date(2026, 9, 7)
    end = datetime.date(2026, 12, 12)
    pip = ["maths homework done", "science homework done", "spelling practice done",
           "maths homework half done", "science homework done, needs a drawing"]
    wren = ["reading done", "phonics cards done", "reading done, two pages", "number bonds done"]
    special = {
        datetime.date(2026, 12, 3): "no homework tonight, dentist appointment in the morning",
        datetime.date(2026, 12, 4): "dentist appointment card is in the blue folder",
    }
    n = 0
    while day <= end:
        if day.weekday() < 5:
            label = day.strftime("%a ") + str(day.day) + day.strftime(" %b")
            if day in special:
                lines.append(f"{label}: {special[day]}.")
            else:
                lines.append(f"{label}: Pip {pip[n % len(pip)]}.")
                lines.append(f"{label}: Wren {wren[n % len(wren)]}.")
            n += 1
        day += datetime.timedelta(days=1)
    return "\n".join(lines) + "\n"


FILES["laptop/log/homework-tracker.txt"] = _homework_tracker()

FILES["laptop/wishlist.md"] = """\
# Wish list

## Winter list

- camping chairs for the garden
- a torch each
- a toy piano for the baby cousin
- new wellies for Wren
"""

FILES["laptop/packing-lists/camping.md"] = """\
# Tent weekend

Everything for the camping weekend in May.

## Tent and sleeping

- tent, tent pegs and the mallet
- spare tent rope, two lengths, and more tent rope in the car
- sleeping bags and mats

## Kitchen

- stove and gas
- pan, mugs, spoons
- matches in a tin
"""

FILES["laptop/ideas/kitchen-science.md"] = """\
# Kitchen science

Kitchen science for a wet afternoon: the science of bubbles, a lava lamp in a
jar, and a rainbow in a glass of sugar water. Science is messy, so use a tray.
"""

FILES["laptop/notes/uniform.md"] = """\
# What Pip and Wren wear

Grey trousers or a grey skirt, a white polo shirt and the green jumper with the
badge. PE: black shorts and a white T-shirt. Name labels on everything. The
uniform shop at the school office sells jumpers on Friday mornings.
"""

FILES["laptop/notes/car-garage.md"] = """\
# Car

## The noise

The car makes a weird noise when it turns left, like a click. Booked into the
garage on Tuesday morning.

## Boot

The boot of the car is stuck again. A new catch is on sale at the garage for
twelve pounds.
"""

FILES["laptop/clubs/football/match-days.md"] = """\
# Match days

Saturday games for Pip's football team: kick-off at ten at Mill Field, home
games in the green shirts, away games in white. Orange slices at half time,
and a lift rota on the group chat.
"""

# ------------------------------------------- S5-T4 held-out slices (files) --

# Files added by S5-T4 (ruling 11 of its plan) for the morphology-heldout,
# accent-heldout and tamil-heldout slices, written and judged before any key
# function existed in the engine or the reference. They keep out of every word
# an earlier J2 query searches (and of the near words fuzzy-v1 expands those
# to). They are few files of long sections because every earlier row's BM25
# reads the pack's chunk count, its average chunk length and (the title field)
# its file count: a first draft of 22 short files moved 39 earlier cells of the
# reference, these six move none. The Tamil is invented, written as everyday
# Tamil.

FILES["laptop/notes/jottings.md"] = """\
# Hollybank Farm

Hollybank Farm has six puppies this autumn, born in September to Juno, their
old sheepdog. Wren may hold one if she sits still on hay bales in barn; they
are black with white paws, all very sleepy. Pears ripen by October, cider
press runs on Sundays in barn yard, one old peach tree grows on south wall,
netted against blackbirds, with fruit only in warm summers.

# Race timekeepers

Two parents stand at each lane end, both with watches set to seconds. Races
begin on whistle from Mr Quarrie. Write down each finish to nearest second on
yellow cards, then pass cards to Ms Lune at results desk by gate. Spare
pencils sit in tray beside her, with clipboards, rubber bands, one spare
whistle in case Mr Quarrie loses his.

# Rainy afternoons

Old wooden dominoes live in tin under stairs, with two pieces missing. Wren
stands them in long rows across hall carpet, curving round chair legs, then
knocks over first one while everyone counts. Snap, happy families, old maid,
rummy with Joss on wet afternoons; cards are kept in drawer by sofa, with
rubber band round each pack.

# Comic swap

Pip draws one comic hero every evening: Captain Puddle, who saves ducks from
drains, wearing wellies with every outfit, cape made from old curtain.
Kavin draws villains: Baron Drizzle, Mister Fog. On Mondays they swap copies
at gate; Pip colours hers with felt tips at kitchen counter, then sticks them
in scrapbook.

# Glasses

Joss collects new glasses on Monday from optician on Mill Lane, ready by
four, frames chosen last month. Old glasses go in top drawer as spares, in their blue case with cloth.
Eye check again in twelve months; Pip also needs one in spring, booked on
first Monday of April, morning slot, before nine if possible, with Dr Fenn.

# Towpath

Joss went cycling with Pip along canal towpath on Sunday, out to lock gates
by old mill, then home, six miles in all. Ducks everywhere, one heron on far
bank, narrowboats moored by bridge with smoke from their chimneys. Puncture
repairs: pump stays in saddle bag, spare tube too.
"""

FILES["laptop/notes/bedtime-stories.md"] = """\
# Méla

Méla is hedgehog who rolls downhill into puddles, then sneezes. Wren invented
her one wet evening; each story ends with Méla asleep in leaves under hedge,
snoring softly, while owls hoot overhead.

# Mela

Mela, mole under Mill Lane, digs tunnels all winter. Mela hates daylight;
Mela sings in her burrow, loudly, off key. Pip tells these stories, doing
voices, until Wren falls asleep.

# Otter

Chapter Ⅰ: otter wakes by river at dawn, shakes dew from whiskers, slides
down muddy bank into cold water. Chapter Ⅱ: otter meets heron on mudbank;
heron stands on one leg, says nothing, flaps off, cross. Chapter Ⅲ: rain all
evening; river rises, brown, fast, roaring under bridge; otter shelters in
hollow willow root with two voles, telling jokes until dawn.

# Chapter Ⅳ

Otter finds old brass key on riverbank when water drops. Nobody knows what it
opens. She hides it under flat stone near willow, marked with feather, then
swims off downstream.
"""

FILES["home/household.md"] = """\
# Sunday baking

Joss makes shortcrust pastry on Sundays with cold butter, cold water, pinch of
salt, rubbed in quickly with fingertips, rested in fridge until firm, then
rolled out thin on floured worktop; scraps become jam tarts. Plum jam goes
into glass jars warmed in oven: glass lids, glass funnel, wax discs, labels
on top with month written in pen. Twelve jars last until spring.

# Hooks by door

Woolly hats on top row of hooks: Wren has pink with bobble, Pip has grey,
Joss has striped one. One red glove missing, left one, since walk to bus
stop on Monday; its partner waits on lowest hook. Aunt Edie knitted two
scarves last winter, one green, one yellow, both far too long; they hang on
end hook so they do not drag on floor.

# News from Orchard Row

Kestrels moved into Hawthorn Cottage at end of row; Mr Hobb retired from
bakery at seventy, thirty years on; bakery reopens on Monday under Mrs Penrose, with
sourdough every weekend morning. More news goes on noticeboard by bus stop, pinned
with red drawing pins, beside parish notices, bus timetables.

# Gate

New gate, new path, new hedge at Hawthorn Cottage. Gate swings both ways,
then clicks shut on its own, which Wren likes to try each morning on way
past, pushing it open with one thumb, counting how long it swings, laughing.

# Supper

Smørrebrød on Mondays: rye bread spread with butter, topped with cucumber,
cress, prawns, sliced radish; Joss learned it from Uncle Anders, each person
builds their own on wooden board. Roast on Sundays, then crumble with custard;
leftovers go into pie on Monday or soup by midweek.
"""

FILES["home/days-out/seals.md"] = """\
# Boat from harbour

Boat leaves harbour at ten, returns by noon. Grey ones lie on rocks near
lighthouse, pups too, white, fluffy, blinking. Pack binoculars, waterproofs,
flask, spare socks; it is windy out past headland, so wear hats. Pay at
kiosk on quay, cash only, then queue by railings.
"""

FILES["school/noticeboard.md"] = """\
# Assembly notes

Year 2 learn maypole dancing in spring with Ms Lune, ribbons red, white,
blue; parents watch from benches on May morning while children weave in,
out, round. Zoe Brannock joins Year 2 from Easter, moving from coast with
her two brothers. Wren will show her round: cloakroom, hall, peg with her
label.

# Summer fête

Thistlecombe fête is on 21 June on village green: Year 5 runs lemonade
stall, Year 2 runs tombola, parents run raffle. Pip has one speaking rôle in
Year 5 assembly that morning: she reads first verse of harvest poem, slowly,
facing hall. She practises at home with Joss as audience.

# Tasting

Ms Lune brought crème brûlée to French tasting: burnt sugar on top, custard
underneath, tapped with spoon until it cracked. Wren had deja vu on Monday:
same song twice in assembly, same verse, same clapping. Ms Lune says deja vu
is French, meaning already seen.

# German corner

Fussball, Tennis, Schwimmen, Laufen: German sport vocabulary on wall chart by
window. Tor is goal, Pfeife is whistle; Pip shouts Tor at every goal in
playground. Mannschaft means side, Spieler means player, Trainer means
coach. Ms Lune quizzes them on Mondays with flash cards.

# Mean

Mean: add them all, then divide by how many there are. Mean of 4, 6, 8 is 6;
mean of 10, 20 is 15. Median is middle one once sorted; mode is most common
one. Pip checks her mean on calculator, then explains it to Wren with
counters on kitchen counter.

# PTA flyer

Autumn flyer, copied from PDF

Coﬀee morning in hall each Monday, quarter past nine, run by PTA volunteers.
Toddlers welcome; toys in corner, squash in beakers. Spare jumpers by
oﬃce door, two pounds each, into honesty jar. Raffle at
door; prizes donated by village shops, drawn at eleven.

# Swim gala results

Pip came 2ⁿᵈ in backstroke, just behind Kavin, by one stroke; her cap came
off at turn, she kept going, medal on ribbon now on bedroom door. Wren came
3ʳᵈ in width race, with arm bands, kicking hard. Then orange squash, crisps,
towel round shoulders in viewing gallery.
"""

FILES["home/tamil/tamil-jottings.md"] = """\
# Village

அம்மாவின் கிராமம் ஒரு சிறிய ஊர். அங்கே எல்லோருக்கும் எல்லோரையும் தெரியும்.
ஊர்க் குளத்தில் தாமரைப் பூக்கள் மிதக்கின்றன. மாலையில் வானத்தில் பறவைகள்
கூட்டமாகப் பறந்தன. நகரத்தின் நடுவில் ஒரு பெரிய மணிக்கூண்டு உள்ளது. அது
ஒவ்வொரு மணிக்கும் அடிக்கும். அதன் அருகே சந்தை கூடுகிறது.

# Work

அப்பாவுக்கு இந்த வாரம் நிறைய வேலை. இரவு தாமதமாகத்தான் வருவார். அதனால்
அம்மா சமைக்கிறார். ஞாயிறு அன்று அவர் ஓய்வு எடுப்பார். அன்று எல்லோரும்
சேர்ந்து சாப்பிடுவோம்.

# Festival

கோயில் சிலையின் கையில் ஒரு வேல் இருக்கிறது. திருவிழா அன்று அதற்கு மாலை
போட்டோம். பிரசாதமாக சர்க்கரைப் பொங்கல் கிடைத்தது. இரவு முழுவதும் மேளம்
ஒலித்தது.

# Kavin

ரென் ஆற்றின் படம் வரைந்தாள். நீல நிறம் நிறைய பயன்படுத்தினாள். பிப்பின் நண்பர்
கவின் ஊருக்கு வந்தான். இருவரும் மைதானத்தில் கிரிக்கெட் விளையாடினார்கள். ரென்
என் தங்கை. அவளுக்கு ஏழு வயது. கவினின் தம்பியின் பெயர் சிவா. அவனுக்கு ஐந்து
வயது.

# Result

ஓவியப் போட்டியின் முடிவு திங்கள் அன்று வரும். எல்லோரும் ஆவலுடன்
காத்திருக்கிறோம். ரென் தன் ஓவியத்தை இரண்டு முறை சரிபார்த்தாள்.

# Haircut

ரென் நேற்று முடி வெட்டிக்கொண்டாள். இப்போது குட்டையாக இருக்கிறது. அவளுக்கு அது
பிடித்திருக்கிறது. அம்மா புகைப்படம் எடுத்தார்.

# River

சிவப்புப் பெட்டி ஒன்று அலமாரி மேல் இருக்கிறது. அதில் பழைய பொம்மைகள் உள்ளன.
குருவியின் கூடு ஜன்னல் அருகே இருக்கிறது. நாங்கள் ஞாயிறு அன்று ஆற்றில்
நீந்தினோம். தண்ணீர் குளிராக இருந்தது. அப்பா கரையில் காத்திருந்தார்.

# Together

நாம் எல்லோரும் சேர்ந்து பாடுவோம். நாம் ஆடுவோம். நாம் சிரிப்போம். இது எங்கள்
வகுப்புப் பாட்டு. ஒவ்வொரு வெள்ளியும் இதைப் பாடுகிறோம்.
"""
