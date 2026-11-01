"""A small JSON Schema (2020-12 subset) validator, standard library only.

It checks the keywords the repository's own schemas use and nothing else:
type (a name or a list, so nullable is `["string", "null"]`), enum, const,
required, properties, additionalProperties (false or a schema), items,
minItems, maxItems, uniqueItems, minimum, maximum, minLength, maxLength,
pattern, and a local `$ref` of the form `#/$defs/<name>` (or any JSON pointer
into the same document). Annotation keywords (`description`, `default`,
`title`, `$id`, `$schema`, `$defs`) are ignored. A keyword outside both lists
raises `UnsupportedKeyword`, so a schema can never silently pass because the
validator did not understand it: `check_schema` walks every subschema at load
(`load_tool_schema`) and before every `validate`, so an unknown keyword under a
property the instance does not carry is refused too (S3-T5 Verdict finding 2).

`validate(instance, schema)` returns a list of error strings (empty = valid);
`check(instance, schema)` raises `SchemaError` with all of them.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

ANNOTATIONS = {"description", "default", "title", "$id", "$schema", "$defs", "$comment", "examples", "version"}
HANDLED = {"type", "enum", "const", "required", "properties", "additionalProperties", "items", "minItems",
           "maxItems", "uniqueItems", "minimum", "maximum", "minLength", "maxLength", "pattern", "$ref"}

TOOLS_DIR = Path(__file__).resolve().parents[2] / "contracts" / "tools"


class SchemaError(ValueError):
    pass


class UnsupportedKeyword(SchemaError):
    pass


def load_tool_schema(name: str, kind: str) -> dict:
    """`contracts/tools/<name>.<kind>.schema.json`; kind is request or result."""
    schema = json.loads((TOOLS_DIR / f"{name}.{kind}.schema.json").read_text(encoding="utf-8"))
    check_schema(schema)
    return schema


def check_schema(schema: Any, path: str = "$") -> None:
    """Raise `UnsupportedKeyword` for any keyword, anywhere in `schema`, that
    is neither handled nor an annotation (the whole tree, not only the path an
    instance reaches)."""
    if isinstance(schema, bool):
        return
    if not isinstance(schema, dict):
        raise SchemaError(f"{path}: a schema must be an object or a boolean")
    for key in schema:
        if key not in HANDLED and key not in ANNOTATIONS:
            raise UnsupportedKeyword(f"{path}: unsupported keyword {key!r}")
    if "type" in schema:
        for name in schema["type"] if isinstance(schema["type"], list) else [schema["type"]]:
            if name not in {"null", "boolean", "integer", "number", "string", "array", "object"}:
                raise UnsupportedKeyword(f"{path}: unknown type {name!r}")
    if "$ref" in schema and not str(schema["$ref"]).startswith("#"):
        raise UnsupportedKeyword(f"{path}: only local $ref is supported: {schema['$ref']!r}")
    for name, member in schema.get("properties", {}).items():
        check_schema(member, f"{path}.properties.{name}")
    for name, member in schema.get("$defs", {}).items():
        check_schema(member, f"{path}.$defs.{name}")
    if isinstance(schema.get("additionalProperties"), dict):
        check_schema(schema["additionalProperties"], f"{path}.additionalProperties")
    if "items" in schema:
        check_schema(schema["items"], f"{path}.items")


def _is_type(value: Any, name: str) -> bool:
    if name == "null":
        return value is None
    if name == "boolean":
        return isinstance(value, bool)
    if name == "integer":
        return (isinstance(value, int) and not isinstance(value, bool)) or (isinstance(value, float) and value.is_integer())
    if name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if name == "string":
        return isinstance(value, str)
    if name == "array":
        return isinstance(value, list)
    if name == "object":
        return isinstance(value, dict)
    raise UnsupportedKeyword(f"unknown type {name!r}")


def _resolve(ref: str, root: dict) -> dict:
    if not ref.startswith("#"):
        raise UnsupportedKeyword(f"only local $ref is supported: {ref!r}")
    node: Any = root
    for part in [p for p in ref[1:].split("/") if p]:
        node = node[part.replace("~1", "/").replace("~0", "~")]
    return node


def _walk(value: Any, schema: Any, root: dict, path: str, errors: list[str]) -> None:
    if schema is True:
        return
    if schema is False:
        errors.append(f"{path}: no value is allowed here")
        return
    for key in schema:
        if key not in HANDLED and key not in ANNOTATIONS:
            raise UnsupportedKeyword(f"{path or '$'}: unsupported keyword {key!r}")
    if "$ref" in schema:
        _walk(value, _resolve(schema["$ref"], root), root, path, errors)
    if "type" in schema:
        names = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_is_type(value, n) for n in names):
            errors.append(f"{path or '$'}: expected {'|'.join(names)}, got {type(value).__name__}")
            return
    if "const" in schema and not _same(value, schema["const"]):
        errors.append(f"{path or '$'}: expected the constant {schema['const']!r}")
    if "enum" in schema and not any(_same(value, option) for option in schema["enum"]):
        errors.append(f"{path or '$'}: {value!r} is not one of {schema['enum']!r}")
    if isinstance(value, bool):
        return
    if isinstance(value, (int, float)):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{path or '$'}: {value} is below the minimum {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(f"{path or '$'}: {value} is above the maximum {schema['maximum']}")
    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            errors.append(f"{path or '$'}: shorter than {schema['minLength']}")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            errors.append(f"{path or '$'}: longer than {schema['maxLength']}")
        if "pattern" in schema and re.search(schema["pattern"], value) is None:
            errors.append(f"{path or '$'}: does not match {schema['pattern']!r}")
    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            errors.append(f"{path or '$'}: fewer than {schema['minItems']} items")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            errors.append(f"{path or '$'}: more than {schema['maxItems']} items")
        if schema.get("uniqueItems"):
            seen = [json.dumps(v, sort_keys=True) for v in value]
            if len(set(seen)) != len(seen):
                errors.append(f"{path or '$'}: items are not unique")
        if "items" in schema:
            for index, item in enumerate(value):
                _walk(item, schema["items"], root, f"{path}[{index}]", errors)
    if isinstance(value, dict):
        for name in schema.get("required", []):
            if name not in value:
                errors.append(f"{path or '$'}: missing required field {name!r}")
        properties = schema.get("properties", {})
        extra = schema.get("additionalProperties", True)
        for name, member in value.items():
            if name in properties:
                _walk(member, properties[name], root, f"{path}.{name}", errors)
            elif extra is False:
                errors.append(f"{path or '$'}: unexpected field {name!r}")
            elif extra is not True:
                _walk(member, extra, root, f"{path}.{name}", errors)


def _same(a: Any, b: Any) -> bool:
    """JSON equality that does not equate True with 1."""
    if isinstance(a, bool) != isinstance(b, bool):
        return False
    return a == b


def validate(instance: Any, schema: dict) -> list[str]:
    check_schema(schema)
    errors: list[str] = []
    _walk(instance, schema, schema, "", errors)
    return errors


def check(instance: Any, schema: dict) -> None:
    errors = validate(instance, schema)
    if errors:
        raise SchemaError("; ".join(errors[:10]))
