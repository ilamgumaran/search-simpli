#!/usr/bin/env python3
"""Generate an ordinary-English-prose corpus of Markdown notes (S6-T3).

The sibling of `scripts/gen_timing_corpus.py` for the index-size measurement
(`docs/tasks/S6-T3.md` ruling 1b). The timing corpus draws pseudo-words from a
24,000-term vocabulary, which inflates the lexical section; this corpus is
ordinary English instead: a few thousand distinct real words (a base list of
common English words written below, with their plural, verb, comparative,
agent and adverb forms)
drawn with a Zipf-Mandelbrot law, so a handful of function words make up a
large share of the tokens and most words are rare, as in prose.

**The text is invented.** No sentence is quoted from anywhere: every sentence
is a random draw of words, so the notes read as word salad with English
statistics. Names of people and places do not occur.

**The notes.** Each file is a Markdown note of mixed length: the word count is
log-normal (median 160 words, clamped to 15..9,000), so most notes are short
and a few run to tens of kilobytes and span many chunks. A note has an H1
title, H2 sections every few paragraphs, paragraphs of two to seven sentences,
sometimes a bulleted list, and one note in five starts with YAML front matter.
Half of the notes are hard-wrapped at 72-80 columns and half keep each
paragraph on one line, so both line shapes reach the chunkers. Files sit in
topic folders (`<topic>/<slug>-NNNNN.md`).

Deterministic: the same arguments write the same bytes.

Usage: python3 scripts/gen_prose_corpus.py <out_dir> [file_count]
"""
import math
import random
import sys
from pathlib import Path

# Function words, most frequent first (their order is their Zipf rank).
FUNCTION = """
the of and to a in is that it for was on with as be this by are at not have
from or but they an you which we one were all there can had their so has if
more when what will been would about no out up who other into some them its
then only could these than also two any may each first most our over such
where after new very just those should because between many both through how
here well even back much under while same before still never down every own
must off last again might too always around few often since without however
another less once later during next three within upon though rather almost
each enough perhaps nothing something everything anything someone nobody
yet already soon quite whether against among along across toward behind
""".split()

NOUNS = """
time year way day thing world life hand part place case week system program
question work number night point home water room area money story fact month
lot right study book eye job word business issue side kind head house service
friend power hour game line end member law car city community name team minute
idea body information back parent face level office door health person art war
history party result change morning reason research girl guy moment air teacher
force education foot boy age policy process music market sense nation plan
college interest death experience effect use class control care field
development role effort rate heart drug show leader light voice wife police
mind price report decision son view relationship town road arm difference value
building action model season society tax director position player record paper
space ground form event official matter center couple site project activity
star table need court oil situation cost industry figure street image phone data
picture practice piece land product doctor wall patient worker news test movie
north love support technology step baby computer type attention film tree source
organization hair window evidence population site camera garden kitchen river
lake mountain island forest valley field meadow harbor bridge station library
museum theater market bakery school garden orchard vineyard village county
season winter summer spring autumn weather rain snow wind storm cloud sunlight
morning evening afternoon weekend holiday journey trip ticket map route path
trail road highway train bus bicycle boat ship plane airport engine wheel motor
battery cable wire switch lamp candle fire stove oven kettle pot pan plate bowl
cup glass bottle jar spoon fork knife napkin towel blanket pillow bed chair
desk shelf drawer cabinet closet basket box bag pocket coat jacket shirt sweater
boot shoe sock glove hat scarf umbrella ring watch clock calendar diary letter
envelope stamp parcel package note list draft chapter page paragraph sentence
title margin index catalog folder file archive record ledger receipt invoice
budget account balance payment salary wage price discount coupon bill coin
note recipe flour sugar butter salt pepper onion garlic tomato potato carrot
pea bean rice bread cheese apple pear plum cherry lemon orange grape melon
berry nut seed leaf branch root stem flower blossom petal grass moss stone
rock sand soil clay brick timber plank nail screw hammer saw drill ladder rope
chain hook knot thread needle fabric cotton wool silk linen leather paint brush
canvas sketch drawing pattern shape circle square triangle line curve angle
edge corner surface layer texture color shade tone sound noise silence echo
song melody rhythm chord note instrument piano guitar violin drum flute choir
band concert lesson exercise practice skill habit routine schedule deadline
meeting agenda minute summary outline goal target milestone task chore errand
appointment visit guest neighbor cousin uncle aunt grandparent sibling child
student classmate coach mentor volunteer stranger crowd audience committee
council board panel group club circle network channel signal message reply
question answer problem solution method approach theory principle rule
exception example detail aspect feature element factor component structure
framework layer module function variable parameter value result output input
error warning failure success progress improvement measure metric sample
survey experiment observation hypothesis conclusion argument claim evidence
reason cause consequence outcome choice option preference priority balance
risk chance luck fortune habit memory dream thought feeling mood emotion
patience courage kindness honesty trust respect pride shame fear hope joy
sorrow anger calm comfort worry doubt belief opinion attitude perspective
""".split()

