"""The judged queries of J2 (S5-T1): seven slices plus named negatives.

A row is (path, anchor, grade, note). The generator turns each anchor into a line
range of the file it names:

  "§Heading"   the Markdown section with that heading (the chunk md-section-v1
               makes for it, trailing blank lines dropped); unique in the file
  "=needle"    the one line holding the needle
  "=a..b"      the lines from the one holding a to the one holding b
  "*"          the whole file

Grades: 2 is the answer, 1 is useful context, 0 names a distractor (a place the
engine is expected to be drawn to, never counted as relevant). For title intent
grade 2 is the whole file: the intent is "open that file".

Each slice carries the facts its `checks` assert (generate.py): the typo of a
misspelling row, the form pairs of a morphology, accent or Tamil row, where a
title row's words sit in the path, which row holds a phrase adjacently. A check
that fails stops the generator: the miss would no longer be real.
"""

from __future__ import annotations

SLICE_MINIMUMS = {
    "control": 20,
    "misspelling": 15,
    "morphology": 12,
    "accent": 6,
    "tamil": 10,
    "title": 10,
    "phrase": 8,
    "title-heldout": 6,
}

QUERIES: list[dict] = []


def q(slice_, qid, question, query, mode, rows, **facts):
    QUERIES.append({"slice": slice_, "id": qid, "question": question, "query": query,
                    "mode": mode, "rows": rows, **facts})


K, W, P, X = "knowledge", "find:words", "find:phrase", "find:prefix"

# ------------------------------------------------------------- control (23) --

q("control", "c01", "When is the volcano project due?", "volcano project due date", K, [
    ("school/volcano-project.md", "§Due date", 2, "the due date"),
    ("school/class-notes-pip.md", "=Volcano model due soon", 1, "the class note that it is due soon"),
    ("laptop/projects/pip-planet-model.md", "§What to make", 0, "another project"),
    ("school/newsletter-autumn.md", "§Science week", 0, "a volcano demo, not the project"),
])
q("control", "c02", "What do I need for swimming on Tuesday?", "swimming kit tuesday", K, [
    ("school/class-notes-wren.md", "§Reminders", 2, "the kit list"),
    ("school/swimming-lessons/autumn-term.md", "*", 0, "the lessons, no kit list"),
    ("school/newsletter-autumn.md", "§Swimming", 0, "lessons start"),
])
q("control", "c03", "What time does the school play start?", "school play start time", K, [
    ("school/school-play.md", "§The evening", 2, "start at six"),
    ("school/school-play.md", "§Rehearsal", 0, "rehearsal times, not the play"),
])
q("control", "c04", "Who is in the relay team?", "relay team", W, [
    ("school/sports-day.md", "§Relay", 2, "the team"),
    ("school/sports-day.md", "§Food stall", 0, "same page, other part"),
])
q("control", "c05", "When does the library book go back?", "library book due back", K, [
    ("school/class-notes-pip.md", "§Week 8", 2, "return by Monday"),
    ("home/calendar-november.md", "=library visit", 0, "a library visit"),
])
q("control", "c06", "What's the screen time rule on school nights?", "screen time school nights", K, [
    ("home/house-rules.md", "§Screens", 2, "the rule"),
    ("laptop/meeting-notes-pta.md", "§Screen time talk", 0, "a talk about screen time"),
])
q("control", "c07", "Is it fish and chips on Friday?", "fish chips friday", K, [
    ("school/lunch-menu.md", "§Friday", 2, "fish and chips"),
    ("school/lunch-menu.md", "§Wednesday", 0, "fish fingers"),
])
q("control", "c08", "When is the dentist appointment?", "dentist appointment", K, [
    ("laptop/notes/dentist.md", "§Next appointment", 2, "the appointment, a short section"),
    ("laptop/log/homework-tracker.txt", "=no homework tonight, dentist appointment..dentist appointment card",
     0, "a long log window holding the pair twice: the length-normalisation row"),
])
q("control", "c09", "What's the wifi password?", "wifi password", K, [
    ("home/fridge-notes.md", "§Wifi", 2, "the password"),
])
q("control", "c10", "When is half term?", "half term dates", K, [
    ("school/term-dates.md", "§Autumn term", 2, "this year's half term"),
    ("laptop/archive/old-term-dates.md", "*", 0, "last year's dates"),
])
q("control", "c11", "How long should I practise the recorder?", "recorder practice minutes", K, [
    ("home/music/recorder-practice.md", "§Every day", 2, "fifteen minutes"),
])
q("control", "c12", "Who picks up on Wednesday?", "wednesday pickup", K, [
    ("laptop/school-run-rota.md", "§Wednesday", 2, "Joss"),
    ("laptop/school-run-rota.md", "§Monday", 0, "another day"),
    ("laptop/school-run-rota.md", "§Tuesday", 0, "another day"),
    ("laptop/school-run-rota.md", "§Thursday", 0, "another day"),
])
q("control", "c13", "What does Biscuit eat?", "biscuit dog food", K, [
    ("home/pets/biscuit-the-dog.md", "§Food", 2, "dog food twice a day"),
    ("home/pets/biscuit-the-dog.md", "§Treats", 0, "treats, not meals"),
])
q("control", "c14", "What are this week's spelling words?", "spelling words week 9", K, [
    ("school/spelling-lists.md", "§Week 9", 2, "the week 9 list (setext heading)"),
    ("school/spelling-lists.md", "§Week 8", 0, "the week before"),
])
q("control", "c15", "பூனை கதை எங்கே? (where is the cat story?)", "பூனை கதை", K, [
    ("laptop/tamil/tamil-stories.md", "§The cat", 2, "the cat story"),
    ("laptop/tamil/tamil-stories.md", "§Elephants", 0, "another story"),
])
q("control", "c16", "When is the café open?", "café opening hours", K, [
    ("home/weekend-plans.md", "§Café on Mill Lane", 2, "opening hours"),
    ("school/lunch-menu.md", "§School lunch menu", 0, "another menu"),
])
q("control", "c17", 'Find "bring a packed lunch".', "bring a packed lunch", P, [
    ("school/trip-permission-museum.md", "§What to bring", 2, "the phrase, in a CRLF file"),
    ("school/sports-day.md", "§Lunch", 0, "packed lunch without bring"),
])
q("control", "c18", "Anything starting with fossil?", "fossil*", X, [
    ("school/dinosaur-topic.md", "§Fossils", 2, "the fossils section"),
    ("laptop/kids-questions.md", "=oldest fossil", 1, "a question about a fossil"),
])
q("control", "c19", "What's Paati's phone number?", "paati phone number", K, [
    ("home/phone-numbers.txt", "*", 2, "the number list, one chunk"),
    ("home/tamil/பாட்டி-கடிதங்கள்.md", "*", 0, "Paati's letters"),
])
q("control", "c20", "Is flour on the shopping list?", "shopping list eggs flour", K, [
    ("home/shopping-list.md", "=This week:..=- rice", 2, "this week's list, CRLF"),
    ("home/fridge-notes.md", "§Shopping", 0, "a shopping note without flour"),
])
q("control", "c21", "What are the class rules about hands up?", "class rules hands up", K, [
    ("school/class-rules.md", "§In the classroom", 2, "hands up, in a file with a BOM"),
    ("home/house-rules.md", "*", 0, "other rules"),
])
q("control", "c22", "When did we pot the tomato seedlings?", "tomato seedlings potted", K, [
    ("home/garden-diary.md", "=tomato seedlings", 2, "14 March, in the long diary"),
    ("home/garden-diary.md", "=runner bean row", 0, "another planting day"),
])
q("control", "c23", "Which day is PE kit?", "pe kit thursday", W, [
    ("school/pe-kit.txt", "*", 2, "one line, no final newline"),
    ("school/class-notes-wren.md", "§Reminders", 0, "swimming kit"),
])

