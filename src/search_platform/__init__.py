"""Small, dependency-free behavioral reference for the search platform."""

from .core import build_index, load_index, search

__all__ = ["build_index", "load_index", "search"]