VERBS = """
say make go take come see know get give find think tell become show leave feel
put bring begin keep hold write stand hear let mean set meet run pay sit speak
lie lead read grow lose fall send build understand draw break spend cut rise
drive buy wear choose seek throw catch deal win forget sell sleep teach eat
drink sing swim fly ride hide shake steal stick strike swing wake shine hang
ask work seem call try need want look use help talk turn start move like live
believe happen include continue change watch follow stop create speak allow add
open walk offer remember consider appear wait serve die expect stay reach kill
remain suggest raise pass report decide pull return explain hope develop carry
receive agree support hit produce cover describe point plan visit fill notice
check finish manage prepare repair clean cook bake wash fold paint plant water
gather collect sort count measure weigh compare mix stir pour boil roast slice
chop peel taste smell listen climb wander travel arrive depart pack unpack
borrow lend share trade order deliver post print sign mark label note record
store save delete copy paste search browse download upload install update
restart arrange organize schedule cancel postpone confirm remind answer reply
question wonder imagine guess solve test try improve practice train exercise
stretch rest relax breathe laugh smile cry shout whisper argue discuss debate
explain describe summarize outline revise edit publish review approve reject
accept refuse invite welcome greet thank forgive apologize promise warn advise
encourage praise complain worry hurry linger pause resume repeat return
""".split()

ADJECTIVES = """
good new first last long great little own other old right big high different
small large next early young important few public bad same able late hard major
better economic strong possible whole free military true federal international
full special easy clear recent certain personal open red difficult available
likely short single medical current wrong private past foreign fine common poor
natural significant similar hot dead central happy serious ready simple left
physical general environmental financial blue democratic dark various entire
close legal religious cold final main green nice huge popular traditional
cultural quiet loud bright dull warm cool wet dry soft rough smooth sharp blunt
heavy light thick thin narrow wide deep shallow fresh stale sweet sour bitter
salty plain fancy neat messy tidy busy idle calm wild gentle brave shy proud
humble eager careful careless curious patient polite rude honest clever wise
silly odd strange familiar rare frequent regular steady sudden slow quick
rapid gradual early modern ancient distant nearby empty crowded rich cheap
expensive useful useless helpful harmless safe dangerous healthy tired hungry
thirsty sleepy awake alive brief lengthy tiny vast golden silver wooden metal
plastic paper glass woolen cotton leafy rocky sandy muddy dusty snowy rainy
windy sunny cloudy foggy stormy frozen melted broken fixed loose tight
""".split()

ADVERBS = """
now then also just only very really here there still even back well never
always often sometimes usually rarely seldom almost nearly quite rather
already soon later today tomorrow yesterday tonight again once twice instead
together apart away ahead behind inside outside upstairs downstairs perhaps
maybe probably certainly surely clearly simply mostly partly fully hardly
""".split()

TOPICS = [
    "garden", "kitchen", "reading", "travel", "music", "repairs", "budget",
    "school", "projects", "weather", "health", "journal", "recipes", "work",
    "meetings", "hobbies", "books", "errands", "letters", "ideas",
]


def _plural(word: str) -> str:
    if word.endswith(("s", "x", "z", "ch", "sh")):
        return word + "es"
    if word.endswith("y") and word[-2:-1] not in "aeiou":
        return word[:-1] + "ies"
    return word + "s"


def _past(word: str) -> str:
    if word.endswith("e"):
        return word + "d"
    if word.endswith("y") and word[-2:-1] not in "aeiou":
        return word[:-1] + "ied"
    return word + "ed"


def _gerund(word: str) -> str:
    if word.endswith("ie"):
        return word[:-2] + "ying"
    if word.endswith("e") and not word.endswith(("ee", "ye", "oe")):
        return word[:-1] + "ing"
    return word + "ing"


def _er(word: str) -> str:
    """Comparative of an adjective, agent noun of a verb."""
    if word.endswith("e"):
        return word + "r"
    if word.endswith("y") and word[-2:-1] not in "aeiou":
        return word[:-1] + "ier"
    return word + "er"


def _adverb(word: str) -> str:
    if word.endswith("le"):
        return word[:-1] + "y"
    if word.endswith("y") and word[-2:-1] not in "aeiou":
        return word[:-1] + "ily"
    if word.endswith("ic"):
        return word + "ally"
    return word + "ly"