# -------------------------------------------------------- misspelling (16) --
# typo = (as typed, the word meant, is it one adjacent transposition)

q("misspelling", "m01", "Show me the dinosaur bones page", "dinosoar bones", K, [
    ("school/dinosaur-topic.md", "§Bones and skeletons", 2, "the bones section"),
    ("home/pets/biscuit-the-dog.md", "§Treats", 0, "chew bones, short"),
], typo=("dinosoar", "dinosaur", False))
q("misspelling", "m02", "Why do we learn multiplication tables?", "multiplicaton tables", K, [
    ("school/maths-practice.md", "§Why we learn them", 2, "the reason"),
    ("school/maths-practice.md", "§Times tables test", 1, "the same topic"),
    ("home/chores.md", "§Setting the tables", 0, "tables, the furniture"),
], typo=("multiplicaton", "multiplication", False))
q("misspelling", "m03", "What do I make for the volcano project?", "volcanoe project", K, [
    ("school/volcano-project.md", "§What to make", 2, "the model"),
    ("laptop/projects/pip-planet-model.md", "§Project notes", 0, "project three times, short"),
], typo=("volcanoe", "volcano", False))
q("misspelling", "m04", "What's the fractions homework?", "fractoins homework", K, [
    ("school/maths-homework.md", "§This week", 2, "the fractions sheet"),
    ("school/newsletter-autumn.md", "§Homework club", 0, "homework, dense"),
    ("laptop/log/homework-tracker.txt", "*", 0, "the homework log"),
], typo=("fractoins", "fractions", True))
q("misspelling", "m05", "Which friends are coming to the party?", "freind birthday party", K, [
    ("home/birthday-party-wren.md", "§Friends to invite", 2, "the guest list"),
    ("home/calendar-november.md", "*", 0, "another birthday party, short"),
], typo=("freind", "friend", True))
q("misspelling", "m06", "Who picks up on Wednesday?", "wendesday pickup", W, [
    ("laptop/school-run-rota.md", "§Wednesday", 2, "Joss"),
], typo=("wendesday", "wednesday", True))
q("misspelling", "m07", "When do the library books go back?", "libary books", K, [
    ("school/class-notes-pip.md", "§Week 8", 2, "return by Monday"),
    ("laptop/reading-list.md", "§Books to borrow", 0, "books, other sense"),
], typo=("libary", "library", False))
q("misspelling", "m08", "How tall is the bean?", "bean hieght", K, [
    ("school/science-homework.md", "§Measuring", 2, "how to measure the height"),
    ("home/garden-diary.md", "=runner bean row", 0, "a bean row in the garden"),
], typo=("hieght", "height", True))
q("misspelling", "m09", "What was the weird noise in the car?", "wierd noise car", K, [
    ("laptop/notes/car-garage.md", "§The noise", 2, "the click"),
    ("home/weekend/sale-in-the-field.md", "*", 0, "car three times"),
], typo=("wierd", "weird", True))
q("misspelling", "m10", "Which night do the recycling bins go out?", "recyling bins", K, [
    ("home/fridge-notes.md", "§Bins", 2, "Wednesday night"),
    ("home/chores.md", "§Bins", 0, "bins twice, short"),
], typo=("recyling", "recycling", False))
q("misspelling", "m11", "Show me the dinosaur stuff", "dinosuar", K, [
    ("school/dinosaur-topic.md", "§Our dinosaur topic", 2, "the topic page"),
], typo=("dinosuar", "dinosaur", True))
q("misspelling", "m12", "What's happening in February?", "febuary", K, [
    ("school/term-dates.md", "§Spring term", 2, "the February break"),
], typo=("febuary", "february", False))
q("misspelling", "m13", "When are the play rehearsals?", "play rehersal times", K, [
    ("school/school-play.md", "§Rehearsal", 2, "rehearsal times"),
    ("school/maths-practice.md", "§Times tables test", 0, "times, other sense"),
], typo=("rehersal", "rehearsal", False))
q("misspelling", "m14", "Where are my swimming goggles?", "swimming goggels", K, [
    ("school/class-notes-wren.md", "§Reminders", 2, "goggles in the kit"),
    ("school/swimming-lessons/autumn-term.md", "*", 0, "swimming lessons"),
    ("school/newsletter-autumn.md", "§Swimming", 0, "swimming lessons start"),
], typo=("goggels", "goggles", True))
q("misspelling", "m15", "What are the science fair rules?", "sciense fair", K, [
    ("school/science-fair.md", "§Science fair rules", 2, "the rules, a long list"),
    ("home/weekend-plans.md", "§Winter fair", 0, "another fair, short"),
], typo=("sciense", "science", False))
q("misspelling", "m16", "How do I make pancakes?", "pancaeks recipe", K, [
    ("home/recipes/pancakes.md", "§Method", 2, "the method"),
    ("home/recipes/rasam.md", "§Rasam", 0, "recipe, another dish"),
], typo=("pancaeks", "pancakes", True))

