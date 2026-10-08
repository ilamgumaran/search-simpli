import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from src.search_platform.core import build_index, save_index
from src.search_platform.interchange import SUPPORTED_ANALYZER_IDS, build_interchange


ROOT = Path(__file__).resolve().parents[1]
SCHEMA_PATH = ROOT / "contracts" / "snapshot-interchange.schema.json"


def schema_errors(value, schema: dict, where: str = "$") -> list[str]:
    """Validate against the JSON Schema keywords the interchange contract uses.

    No third-party validator is a dependency of this repository, so this
    covers exactly the keywords in `snapshot-interchange.schema.json`
    (type, const, enum, required, properties, additionalProperties, items,
    minimum, minLength, uniqueItems) and fails on any other keyword, so a
    later schema edit cannot be silently ignored here.
    """
    known = {"$schema", "$id", "title", "type", "const", "enum", "required", "properties",
             "additionalProperties", "items", "minimum", "minLength", "uniqueItems",
             "description"}
    unknown = set(schema) - known
    if unknown:
        return [f"{where}: validator does not implement {sorted(unknown)}"]
    errors: list[str] = []
    kind = schema.get("type")
    checks = {
        "object": lambda v: isinstance(v, dict),
        "array": lambda v: isinstance(v, list),
        "string": lambda v: isinstance(v, str),
        "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
        "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    }
    if kind is not None and not checks[kind](value):
        return [f"{where}: expected {kind}"]
    if "const" in schema and value != schema["const"]:
        errors.append(f"{where}: {value!r} is not const {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{where}: {value!r} is not one of {schema['enum']!r}")
    if "minimum" in schema and value < schema["minimum"]:
        errors.append(f"{where}: {value!r} < minimum {schema['minimum']}")
    if "minLength" in schema and len(value) < schema["minLength"]:
        errors.append(f"{where}: shorter than {schema['minLength']}")
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{where}: missing {key}")
        properties = schema.get("properties", {})
        for key, item in value.items():
            if key in properties:
                errors.extend(schema_errors(item, properties[key], f"{where}.{key}"))
            elif schema.get("additionalProperties") is False:
                errors.append(f"{where}: unexpected {key}")
    if isinstance(value, list):
        if schema.get("uniqueItems") and len({json.dumps(v, sort_keys=True) for v in value}) != len(value):
            errors.append(f"{where}: items are not unique")
        if "items" in schema:
            for index, item in enumerate(value):
                errors.extend(schema_errors(item, schema["items"], f"{where}[{index}]"))
    return errors


class InterchangeTests(unittest.TestCase):
    def test_exports_citations_vectors_and_model_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "car.md").write_text("A car is a road vehicle with wheels.", encoding="utf-8")
            (root / "auto.md").write_text("An automobile is a road vehicle with wheels.", encoding="utf-8")
            index = build_index(root, vector_mode="cooccurrence")
            payload = build_interchange(index, generation=7)

        self.assertEqual(payload["format_version"], 1)
        self.assertEqual(payload["generation"], 7)
        self.assertEqual(payload["analyzer_id"], "ascii-alnum-v1")
        self.assertEqual(payload["embedding_model_id"], index["embedding"]["model_id"])
        self.assertTrue(payload["embedding_model_id"].startswith("cooccurrence-ppmi-v1-sha256-"))
        self.assertEqual(len(payload["documents"]), 2)
        self.assertTrue(payload["documents"][0]["vector"])
        self.assertEqual(payload["documents"][0]["required_labels"], [])
        self.assertGreaterEqual(payload["documents"][0]["start_line"], 1)

    def test_no_vector_index_uses_explicit_none_model(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "one.md").write_text("lexical evidence", encoding="utf-8")
            payload = build_interchange(build_index(root), generation=1)

        self.assertEqual(payload["embedding_model_id"], "none")
        self.assertEqual(payload["documents"][0]["vector"], [])

    def test_generation_is_validated(self) -> None:
        with self.assertRaisesRegex(ValueError, "generation"):
            build_interchange({"chunks": [], "embedding": None}, generation=0)

    def test_schema_accepts_both_analyzers_and_nothing_else(self) -> None:
        """S2-T1 criteria 2 and 5: `analyzer_id` is an enum of exactly the two
        values the Zig importer accepts; the Python export validates with its
        default (`ascii-alnum-v1`) and with `analyzer-v2`."""
        schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
        self.assertEqual(
            schema["properties"]["analyzer_id"],
            {"enum": ["ascii-alnum-v1", "analyzer-v2"]},
        )
        self.assertEqual(tuple(schema["properties"]["analyzer_id"]["enum"]), SUPPORTED_ANALYZER_IDS)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "café.md").write_text("Le café sert des crêpes.\n\nதமிழ் மொழி", encoding="utf-8")
            index = build_index(root, vector_mode="cooccurrence")
        default = build_interchange(index, generation=1)
        self.assertEqual(default["analyzer_id"], "ascii-alnum-v1")
        self.assertEqual(schema_errors(default, schema), [])
        unicode_payload = build_interchange(index, generation=1, analyzer_id="analyzer-v2")
        self.assertEqual(unicode_payload["analyzer_id"], "analyzer-v2")
        self.assertEqual(schema_errors(unicode_payload, schema), [])
        for rejected in ("other", "v2", "analyzer-v1", ""):
            payload = dict(default, analyzer_id=rejected)
            self.assertNotEqual(schema_errors(payload, schema), [], rejected)
            with self.assertRaisesRegex(ValueError, "analyzer_id"):
                build_interchange(index, generation=1, analyzer_id=rejected)

    def test_keep_generations_is_an_optional_publication_option(self) -> None:
        """S2-T5 ruling 2: `keep_generations` is optional, >= 1, described as an
        option rather than snapshot content, composes with `analyzer-v2`, and
        the schema still rejects unknown fields."""
        schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
        self.assertNotIn("keep_generations", schema["required"])
        self.assertIn("not snapshot content", schema["properties"]["keep_generations"]["description"])
        self.assertIn("ignores it", schema["properties"]["keep_generations"]["description"])
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "a.md").write_text("alpha beta", encoding="utf-8")
            index = build_index(root, vector_mode="cooccurrence")
        payload = build_interchange(index, generation=1, analyzer_id="analyzer-v2")
        self.assertEqual(schema_errors(payload, schema), [])
        both = dict(payload, keep_generations=2)
        self.assertEqual(both["analyzer_id"], "analyzer-v2")
        self.assertEqual(schema_errors(both, schema), [])
        for bad in (0, -1, 1.5, "2"):
            self.assertNotEqual(schema_errors(dict(payload, keep_generations=bad), schema), [], bad)
        self.assertNotEqual(schema_errors(dict(payload, keep_generation=2), schema), [])

    def test_export_zig_cli_writes_schema_valid_files(self) -> None:
        """The `export_zig.py` command itself: default stays `ascii-alnum-v1`;
        `--analyzer analyzer-v2` writes the Unicode id; both validate."""
        schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "corpus"
            root.mkdir()
            (root / "one.md").write_text("lexical evidence for the export", encoding="utf-8")
            index_path = Path(temporary) / "index.json"
            save_index(build_index(root), index_path)
            for extra, expected in (([], "ascii-alnum-v1"), (["--analyzer", "analyzer-v2"], "analyzer-v2")):
                out = Path(temporary) / f"{expected}.json"
                subprocess.run(
                    [sys.executable, str(ROOT / "export_zig.py"), str(index_path), "--out", str(out), *extra],
                    cwd=ROOT, check=True, capture_output=True, timeout=60,
                )
                payload = json.loads(out.read_text(encoding="utf-8"))
                self.assertEqual(payload["analyzer_id"], expected)
                self.assertEqual(schema_errors(payload, schema), [])


if __name__ == "__main__":
    unittest.main()
