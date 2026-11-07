"""S5-T4: K, the key function of fold-groups-v1, in the Python mirror
(`src/search_platform/analyzer_v3.py`, docs/tasks/S5-T4.md rulings 2-5). The
Zig side (`zig/src/fold.zig`) equals the golden this mirror writes."""

import subprocess
import sys
import unicodedata
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from search_platform import analyzer_v3 as v3  # noqa: E402
from search_platform._fold import FOLD, UNICODE_VERSION  # noqa: E402


def K(token: str, parts: str = "FAST") -> list[str]:
    return list(v3.key_terms(token, parts))


class FoldTableTests(unittest.TestCase):
    def test_table_regenerates_byte_for_byte(self):
        if unicodedata.unidata_version != UNICODE_VERSION:
            self.skipTest("table generated with Unicode " + UNICODE_VERSION)
        fresh = subprocess.run([sys.executable, str(ROOT / "scripts" / "gen_unicode_tables.py"), "--python-fold"],
                               capture_output=True, text=True, check=True).stdout
        self.assertEqual(fresh, (ROOT / "src" / "search_platform" / "_fold.py").read_text(encoding="utf-8"))

    def test_zig_tables_regenerate_byte_for_byte(self):
        """zig/src/unicode_tables.zig, fold table included, is what the generator writes."""
        if unicodedata.unidata_version != UNICODE_VERSION:
            self.skipTest("table generated with Unicode " + UNICODE_VERSION)
        fresh = subprocess.run([sys.executable, str(ROOT / "scripts" / "gen_unicode_tables.py")],
                               capture_output=True, text=True, check=True).stdout
        self.assertEqual(fresh, (ROOT / "zig" / "src" / "unicode_tables.zig").read_text(encoding="utf-8"))

    def test_table_counts(self):
        self.assertEqual(len(FOLD), 6158)
        self.assertEqual(sum(1 for v in FOLD.values() if len(v) > 1), 1303)
        self.assertEqual(max(len(v) for v in FOLD.values()), 18)
        self.assertNotIn(0xD800, FOLD)


class GoldenTests(unittest.TestCase):
    def test_golden_regenerates_byte_for_byte(self):
        """fixtures/analyzer-v3-golden.json is what the mirror writes today."""
        if unicodedata.unidata_version != UNICODE_VERSION:
            self.skipTest("golden generated with Unicode " + UNICODE_VERSION)
        fresh = subprocess.run([sys.executable, str(ROOT / "scripts" / "gen_analyzer_v3_golden.py")],
                               capture_output=True, text=True, check=True).stdout
        self.assertEqual(fresh, (ROOT / "fixtures" / "analyzer-v3-golden.json").read_text(encoding="utf-8"))

    def test_golden_holds_every_set(self):
        import json
        golden = json.loads((ROOT / "fixtures" / "analyzer-v3-golden.json").read_text(encoding="utf-8"))
        self.assertEqual(set(golden["sets"]), {"j2", "family-folder", "timing-10k", "fold-table", "traps"})
        self.assertEqual(golden["sets"]["fold-table"]["terms"], len(FOLD))
        self.assertEqual(golden["count"]["terms"], len(golden["same"]) + len(golden["changed"]))
        changed = dict((t, k) for t, k in golden["changed"])
        self.assertEqual(changed["½"], ["1", "2"])
        self.assertEqual(changed["மரங்கள்"], ["மரம்"])
        self.assertIn("glasses", golden["same"])