# --------------------------------------------------------- morphology (13) --
# forms = [(query word, the form in the answer)]; only_form: no query word at
# all occurs in the answer, every match differs in form.

q("morphology", "o01", "Did dinosaurs have sharp teeth?", "dinosaurs teeth", K, [
    ("school/dinosaur-topic.md", "§Teeth", 2, "sharp teeth"),
    ("laptop/notes/dentist.md", "§Brushing teeth", 0, "teeth three times"),
], forms=[("dinosaurs", "dinosaur")], only_form=False)
q("morphology", "o02", "Can we go on a pony ride?", "pony ride", K, [
    ("laptop/plans/half-term-plans.md", "§Farm day", 2, "the ponies give rides"),
    ("laptop/school-run-rota.md", "§Friday", 0, "ride bikes"),
], forms=[("pony", "ponies"), ("ride", "rides")], only_form=True)
q("morphology", "o03", "What are the teachers' names?", "teachers names", K, [
    ("school/contacts.txt", "*", 2, "teacher, name"),
    ("school/newsletter-autumn.md", "§Staff news", 0, "two new teachers"),
], forms=[("teachers", "teacher"), ("names", "name")], only_form=True)
q("morphology", "o04", "Where's Biscuit's lead?", "biscuit's lead", K, [
    ("home/pets/biscuit-the-dog.md", "§Lead", 2, "the hook by the back door"),
    ("home/pets/biscuit-the-dog.md", "§About Biscuit", 0, "Biscuit four times"),
], forms=[], only_form=False, possessive=True)
q("morphology", "o05", "When were the tulips planted?", "planting tulips", K, [
    ("home/garden-diary.md", "=tulip bulbs", 2, "12 October"),
    ("home/fridge-notes.md", "§Shopping", 0, "buy tulips"),
    ("school/science-homework.md", "§Planting day", 0, "planting a bean"),
], forms=[("planting", "planted"), ("tulips", "tulip")], only_form=True)
q("morphology", "o06", "Why was football practice cancelled?", "football practice cancelled", K, [
    ("laptop/club-timetable.md", "§Changes this week", 2, "the pitch is flooded"),
    ("laptop/club-timetable.md", "§Football", 0, "football practice, the usual times"),
], forms=[("cancelled", "cancelling")], only_form=False)
q("morphology", "o07", "Who feeds Biscuit?", "feeds biscuit", K, [
    ("home/chores.md", "§Pets", 2, "Pip feeds him"),
    ("home/pets/biscuit-the-dog.md", "§About Biscuit", 0, "Biscuit four times"),
], forms=[("feeds", "feed")], only_form=False)
q("morphology", "o08", "When are the spelling tests?", "spelling tests", K, [
    ("school/class-notes-pip.md", "§Spelling", 2, "every Friday"),
    ("school/spelling-lists.md", "§Week 8", 0, "a spelling list"),
], forms=[("tests", "test")], only_form=False)
q("morphology", "o09", "When did we get strawberries?", "strawberries", K, [
    ("home/garden-diary.md", "=first strawberry", 2, "18 June"),
    ("laptop/recipes-to-try.txt", "*", 0, "strawberries and cream, a recipe idea"),
], forms=[("strawberries", "strawberry")], only_form=True)
q("morphology", "o10", "Where are the craft boxes?", "craft boxes", K, [
    ("home/chores.md", "§Where things live", 2, "under the stairs"),
    ("school/art-club/autumn-projects.md", "§Leaf prints", 0, "craft twice"),
], forms=[("boxes", "box")], only_form=False)
q("morphology", "o11", "Where's my skip rope?", "skip rope", K, [
    ("home/chores.md", "§Where things live", 2, "in the shed"),
    ("laptop/packing-lists/camping.md", "§Tent and sleeping", 0, "tent rope twice"),
], forms=[("skip", "skipping")], only_form=False)
q("morphology", "o12", "When do we paint the pots?", "painted pots", K, [
    ("school/art/year5-pottery.md", "§Next week", 2, "next week we paint the pot"),
    ("home/chores.md", "§Garden jobs", 0, "plant pots twice"),
], forms=[("painted", "paint"), ("pots", "pot")], only_form=True)
q("morphology", "o13", "Where are Paati's recipes?", "paati's recipes", K, [
    ("home/recipes/rasam.md", "§Rasam", 2, "Paati's recipe"),
    ("laptop/recipes-to-try.txt", "*", 0, "recipes twice"),
], forms=[("recipes", "recipe")], only_form=False)

