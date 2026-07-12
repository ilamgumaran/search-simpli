from __future__ import annotations

import hashlib
import math
import struct
from pathlib import Path
from typing import Iterable, Protocol


FASTEMBED_RUNTIME = "0.8.0"
DEFAULT_FASTEMBED_MODEL = "BAAI/bge-small-en-v1.5"
CONFORMANCE_VERSION = "embedding-probes-v1"
QUERY_PROBES = (
    "query: find a road vehicle",
    "query: locate a medical professional",
)
PASSAGE_PROBES = (
    "passage: an automobile has wheels and travels on roads",
    "passage: a physician diagnoses illness and treats patients",
)


class ProviderError(RuntimeError):
    """Base error for optional embedding-provider boundaries."""


class ProviderUnavailable(ProviderError):
    """An optional embedding runtime or model cannot be loaded."""


class ProviderMismatch(ProviderError):
    """An embedding provider is not compatible with an index."""


class EmbeddingProvider(Protocol):
    @property
    def metadata(self) -> dict: ...

    def embed_documents(self, texts: list[str]) -> list[list[float]]: ...

    def embed_queries(self, texts: list[str]) -> list[list[float]]: ...


def _as_lists(vectors: Iterable[Iterable[float]]) -> list[list[float]]:
    return [[float(value) for value in vector] for vector in vectors]


def _probe_fingerprint(
    runtime_version: str,
    model_name: str,
    query_vectors: list[list[float]],
    passage_vectors: list[list[float]],
) -> str:
    digest = hashlib.sha256()
    for text in (CONFORMANCE_VERSION, runtime_version, model_name, *QUERY_PROBES, *PASSAGE_PROBES):
        encoded = text.encode("utf-8")
        digest.update(struct.pack("<I", len(encoded)))
        digest.update(encoded)
    for vectors in (query_vectors, passage_vectors):
        digest.update(struct.pack("<I", len(vectors)))
        for vector in vectors:
            digest.update(struct.pack("<I", len(vector)))
            for value in vector:
                if not math.isfinite(value):
                    raise ProviderUnavailable("embedding conformance probe returned a non-finite value")
                digest.update(struct.pack("<f", value))
    return digest.hexdigest()


class FastEmbedProvider:
    """Pinned local ONNX provider; imported only when neural mode is requested."""

    def __init__(
        self,
        *,
        model_name: str = DEFAULT_FASTEMBED_MODEL,
        cache_dir: Path | None = None,
        runtime_version: str = FASTEMBED_RUNTIME,
    ) -> None:
        try:
            import fastembed
            from fastembed import TextEmbedding
        except ImportError as exc:  # pragma: no cover - depends on optional environment
            raise ProviderUnavailable(
                f"fastembed=={runtime_version} is required for neural mode"
            ) from exc
        installed = getattr(fastembed, "__version__", None)
        if installed != runtime_version:
            raise ProviderUnavailable(
                f"fastembed runtime mismatch: expected {runtime_version}, got {installed!r}"
            )
        try:
            self._model = TextEmbedding(
                model_name=model_name,
                cache_dir=str(cache_dir.expanduser().resolve()) if cache_dir is not None else None,
            )
            query_vectors = _as_lists(self._model.query_embed(QUERY_PROBES))
            passage_vectors = _as_lists(self._model.passage_embed(PASSAGE_PROBES))
        except Exception as exc:  # optional runtime exposes several download/runtime errors
            raise ProviderUnavailable(f"could not initialize embedding model {model_name!r}") from exc
        if not query_vectors or not passage_vectors or len(query_vectors[0]) == 0:
            raise ProviderUnavailable("embedding conformance probe returned no dimensions")
        dimensions = len(query_vectors[0])
        if any(len(vector) != dimensions for vector in query_vectors + passage_vectors):
            raise ProviderUnavailable("embedding conformance probe returned inconsistent dimensions")
        fingerprint = _probe_fingerprint(
            runtime_version, model_name, query_vectors, passage_vectors
        )
        self._metadata = {
            "model_id": f"fastembed-{runtime_version}-{model_name}-sha256-{fingerprint}",
            "model_family": model_name,
            "type": "neural",
            "dimensions": dimensions,
            "normalization": "l2",
            "semantic": True,
            "provider": {
                "type": "fastembed",
                "runtime_version": runtime_version,
                "model_name": model_name,
                "conformance_version": CONFORMANCE_VERSION,
            },
        }

    @property
    def metadata(self) -> dict:
        return dict(self._metadata)

    def embed_documents(self, texts: list[str]) -> list[list[float]]:
        return _as_lists(self._model.passage_embed(texts))

    def embed_queries(self, texts: list[str]) -> list[list[float]]:
        return _as_lists(self._model.query_embed(texts))


def provider_from_index(index: dict, *, cache_dir: Path | None = None) -> EmbeddingProvider | None:
    if index.get("vector_mode") != "neural":
        return None
    embedding = index.get("embedding")
    config = embedding.get("provider") if isinstance(embedding, dict) else None
    if not isinstance(config, dict) or config.get("type") != "fastembed":
        raise ProviderUnavailable("neural index has no supported provider configuration")
    provider = FastEmbedProvider(
        model_name=config.get("model_name", ""),
        runtime_version=config.get("runtime_version", ""),
        cache_dir=cache_dir,
    )
    expected_id = embedding.get("model_id")
    expected_dimensions = embedding.get("dimensions")
    actual = provider.metadata
    if actual["model_id"] != expected_id or actual["dimensions"] != expected_dimensions:
        raise ProviderMismatch(
            "loaded provider does not match index: "
            f"expected {expected_id!r}/{expected_dimensions!r}, "
            f"got {actual['model_id']!r}/{actual['dimensions']!r}"
        )
    return provider