class KTests(unittest.TestCase):
    def test_fold_traps(self):
        """Ruling 2's measured traps."""
        for token, terms in (("ｇｏｇｇｌｅｓ", ["goggle"]), ("ﬂute", ["flute"]), ("１２", ["12"]),
                             ("straße", ["strasse"]), ("Ⅻ", ["xii"]), ("x²", ["x2"]), ("½", ["1", "2"])):
            self.assertEqual(K(token), terms, token)
        self.assertEqual(K("ｇｏｇｇｌｅｓ", "F"), ["goggles"])
        self.assertEqual(K("Straße", "F"), ["strasse"])
        self.assertEqual(K("Straße", "AST"), ["straße"])  # without F the piece is v2's simple fold

    def test_marks_traps(self):
        """Ruling 3's measured traps and its rule: marks after another base stay."""
        for token, term in (("résumé", "resume"), ("crêpe", "crepe"), ("øre", "ore"), ("łódź", "lodz"),
                            ("æsop", "aesop"), ("frühling", "fruhling"), ("noël", "noel")):
            self.assertEqual(K(token, "FA"), [term], token)
        self.assertEqual(K("ά", "FA"), ["ά"])  # Greek tonos after a Greek base
        self.assertEqual(K("கணினி", "FA"), ["கணினி"])
        self.assertEqual(K("cafe", "FA"), ["cafe"])
        # the nearest preceding non-mark code point: a mark outside U+0300-U+036F
        # between the base and an accent does not hide the Latin base
        self.assertEqual(v3.fold_marks("a⃗́"), "a⃗")

    def test_plural_rules(self):
        """Ruling 4's rules, keep list, known misses and known merge."""
        cases = {"ponies": "pony", "ties": "tie", "boxes": "box", "classes": "class", "lunches": "lunch",
                 "potatoes": "potato", "shoes": "shoe", "toes": "toe", "tests": "test", "rides": "ride",
                 "glass": "glass", "bus": "bus", "virus": "virus", "tennis": "tennis", "gas": "gas",
                 "buses": "buse", "caches": "cach", "headaches": "headach", "movies": "movy",
                 "cookies": "cooky", "leaves": "leave", "abs": "abs", "ab": "ab"}
        for word, stem in cases.items():
            self.assertEqual(v3.stem_plural(word), stem, word)
        for word in v3.PLURAL_KEEP:
            self.assertEqual(K(word), [word], word)
        self.assertEqual(len(v3.PLURAL_KEEP), 50)
        self.assertEqual(v3.stem_plural("cafés"), "cafés")  # not [a-z]
        self.assertEqual(K("cafés"), ["cafe"])  # A first, then S
        self.assertEqual(v3.stem_plural("s" * 50), "s" * 50)

    def test_tamil_rules(self):
        """Ruling 5's rules, conditions, guards, keep list and known misses."""
        cases = {"மரங்கள்": "மரம்", "பழங்கள்": "பழம்", "புத்தகங்கள்": "புத்தகம்", "யானைகள்": "யானை",
                 "பாடல்கள்": "பாடல்", "மரத்தில்": "மரம்", "நூலகத்தில்": "நூலகம்", "மரத்தின்": "மரம்",
                 "கடைக்கு": "கடை", "பள்ளிக்கு": "பள்ளி", "தேர்வுக்கு": "தேர்வு", "பள்ளியில்": "பள்ளி",
                 "பாட்டியின்": "பாட்டி", "காலை": "காலை", "நாளை": "நாளை", "தேர்வு": "தேர்வு",
                 "நாட்கள்": "நாட்", "சொற்கள்": "சொற்", "கடலுக்கு": "கடலு", "வீட்டுக்கு": "வீட்டு"}
        for word, stem in cases.items():
            self.assertEqual(K(word), [stem], word)
        for word in v3.TAMIL_KEEP:
            self.assertEqual(K(word), [word], word)
        self.assertEqual(K("கள்"), ["கள்"])  # the result would keep no Tamil letter
        self.assertEqual(K("மக்கு"), ["மக்கு"])  # க்கு after a consonant: no vowel sign
        self.assertEqual(K("மரம்கள்", "S"), ["மரம்கள்"])  # S never touches Tamil

    def test_resplit_key(self):
        self.assertEqual(v3.key("½"), "1 2")
        self.assertEqual(v3.key("glasses"), "glasses")
        self.assertEqual(v3.key("Boxes", "S"), "box")

    def test_parts_alone(self):
        self.assertEqual(K("Écoles", "F"), ["écoles"])
        self.assertEqual(K("Écoles", "A"), ["ecoles"])
        self.assertEqual(K("Écoles", "S"), ["écoles"])
        self.assertEqual(K("Écoles", "FAS"), ["ecole"])
        self.assertEqual(K("மரங்கள்", "F"), ["மரங்கள்"])
        self.assertEqual(K("மரங்கள்", "T"), ["மரம்"])

    def test_reads_only_its_token(self):
        """Determinism: the same token gives the same terms with the cache cleared."""
        tokens = ["Straße", "½", "résumé", "ponies", "மரங்கள்", "ｇｏｇｇｌｅｓ"]
        first = [K(t) for t in tokens]
        v3.key_terms.cache_clear()
        self.assertEqual([K(t) for t in reversed(tokens)], list(reversed(first)))