# ------------------------------------------------------------- accent (9) --
# fold = (query word, the form in the answer); guard: the two are the same token
# after NFC, and the row must keep passing.

q("accent", "a01", "What's on the cafe menu?", "cafe menu", K, [
    ("home/weekend-plans.md", "§Café on Mill Lane", 2, "café, accented in the file"),
    ("school/lunch-menu.md", "§School lunch menu", 0, "another menu"),
], fold=("cafe", "café"))
q("accent", "a02", "Which book has the naïve snail?", "naïve character book", K, [
    ("school/reading-log-pip.md", "§Book 3", 2, "naive, plain in the file"),
    ("school/reading-log-pip.md", "§Book 1", 0, "another book"),
    ("school/reading-log-pip.md", "§Book 2", 0, "another book"),
], fold=("naïve", "naive"))
q("accent", "a03", "What does fruhling mean?", "fruhling", K, [
    ("school/german-club.md", "§Words for spring", 2, "Frühling"),
], fold=("fruhling", "frühling"))
q("accent", "a04", "Which room is Year 5 in?", "room 12", K, [
    ("school/notes-from-phone.txt", "*", 2, "Room １２, full-width digits in the file"),
    ("school/class-notes-pip.md", "§Week 9", 0, "the room move, no number"),
], fold=("12", "１２"))
q("accent", "a05", "Where are my ｇｏｇｇｌｅｓ? (typed full-width)", "ｇｏｇｇｌｅｓ", K, [
    ("school/class-notes-wren.md", "§Reminders", 2, "goggles"),
], fold=("ｇｏｇｇｌｅｓ", "goggles"))
q("accent", "a06", "When is the field trip?", "field trip date", K, [
    ("school/letters/letter-home-oct.txt", "*", 2, "the ligature ﬁ, pasted from a PDF"),
    ("school/trip-permission-museum.md", "§About the trip", 0, "another trip, with its date"),
], fold=("field", "ﬁeld"))
q("accent", "a07", "When does flute start? (pasted with a ligature)", "ﬂute", K, [
    ("home/music/recorder-practice.md", "§Flute next year", 2, "flute"),
], fold=("ﬂute", "flute"))
q("accent", "a08", "When is the Noël concert?", "noël concert", K, [
    ("school/newsletter-autumn.md", "§Noël carol concert", 2, "decomposed Noël in the file"),
    ("school/newsletter-autumn.md", "§Band", 0, "the band concert"),
], fold=("noël", "noël"), guard=True)
q("accent", "a09", "What does strasse mean?", "strasse", K, [
    ("school/german-club.md", "§Street words", 2, "Straße"),
], fold=("strasse", "straße"))