def build_vocabulary() -> list[str]:
    """Every distinct surface form, in Zipf rank order: the function words in
    their listed order, then every content form in a fixed shuffled order
    (base forms are drawn ahead of their inflections, so they rank higher)."""
    seen: set[str] = set()
    ordered: list[str] = []

    def add(words):
        for word in words:
            if word not in seen:
                seen.add(word)
                ordered.append(word)

    add(FUNCTION)
    base: list[str] = []
    inflected: list[str] = []
    for noun in dict.fromkeys(NOUNS):
        base.append(noun)
        inflected.append(_plural(noun))
    for verb in dict.fromkeys(VERBS):
        base.append(verb)
        inflected += [_plural(verb), _past(verb), _gerund(verb), _er(verb)]
    for adjective in dict.fromkeys(ADJECTIVES):
        base.append(adjective)
        inflected += [_adverb(adjective), _er(adjective)]
    base += ADVERBS
    order = random.Random(20261116)
    order.shuffle(base)
    order.shuffle(inflected)
    # Interleave: one inflected form after every two base forms, so ranks mix.
    mixed: list[str] = []
    bi = ii = 0
    while bi < len(base) or ii < len(inflected):
        for _ in range(2):
            if bi < len(base):
                mixed.append(base[bi])
                bi += 1
        if ii < len(inflected):
            mixed.append(inflected[ii])
            ii += 1
    add(mixed)
    return ordered


class ZipfSampler:
    """Draws ranks from p(r) proportional to 1 / (r + 2.7) ** 1.05."""

    def __init__(self, words: list[str]):
        self.words = words
        weights = [1.0 / (rank + 2.7) ** 1.05 for rank in range(1, len(words) + 1)]
        total = 0.0
        self.cumulative = []
        for weight in weights:
            total += weight
            self.cumulative.append(total)
        self.total = total

    def draw(self, rng: random.Random) -> str:
        target = rng.random() * self.total
        lo, hi = 0, len(self.cumulative) - 1
        while lo < hi:
            mid = (lo + hi) // 2
            if self.cumulative[mid] < target:
                lo = mid + 1
            else:
                hi = mid
        return self.words[lo]


def sentence(rng: random.Random, sampler: ZipfSampler) -> str:
    words = [sampler.draw(rng) for _ in range(rng.randint(6, 24))]
    if len(words) > 9 and rng.random() < 0.4:
        words[rng.randint(3, len(words) - 4)] += ","
    text = " ".join(words)
    end = "." if rng.random() < 0.9 else ("?" if rng.random() < 0.6 else "!")
    return text[0].upper() + text[1:] + end


def wrap(text: str, width: int) -> list[str]:
    lines, current = [], ""
    for word in text.split(" "):
        if current and len(current) + 1 + len(word) > width:
            lines.append(current)
            current = word
        else:
            current = word if not current else current + " " + word
    if current:
        lines.append(current)
    return lines


def title_words(rng: random.Random, sampler: ZipfSampler, count: int) -> list[str]:
    words: list[str] = []
    while len(words) < count:
        word = sampler.draw(rng)
        if word not in FUNCTION[:60]:
            words.append(word)
    return words


def make_note(rng: random.Random, sampler: ZipfSampler, index: int, topic: str) -> tuple[str, str]:
    target = int(min(9000, max(15, rng.lognormvariate(math.log(160), 1.0))))
    wrap_width = rng.randint(72, 80) if rng.random() < 0.5 else 0
    name = title_words(rng, sampler, rng.randint(2, 3))
    out: list[str] = []
    if rng.random() < 0.2:
        tags = ", ".join(title_words(rng, sampler, rng.randint(1, 3)))
        out += ["---", f"title: {' '.join(name)}", f"tags: [{tags}]",
                f"day: {1 + index % 28}", "---", ""]
    out += [f"# {' '.join(name).capitalize()}", ""]
    written = 0
    paragraphs_in_section = 0
    while written < target:
        if paragraphs_in_section >= rng.randint(3, 6):
            out += [f"## {' '.join(title_words(rng, sampler, rng.randint(1, 4))).capitalize()}", ""]
            paragraphs_in_section = 0
        if rng.random() < 0.12:
            for _ in range(rng.randint(2, 6)):
                item = " ".join(sampler.draw(rng) for _ in range(rng.randint(2, 9)))
                out.append(f"- {item}")
                written += len(item.split())
            out.append("")
        else:
            text = " ".join(sentence(rng, sampler) for _ in range(rng.randint(2, 7)))
            written += len(text.split())
            out += (wrap(text, wrap_width) if wrap_width else [text]) + [""]
        paragraphs_in_section += 1
    slug = "-".join(name)
    return f"{topic}/{slug}-{index:05d}.md", "\n".join(out).rstrip("\n") + "\n"


def main() -> None:
    out_dir = Path(sys.argv[1])
    file_count = int(sys.argv[2]) if len(sys.argv) > 2 else 1000
    out_dir.mkdir(parents=True, exist_ok=True)
    vocabulary = build_vocabulary()
    sampler = ZipfSampler(vocabulary)
    rng = random.Random(20261116)
    total = 0
    for index in range(file_count):
        relative, text = make_note(rng, sampler, index, TOPICS[index % len(TOPICS)])
        path = out_dir / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        data = text.encode("utf-8")
        path.write_bytes(data)
        total += len(data)
    print(f"wrote {file_count} notes ({total} bytes) under {out_dir}: "
          f"{len(vocabulary)} distinct word forms")


if __name__ == "__main__":
    main()