def write(root: Path, files: dict) -> None:
    for path, text in files.items():
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")


class FoldGroupsTests(unittest.TestCase):
    """fold-groups-v1 in the reference (ruling 10); since S5-T4 Phase 2 the
    default is `fold="FAST"`, as the engine's."""

    def test_groups_trigger_order_and_the_default_is_on(self):
        import tempfile
        from search_platform.core import build_index, fold_groups, search
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write(root, {"a.md": "Two ponies in the field.", "b.md": "One pony, one pony.", "c.md": "Ponies and a pony.",
                         "d.md": "Rain."})
            index = build_index(root)
            self.assertEqual(fold_groups(index, "pony"), {"pony": ["pony", "ponies"]})
            self.assertEqual(fold_groups(index, "ponies"), {"ponies": ["ponies", "pony"]})
            self.assertEqual(fold_groups(index, "rain"), {})  # the term alone: no group
            plain = search(index, "ponies", retrieval_mode="lexical", fold="")
            self.assertEqual({h["citation"]["path"] for h in plain}, {"a.md", "c.md"})
            grouped = search(index, "ponies", retrieval_mode="lexical")
            self.assertEqual({h["citation"]["path"] for h in grouped}, {"a.md", "b.md", "c.md"})
            self.assertEqual(search(index, "ponies", retrieval_mode="lexical", fold="FAST"), grouped)
            self.assertEqual(search(index, "rain", retrieval_mode="lexical"),
                             search(index, "rain", retrieval_mode="lexical", fold=""))

    def test_a_grouped_term_is_not_also_expanded_by_fuzzy(self):
        import tempfile
        from search_platform.core import _query_groups, build_index
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write(root, {"a.md": "The dinosaur bones.", "b.md": "Some bones."})
            index = build_index(root)
            chunks = index["chunks"]
            # boxes: no file holds it; fuzzy-v1 alone reaches bones (plant P9')
            self.assertEqual(_query_groups(chunks, chunks, ["boxes"], (), fold=""), {"boxes": (("bones", 1.0),)})
            write(root, {"c.md": "A box of crayons."})
            index = build_index(root)
            chunks = index["chunks"]
            self.assertEqual(_query_groups(chunks, chunks, ["boxes"], (), fold="FAST"), {"boxes": (("box", 1.0),)})

    def test_privacy_and_the_prefix_narrow_membership(self):
        import tempfile
        from search_platform.core import build_index, fold_groups
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write(root, {"private/plan.md": "The secret ponies.", "public/notes.md": "One pony.",
                         "other/more.md": "Pony rides."})
            rules = [{"path_prefix": "private/", "required_labels": ["tenant:x"]}]
            index = build_index(root, access_rules=rules)
            self.assertEqual(fold_groups(index, "pony"), {})  # ponies only in a hidden chunk
            self.assertEqual(fold_groups(index, "pony", principal_labels=["tenant:x"]), {"pony": ["pony", "ponies"]})
            self.assertEqual(fold_groups(index, "ponies", principal_labels=["tenant:x"], path_prefix="public/"),
                             {"ponies": ["pony"]})

    def test_title_terms_are_members(self):
        import tempfile
        from search_platform.core import build_index, fold_groups, search
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write(root, {"days-out/seals.md": "Grey ones on the rocks.", "other.md": "Nothing much."})
            index = build_index(root, filename_index=True)
            self.assertEqual(fold_groups(index, "seal"), {"seal": ["seals"]})
            for field in ("content", "both"):
                hits = search(index, "seal", retrieval_mode="lexical", search_field=field, fold="FAST")
                self.assertEqual([h["citation"]["path"] for h in hits], ["days-out/seals.md"], field)
            self.assertEqual(search(index, "seal", retrieval_mode="lexical", search_field="filename", fold="FAST"), [])


if __name__ == "__main__":
    unittest.main()