# -------------------------------------------------------------- Tamil (13) --
# forms = [(query word, the form in the answer)]; a guard is a homograph an
# inflection stripper must not merge: (query word, the word it would become).

q("tamil", "t01", "புத்தகங்கள் எங்கே? (where are the books?)", "புத்தகங்கள்", K, [
    ("school/tamil/tamil-class.md", "§Library", 2, "புத்தகம், the library book"),
    ("home/tamil/பாட்டி-கடிதங்கள்.md", "§Books sent", 0, "புத்தகங்கள், Paati's parcel"),
], forms=[("புத்தகங்கள்", "புத்தகம்")])
q("tamil", "t02", "யானை கதை? (the elephant story?)", "யானை", K, [
    ("laptop/tamil/tamil-stories.md", "§Elephants", 2, "யானைகள், plural"),
], forms=[("யானை", "யானைகள்")])
q("tamil", "t03", "பாட்டி எந்தக் கடைக்கு போனார்? (which shop?)", "கடைக்கு", K, [
    ("home/tamil/பாட்டி-கடிதங்கள்.md", "§Shop", 2, "கடை"),
], forms=[("கடைக்கு", "கடை")])
q("tamil", "t04", "மரம் பற்றிய கதை? (a story about a tree?)", "மரம் கதை", K, [
    ("laptop/tamil/tamil-stories.md", "§Monkey", 2, "மரத்தில், மரங்கள்"),
    ("laptop/tamil/tamil-stories.md", "§The cat", 0, "கதை only"),
], forms=[("மரம்", "மரத்தில்")])
q("tamil", "t05", "நூலகத்தில் என்ன நடக்கும்? (at the library?)", "நூலகத்தில்", K, [
    ("home/tamil/பாட்டி-கடிதங்கள்.md", "§Library", 2, "நூலகம்"),
], forms=[("நூலகத்தில்", "நூலகம்")])
q("tamil", "t06", "பாட்டி வீடு எங்கே? (Paati's house?)", "பாட்டி வீடு", K, [
    ("school/tamil/tamil-class.md", "§My family", 2, "பாட்டியின் வீடு"),
    ("laptop/tamil/tamil-stories.md", "§New house", 0, "வீடு twice, short"),
], forms=[("பாட்டி", "பாட்டியின்")])
q("tamil", "t07", "தோட்டத்துப் பழங்கள்? (fruit from the garden?)", "பழங்கள்", K, [
    ("home/tamil/பாட்டி-கடிதங்கள்.md", "§Garden", 2, "பழம்"),
], forms=[("பழங்கள்", "பழம்")])
q("tamil", "t08", "தேர்வுக்கு என்ன படிக்க வேண்டும்? (for the exam?)", "தேர்வுக்கு", K, [
    ("school/tamil/tamil-class.md", "§Exam", 2, "தேர்வு"),
], forms=[("தேர்வுக்கு", "தேர்வு")])
q("tamil", "t09", "அந்தப் பாடல்? (the song?)", "பாடல்", K, [
    ("school/tamil/tamil-class.md", "§Songs", 2, "பாடல்கள்"),
    ("school/tamil/tamil-class.md", "§Lessons", 0, "பாடங்கள், lessons"),
], forms=[("பாடல்", "பாடல்கள்")])
q("tamil", "t10", "பள்ளிக்கு எப்போது? (going to school?)", "பள்ளிக்கு", K, [
    ("school/tamil/tamil-class.md", "§School time", 2, "பள்ளி"),
], forms=[("பள்ளிக்கு", "பள்ளி")])
q("tamil", "g1", "காலை எப்போது? (when in the morning?)", "காலை", K, [
    ("school/tamil/tamil-class.md", "§School time", 2, "காலை, morning"),
    ("home/tamil/பாட்டி-கடிதங்கள்.md", "§Wren's football", 0, "கால், leg: காலை read as கால் + accusative"),
], guard=("காலை", "கால்"), guard_kind="inflectional")
q("tamil", "g2", "நாளை யார் வருகிறார்கள்? (who is coming tomorrow?)", "நாளை", K, [
    ("home/tamil/பாட்டி-கடிதங்கள்.md", "§Visit", 2, "நாளை, tomorrow"),
    ("school/tamil/tamil-class.md", "§My family", 0, "நாள், day: நாளை read as நாள் + accusative"),
], guard=("நாளை", "நாள்"), guard_kind="inflectional")
q("tamil", "g3", "தேர்வு எப்போது? (when is the exam?)", "தேர்வு", K, [
    ("school/tamil/tamil-class.md", "§Exam", 2, "தேர்வு, exam"),
    ("home/tamil/பாட்டி-கடிதங்கள்.md", "§Temple festival", 0, "தேர், chariot: the nominal -வு, derivational"),
], guard=("தேர்வு", "தேர்"), guard_kind="derivational, information")

