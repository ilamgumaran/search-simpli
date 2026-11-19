"""S6-T8 verifier: an edge corpus for the one-byte offsets (invented text). edge_gen.py OUT_DIR"""
import sys
from pathlib import Path

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
F = {}


def tok(n, base="q"):
    letters = "abcdefghijklmnopqrstuvwxyz"
    return base + "".join(letters[i % 26] for i in range(n - len(base)))


# lengths 1..20, 30, 64, 127, 128, 300, 16384 (varint 1, 2 and 3 bytes)
F["len.txt"] = "\n".join("len%d %s end" % (n, tok(n, "l")) for n in list(range(1, 21)) + [30, 64, 127, 128, 300]) + "\n"
F["len-huge.txt"] = "start " + tok(16384, "h") + " stop\n"
# gaps of 1..20, 64, 128, 300 spaces (zigzag 2..40, ...), and a tab run
F["gaps.txt"] = "\n".join("g%d" % n + " " * n + "w%d" % n for n in list(range(1, 21)) + [64, 128, 300]) + "\n"
F["gap-huge.txt"] = "first" + " " * 20000 + "second\n"
# exactly 7 and 8 spaces after a token at the chunk start: gap z 14 and 16; 7.5 is impossible, so z15 needs a negative gap
F["gap7.txt"] = "aa" + " " * 7 + "bb\n"
F["gap8.txt"] = "aa" + " " * 8 + "bb\n"
# tokens of 14, 15, 16 codepoints first and last in a file (chunk start and end)
for n in (14, 15, 16):
    F["edge%d.txt" % n] = tok(n, "s") + " middle " + tok(n, "e")
# NFC regions that make negative gaps: a + k x U+037E + U+2126 (gap -(k+2))
for k in range(0, 10):
    F["neg%d.txt" % k] = "x a" + ";" * k + "Ω y\n"
# combining marks, Hangul jamo, Tamil
F["combining.txt"] = "café résumé é" * 3 + " ñö 각 가\n"
F["tamil.txt"] = "பள்ளி வீட்டுப்பாடம் நாளை கணிதம் அறிவியல் " * 4 + "\n" + "தமிழ்" * 10 + "\n"
F["tamil-long.md"] = "# தலைப்பு\n\n" + ("மாணவர்கள் ஆசிரியர் பாடம் " * 200) + "\n"
# zero tokens and one token
F["punct.txt"] = "!!! ... ??? --- ***\n"
F["one.txt"] = "lonely\n"
F["one-long.txt"] = tok(40, "z") + "\n"
# overlapping chunks: many long lines so the line window overlaps
F["overlap.txt"] = "".join("line %d %s alpha beta gamma %s\n" % (i, tok(15 + i % 4, "o"), "pad " * 30) for i in range(200))
F["overlap.md"] = "".join("## Section %d\n\n%s %s\n\n" % (i, ("para %d " % i) * 60, tok(16, "m")) for i in range(40))
# mixed: emoji and variation selectors (dropped before tokenizing)
F["emoji.txt"] = "smile \U0001F600 heart ❤️ star ⭐ word\n"
# both fields escape: a gap of 8+ and a length of 15+, and a huge pair
F["both.txt"] = "x" + " " * 8 + tok(15, "b") + "\n" + "y" + " " * 30 + tok(21, "c") + " " * 9000 + tok(500, "d") + "\n"
# many hits for paging: one common word in many lines
F["many.txt"] = "".join("common filler%d common\n" % i for i in range(3000))
for name, text in F.items():
    (out / name).write_text(text, encoding="utf-8")
print(len(F), "files")
