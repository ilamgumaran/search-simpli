from __future__ import annotations

import json
from pathlib import Path
from typing import Iterable


ACCESS_RULES_VERSION = 1
ACCESS_SEMANTICS = "all-required-labels-v1"


def normalize_labels(labels: Iterable[str]) -> list[str]:
    normalized: set[str] = set()
    for label in labels:
        if not isinstance(label, str) or not label or label.strip() != label:
            raise ValueError("access labels must be non-empty strings without surrounding whitespace")
        if any(character in label for character in ("\0", "\n", "\r")):
            raise ValueError("access labels cannot contain NUL or line breaks")
        normalized.add(label)
    return sorted(normalized)


def validate_access_rules(payload: object) -> list[dict]:
    if not isinstance(payload, dict) or payload.get("version") != ACCESS_RULES_VERSION:
        raise ValueError(f"access rules version must be {ACCESS_RULES_VERSION}")
    rules = payload.get("rules")
    if not isinstance(rules, list):
        raise ValueError("access rules must contain a rules array")
    validated = []
    for position, rule in enumerate(rules):
        if not isinstance(rule, dict) or set(rule) != {"path_prefix", "required_labels"}:
            raise ValueError(
                f"rules[{position}] must contain only path_prefix and required_labels"
            )
        prefix = rule["path_prefix"]
        if not isinstance(prefix, str) or prefix.startswith("/") or ".." in Path(prefix).parts:
            raise ValueError(f"rules[{position}].path_prefix must be a safe relative prefix")
        labels = rule["required_labels"]
        if not isinstance(labels, list):
            raise ValueError(f"rules[{position}].required_labels must be an array")
        validated.append({"path_prefix": prefix, "required_labels": normalize_labels(labels)})
    return validated


def load_access_rules(path: Path) -> list[dict]:
    return validate_access_rules(json.loads(path.expanduser().read_text(encoding="utf-8")))


def required_labels_for_path(path: str, rules: list[dict] | None) -> list[str]:
    if not rules:
        return []
    labels = {
        label
        for rule in rules
        if path.startswith(rule["path_prefix"])
        for label in rule["required_labels"]
    }
    return sorted(labels)


def is_authorized(required_labels: Iterable[str], principal_labels: Iterable[str]) -> bool:
    return set(required_labels).issubset(principal_labels)