# -------------------------------------------------------------- title (11) --
# name = [(query word, where it sits in the path: stem, folder or none)]

q("title", "ti01", "Open my science homework", "science homework", K, [
    ("school/science-homework.md", "*", 2, "the file"),
    ("laptop/log/homework-tracker.txt", "*", 0, "science homework done, many times"),
    ("school/newsletter-autumn.md", "§Homework club", 0, "science homework, dense"),
    ("laptop/ideas/kitchen-science.md", "*", 0, "science three times"),
], name=[("science", "stem"), ("homework", "stem")])
q("title", "ti02", "Where's the maths homework?", "maths homework", K, [
    ("school/maths-homework.md", "*", 2, "the file"),
    ("laptop/log/homework-tracker.txt", "*", 0, "maths homework done, many times"),
    ("school/newsletter-autumn.md", "§Homework club", 0, "maths homework, dense"),
], name=[("maths", "stem"), ("homework", "stem")])
q("title", "ti03", "Show me the pocket money note", "pocket money", K, [
    ("home/money/pocket-money.md", "*", 2, "the file"),
    ("laptop/budget-autumn.md", "§Kids", 0, "pocket money twice"),
], name=[("pocket", "stem"), ("money", "stem")])
q("title", "ti04", "Wren's birthday party plan", "birthday party", K, [
    ("home/birthday-party-wren.md", "*", 2, "the file"),
    ("home/calendar-november.md", "*", 0, "Ada's birthday party"),
], name=[("birthday", "stem"), ("party", "stem")])
q("title", "ti05", "The camping list", "camping list", K, [
    ("laptop/packing-lists/camping.md", "*", 2, "the file"),
    ("laptop/wishlist.md", "*", 0, "camping chairs on a list"),
], name=[("camping", "stem"), ("list", "none")])
q("title", "ti06", "The swimming lessons file", "swimming lessons", K, [
    ("school/swimming-lessons/autumn-term.md", "*", 2, "the file"),
    ("school/newsletter-autumn.md", "§Swimming", 0, "swimming lessons start"),
    ("school/class-notes-wren.md", "§Next term", 0, "swimming will resume"),
], name=[("swimming", "folder"), ("lessons", "folder")])
q("title", "ti07", "Art club notes", "art club", K, [
    ("school/art-club/autumn-projects.md", "*", 2, "the file"),
    ("laptop/club-timetable.md", "§Art club", 0, "art club times"),
], name=[("art", "folder"), ("club", "folder")])
q("title", "ti08", "Our reading list", "reading list", K, [
    ("laptop/reading-list.md", "*", 2, "the file"),
    ("school/reading-log-pip.md", "§Reading at home", 0, "reading every night"),
    ("school/newsletter-autumn.md", "§Reading list", 0, "the school's reading list"),
], name=[("reading", "stem"), ("list", "stem")])
q("title", "ti09", "School uniform list", "school uniform", K, [
    ("laptop/notes/uniform.md", "*", 2, "the file"),
    ("school/newsletter-autumn.md", "§Uniform", 0, "school uniform, label it"),
], name=[("school", "none"), ("uniform", "stem")])
q("title", "ti10", "பாட்டி கடிதங்கள் (Paati's letters)", "பாட்டி கடிதங்கள்", K, [
    ("home/tamil/பாட்டி-கடிதங்கள்.md", "*", 2, "the file; the Tamil words are in its name only"),
], name=[("பாட்டி", "stem"), ("கடிதங்கள்", "stem")])
q("title", "ti11", "Football stuff", "football", K, [
    ("laptop/clubs/football/match-days.md", "*", 2, "the file"),
    ("laptop/club-timetable.md", "§Football", 0, "football practice"),
], name=[("football", "folder")])

# ------------------------------------------------------------- phrase (10) --
# adjacent: the row index that holds the words in order; apart: the row index
# that holds them all, not adjacent (p07 reverses the two).

q("phrase", "p01", "How do we make hot chocolate?", "hot chocolate", K, [
    ("home/recipes/winter-drinks.md", "§Hot chocolate", 2, "the recipe"),
    ("home/fridge-notes.md", "§Shopping", 0, "chocolate, hot oven, chocolate"),
], adjacent=0, apart=1)
q("phrase", "p02", "Pip's solar system model?", "solar system model", K, [
    ("laptop/projects/pip-planet-model.md", "§What to make", 2, "the model"),
    ("home/roof-and-heating.md", "*", 0, "solar panels, heating system, model number"),
], adjacent=0, apart=1)
q("phrase", "p03", "When is the times tables test?", "times tables test", K, [
    ("school/maths-practice.md", "§Times tables test", 2, "Friday mornings"),
    ("laptop/meeting-notes-pta.md", "§Hall bookings", 0, "a test, booking times, tables"),
], adjacent=0, apart=1)
q("phrase", "p04", "Is there ice cream at the party?", "ice cream", K, [
    ("home/birthday-party-wren.md", "§Food", 2, "ice cream cake"),
    ("laptop/recipes-to-try.txt", "*", 0, "cream, then ice in the freezer"),
], adjacent=0, apart=1)
q("phrase", "p05", "When is the car boot sale?", "car boot sale", K, [
    ("home/weekend/sale-in-the-field.md", "*", 2, "Sunday from seven"),
    ("laptop/notes/car-garage.md", "§Boot", 0, "the boot of the car, on sale"),
], adjacent=0, apart=1)
q("phrase", "p06", "Is it fish fingers on Wednesday?", "fish fingers", K, [
    ("school/lunch-menu.md", "§Wednesday", 2, "fish fingers"),
    ("home/pets/fish-tank.md", "*", 0, "wash your fingers after feeding the fish"),
], adjacent=0, apart=1)
q("phrase", "p07", "Is it too hot for the dog to go out?", "hot dog", K, [
    ("home/pets/biscuit-the-dog.md", "§Hot days", 2, "hot ... dog, apart"),
    ("school/sports-day.md", "§Food stall", 0, "a hot dog stall, adjacent"),
], adjacent=1, apart=0, reversed=True)
q("phrase", "p08", "Find hot chocolate (every word)", "hot chocolate", W, [
    ("home/recipes/winter-drinks.md", "§Hot chocolate", 2, "the recipe"),
    ("home/fridge-notes.md", "§Shopping", 0, "chocolate, hot oven, chocolate"),
], adjacent=0, apart=1)
q("phrase", "p09", 'Find "hot chocolate"', "hot chocolate", P, [
    ("home/recipes/winter-drinks.md", "§Hot chocolate", 2, "the recipe"),
    ("home/fridge-notes.md", "§Shopping", 0, "excluded by the phrase"),
], adjacent=0, apart=1)
q("phrase", "p10", "When is after school club?", "after school club", K, [
    ("laptop/club-timetable.md", "§After school club", 2, "until six"),
    ("school/newsletter-autumn.md", "§Clubs", 0, "after lunch, every school day, a club"),
], adjacent=0, apart=1)

# ---------------------------------------------------------- negatives (14) --
# Nothing in the folders answers these; the rows name the distractors.

q("negatives", "cn1", "Any piano lessons?", "piano lessons", K, [
    ("laptop/wishlist.md", "*", 0, "a toy piano"),
    ("school/swimming-lessons/autumn-term.md", "*", 0, "lessons, swimming"),
], of="control")
q("negatives", "cn2", "When is the volcano trip?", "volcano trip", K, [
    ("school/volcano-project.md", "*", 0, "a volcano project"),
    ("school/trip-permission-museum.md", "*", 0, "a museum trip"),
], of="control")
q("negatives", "mn1", "Is there a dinosaur museum trip?", "dinosuar museum", K, [
    ("school/trip-permission-museum.md", "*", 0, "the Toy Museum"),
    ("school/dinosaur-topic.md", "*", 0, "the museum team"),
], of="misspelling")
q("negatives", "mn2", "Skating lessons?", "skateing lessons", K, [
    ("school/swimming-lessons/autumn-term.md", "*", 0, "lessons, swimming"),
], of="misspelling")
q("negatives", "on1", "Dinosaur eggs hatching?", "dinosaur eggs hatching", K, [
    ("school/dinosaur-topic.md", "*", 0, "dinosaurs, no eggs"),
    ("home/shopping-list.md", "*", 0, "eggs to buy"),
], of="morphology")
q("negatives", "on2", "Did we paint the fence?", "painting the fence", K, [
    ("school/art/year5-pottery.md", "*", 0, "paint a pot"),
    ("home/garden-diary.md", "=mended the fence", 0, "the fence was mended"),
], of="morphology")
q("negatives", "an1", "A crêpe recipe?", "crêpe recipe", K, [
    ("home/recipes/pancakes.md", "*", 0, "pancakes, not crêpes"),
], of="accent")
q("negatives", "an2", "Where's my résumé and its cover letter?", "résumé letter", K, [
    ("school/class-notes-wren.md", "§Next term", 0, "resume, the verb"),
    ("school/letters/letter-home-oct.txt", "*", 0, "a letter home from school"),
], of="accent")
q("negatives", "tn1", "ரயில் பயணம்? (a train journey?)", "ரயில் பயணம்", K, [
    ("laptop/tamil/tamil-stories.md", "§The journey", 0, "a long journey, no train"),
], of="tamil")
q("negatives", "tn2", "கடற்கரை அலைகள்? (waves at the beach?)", "கடற்கரை அலைகள்", K, [
    ("home/tamil/பாட்டி-கடிதங்கள்.md", "§Sea", 0, "the sea and its waves, not a beach visit"),
], of="tamil")
q("negatives", "tin1", "Music homework", "music homework", K, [
    ("home/music/recorder-practice.md", "*", 0, "music, by folder only"),
    ("laptop/log/homework-tracker.txt", "*", 0, "homework, no music"),
], of="title")
q("negatives", "tin2", "Garden plans", "garden plans", K, [
    ("laptop/plans/half-term-plans.md", "*", 0, "plans, a week off"),
    ("home/garden-diary.md", "*", 0, "the garden diary"),
], of="title")
q("negatives", "pn1", "Ice skating?", "ice skating", K, [
    ("laptop/recipes-to-try.txt", "*", 0, "ice in the freezer"),
    ("home/birthday-party-wren.md", "§Food", 0, "ice cream"),
], of="phrase")
q("negatives", "pn2", "Cream tea?", "cream tea", K, [
    ("home/birthday-party-wren.md", "§Food", 0, "ice cream"),
    ("laptop/recipes-to-try.txt", "*", 0, "strawberries and cream"),
], of="phrase")

# ------------------------------------------------------ title-heldout (8) --
# S5-T2, orchestrator ruling 5 on its plan: title-intent rows held out from the
# weight that S5-T2 chose on ti01-ti11, written and judged before any ranking
# code existed and before any run of these queries. Existing files only, so no
# other row's numbers move. The generator also asserts that no query word here
# is a query word of ti01-ti11 or a word of their targets' paths (root included).

q("title-heldout", "th01", "Joss's garden diary", "garden diary", K, [
    ("home/garden-diary.md", "*", 2, "the file"),
    ("school/science-homework.md", "*", 0, "a bean diary, diary four times"),
    ("home/chores.md", "§Garden jobs", 0, "garden jobs"),
    ("school/newsletter-autumn.md", "§Dates for the diary", 0, "dates for the diary"),
], name=[("garden", "stem"), ("diary", "stem")])
q("title-heldout", "th02", "What are our house rules?", "house rules", K, [
    ("home/house-rules.md", "*", 2, "the file"),
    ("school/class-rules.md", "*", 0, "the class rules, rules twice"),
    ("laptop/budget-autumn.md", "§House", 0, "the house budget"),
], name=[("house", "stem"), ("rules", "stem")])
q("title-heldout", "th03", "The questions the kids asked", "kids questions", K, [
    ("laptop/kids-questions.md", "*", 2, "the file"),
    ("laptop/budget-autumn.md", "§Kids", 0, "kids twice"),
    ("school/science-homework.md", "§Questions to answer", 0, "homework questions"),
], name=[("kids", "stem"), ("questions", "stem")])
q("title-heldout", "th04", "What's on the November calendar?", "november calendar", K, [
    ("home/calendar-november.md", "*", 2, "the file"),
    ("laptop/archive/old-term-dates.md", "*", 0, "last year's calendar, November"),
    ("home/garden-diary.md", "§November", 0, "November thirty times"),
], name=[("november", "stem"), ("calendar", "stem")])
q("title-heldout", "th05", "The holiday file", "holiday", K, [
    ("home/holiday/seaside-packing.md", "*", 2, "the file"),
    ("laptop/budget-autumn.md", "=Holiday pot", 0, "the holiday pot"),
    ("laptop/archive/old-term-dates.md", "*", 0, "last year's October holiday"),
    ("school/class-notes-wren.md", "§Next term", 0, "after the October holiday"),
], name=[("holiday", "folder")])
q("title-heldout", "th06", "Open my ideas folder", "ideas", K, [
    ("laptop/ideas/kitchen-science.md", "*", 2, "the file"),
    ("laptop/plans/half-term-plans.md", "§Rainy day ideas", 0, "rainy day ideas"),
    ("school/science-fair.md", "§Ideas", 0, "science fair ideas"),
    ("school/maths-practice.md", "=Practice ideas", 0, "practice ideas"),
], name=[("ideas", "folder")])
q("title-heldout", "th07", "Pip's music things", "music", K, [
    ("home/music/recorder-practice.md", "*", 2, "the file"),
    ("school/notes-from-phone.txt", "*", 0, "the music room"),
    ("school/class-notes-pip.md", "=music room", 0, "the music room"),
], name=[("music", "folder")])
q("title-heldout", "th08", "Our health records", "health", K, [
    ("home/health/doctor-visits.md", "*", 2, "the file; health is in its folder name only"),
], name=[("health", "folder")])

q("negatives", "thn1", "The holiday photos?", "holiday photos", K, [
    ("home/holiday/seaside-packing.md", "*", 0, "the holiday folder, no photos"),
    ("school/newsletter-autumn.md", "§Dates for the diary", 0, "a school photo day"),
], of="title-heldout")
q("negatives", "thn2", "Is there a music exam?", "music exam", K, [
    ("home/music/recorder-practice.md", "*", 0, "music by folder only, no exam"),
    ("school/tamil/tamil-class.md", "§Exam", 0, "a Tamil exam"),
], of="title-heldout")
