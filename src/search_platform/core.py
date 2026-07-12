from __future__ import annotations

import hashlib
import json
import math
import re
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass, replace
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Iterator

from .providers import EmbeddingProvider, ProviderMismatch
from .access import ACCESS_SEMANTICS, is_authorized, required_labels_for_path


INDEX_VERSION = 1
MAX_COOCCURRENCE_TERMS = 512
CHUNKER_ID = "line-window-v1"
CHUNK_MAX_CHARS = 1_600
CHUNK_OVERLAP_LINES = 3
TOKEN_PATTERN = re.compile(r"[^\W_]+", re.UNICODE)
DEFAULT_EXTENSIONS = {
    ".c",
    ".cpp",
    ".css",
    ".go",
    ".h",
    ".html",
    ".java",
    ".js",
    ".json",
    ".md",
    ".py",
    ".rs",
    ".rst",
    ".toml",
    ".ts",
    ".txt",
    ".yaml",
    ".yml",
    ".zig",
}
IGNORED_DIRECTORIES = {
    ".git",
    ".search",
    ".zig-cache",
    "__pycache__",
    "node_modules",
    "zig-out",
}


@dataclass(frozen=True)
class Chunk:
    id: str
    path: str
    start_line: int
    end_line: int
    text: str
    terms: dict[str, int]
    length: int
    vector: list[float] | None
    required_labels: list[str]


def tokenize(text: str) -> list[str]:
    return [token.casefold() for token in TOKEN_PATTERN.findall(text)]


def _hash_vector(tokens: Iterable[str], dimensions: int = 128) -> list[float]:
    """Create an offline test vector; this does not understand semantic meaning."""
    values = [0.0] * dimensions
    for token, count in Counter(tokens).items():
        digest = hashlib.blake2b(token.encode("utf-8"), digest_size=8).digest()
        bucket = int.from_bytes(digest[:4], "little") % dimensions
        sign = 1.0 if digest[4] & 1 else -1.0
        values[bucket] += sign * (1.0 + math.log(count))
    norm = math.sqrt(sum(value * value for value in values))
    return [value / norm for value in values] if norm else values


def _normalize_vector(values: list[float]) -> list[float]:
    norm = math.sqrt(sum(value * value for value in values))
    return [value / norm for value in values] if norm else values


def _cooccurrence_model_id(model: dict) -> str:
    canonical_model = {
        "model_family": model.get("model_family", "cooccurrence-ppmi-v1"),
        "type": model["type"],
        "window": model["window"],
        "dimensions": model["dimensions"],
        "vocabulary": model["vocabulary"],
        "word_vectors": model["word_vectors"],
    }
    canonical = json.dumps(
        canonical_model,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")
    return f"cooccurrence-ppmi-v1-sha256-{hashlib.sha256(canonical).hexdigest()}"


def _fit_cooccurrence_model(tokenized_chunks: list[list[str]], *, window: int = 4) -> dict:
    """Train a small distributional-semantic PPMI model from this corpus."""
    corpus_frequency = Counter(token for tokens in tokenized_chunks for token in tokens)
    selected = sorted(corpus_frequency, key=lambda term: (-corpus_frequency[term], term))[
        :MAX_COOCCURRENCE_TERMS
    ]
    vocabulary = sorted(selected)
    vocabulary_set = set(vocabulary)
    cooccurrence: dict[str, Counter[str]] = defaultdict(Counter)
    for tokens in tokenized_chunks:
        filtered = [token for token in tokens if token in vocabulary_set]
        for position, token in enumerate(filtered):
            start = max(0, position - window)
            end = min(len(filtered), position + window + 1)
            for context_position in range(start, end):
                if context_position != position:
                    cooccurrence[token][filtered[context_position]] += 1

    row_totals = {term: sum(counts.values()) for term, counts in cooccurrence.items()}
    column_totals: Counter[str] = Counter()
    for counts in cooccurrence.values():
        column_totals.update(counts)
    total = sum(row_totals.values())
    vectors: dict[str, list[float]] = {}
    for term in vocabulary:
        values = []
        for context in vocabulary:
            count = cooccurrence[term][context]
            if not count or not total or not row_totals.get(term) or not column_totals[context]:
                values.append(0.0)
                continue
            pmi = math.log((count * total) / (row_totals[term] * column_totals[context]))
            values.append(max(0.0, pmi))
        vectors[term] = _normalize_vector(values)
    model = {
        "model_family": "cooccurrence-ppmi-v1",
        "type": "cooccurrence_ppmi",
        "window": window,
        "dimensions": len(vocabulary),
        "vocabulary": vocabulary,
        "word_vectors": vectors,
    }
    # This model is trained independently for each corpus. The family name alone
    # is not sufficient compatibility evidence: equal dimensions can still have
    # different vocabulary axes and weights. Fingerprint the canonical learned
    # artifact so query and document vectors can be matched fail-closed.
    model["model_id"] = _cooccurrence_model_id(model)
    return model


def _cooccurrence_vector(tokens: Iterable[str], model: dict) -> list[float]:
    dimensions = model["dimensions"]
    values = [0.0] * dimensions
    matched = 0
    for token in tokens:
        token_vector = model["word_vectors"].get(token)
        if token_vector is None:
            continue
        matched += 1
        for index, value in enumerate(token_vector):
            values[index] += value
    if matched:
        values = [value / matched for value in values]
    return _normalize_vector(values)


def _iter_text_files(root: Path) -> Iterator[Path]:
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix.casefold() not in DEFAULT_EXTENSIONS:
            continue
        if any(part in IGNORED_DIRECTORIES or part.startswith(".") for part in path.relative_to(root).parts):
            continue
        yield path


def _line_chunks(
    text: str,
    max_chars: int = CHUNK_MAX_CHARS,
    overlap_lines: int = CHUNK_OVERLAP_LINES,
) -> Iterator[tuple[int, int, str]]:
    lines = text.splitlines()
    if not lines and text:
        lines = [text]
    start = 0
    while start < len(lines):
        size = 0
        end = start
        while end < len(lines):
            candidate_size = len(lines[end]) + 1
            if end > start and size + candidate_size > max_chars:
                break
            size += candidate_size
            end += 1
        chunk_text = "\n".join(lines[start:end]).strip()
        if chunk_text:
            yield start + 1, end, chunk_text
        if end >= len(lines):
            break
        start = max(start + 1, end - overlap_lines)


def _chunk_id(path: str, start_line: int, end_line: int, text: str) -> str:
    identity = f"{path}\0{start_line}\0{end_line}\0{text}".encode("utf-8")
    return hashlib.sha256(identity).hexdigest()[:20]


def _provider_vectors(
    provider: EmbeddingProvider,
    texts: list[str],
    *,
    purpose: str,
    expected_dimensions: int,
) -> list[list[float]]:
    raw = provider.embed_documents(texts) if purpose == "documents" else provider.embed_queries(texts)
    if len(raw) != len(texts):
        raise ProviderMismatch(
            f"embedding provider returned {len(raw)} vectors for {len(texts)} {purpose}"
        )
    vectors = []
    for vector in raw:
        if len(vector) != expected_dimensions:
            raise ProviderMismatch(
                f"embedding provider returned {len(vector)} dimensions; expected {expected_dimensions}"
            )
        values = [float(value) for value in vector]
        if any(not math.isfinite(value) for value in values):
            raise ProviderMismatch("embedding provider returned a non-finite value")
        vectors.append(_normalize_vector(values))
    return vectors


def build_index(
    root: Path,
    *,
    vector_mode: str = "none",
    embedding_provider: EmbeddingProvider | None = None,
    access_rules: list[dict] | None = None,
    previous_index: dict | None = None,
) -> dict:
    root = root.expanduser().resolve()
    if not root.is_dir():
        raise ValueError(f"knowledge root is not a directory: {root}")
    if vector_mode not in {"none", "hash", "cooccurrence", "neural"}:
        raise ValueError("vector_mode must be 'none', 'hash', 'cooccurrence', or 'neural'")
    if (vector_mode == "neural") != (embedding_provider is not None):
        raise ValueError("neural vector mode requires exactly one embedding provider")

    chunking = {
        "id": CHUNKER_ID,
        "max_chars": CHUNK_MAX_CHARS,
        "overlap_lines": CHUNK_OVERLAP_LINES,
    }
    if previous_index is not None:
        if previous_index.get("root") != str(root):
            raise ValueError("incremental index root does not match the current root")
        if previous_index.get("vector_mode", "none") != vector_mode:
            raise ValueError("incremental index vector mode does not match")
        if previous_index.get("chunking") != chunking:
            raise ValueError("incremental index chunker contract does not match")
        if not isinstance(previous_index.get("source_files"), list):
            raise ValueError("incremental index has no source-file hash metadata")
        if vector_mode == "neural":
            assert embedding_provider is not None
            previous_embedding = previous_index.get("embedding") or {}
            provider_metadata = embedding_provider.metadata
            if (
                previous_embedding.get("model_id") != provider_metadata.get("model_id")
                or previous_embedding.get("dimensions") != provider_metadata.get("dimensions")
            ):
                raise ProviderMismatch("incremental embedding provider does not match previous index")

    chunks: list[Chunk] = []
    skipped: list[dict[str, str]] = []
    source_files: list[dict[str, str]] = []
    previous_files = {
        item["path"]: item
        for item in (previous_index or {}).get("source_files", [])
        if isinstance(item, dict) and isinstance(item.get("path"), str)
    }
    previous_chunks: dict[str, list[dict]] = defaultdict(list)
    for chunk in (previous_index or {}).get("chunks", []):
        previous_chunks[chunk["path"]].append(chunk)
    seen_paths: set[str] = set()
    reused_files = 0
    reused_chunks = 0
    relabeled_chunks = 0
    added_files = 0
    changed_files = 0
    stale_files = 0
    for path in _iter_text_files(root):
        relative_path = path.relative_to(root).as_posix()
        seen_paths.add(relative_path)
        try:
            content_bytes = path.read_bytes()
            text = content_bytes.decode("utf-8")
        except (UnicodeDecodeError, OSError) as exc:
            skipped.append({"path": relative_path, "reason": str(exc)})
            if relative_path in previous_files:
                stale_files += 1
                source_files.append(dict(previous_files[relative_path]))
                labels = required_labels_for_path(relative_path, access_rules)
                for saved in previous_chunks[relative_path]:
                    if saved.get("required_labels", []) != labels:
                        relabeled_chunks += 1
                    chunks.append(
                        Chunk(
                            id=saved["id"],
                            path=saved["path"],
                            start_line=saved["start_line"],
                            end_line=saved["end_line"],
                            text=saved["text"],
                            terms=dict(saved["terms"]),
                            length=saved["length"],
                            vector=saved.get("vector"),
                            required_labels=labels,
                        )
                    )
                    reused_chunks += 1
            continue
        content_hash = hashlib.sha256(content_bytes).hexdigest()
        source_files.append({"path": relative_path, "sha256": content_hash})
        previous_file = previous_files.get(relative_path)
        labels = required_labels_for_path(relative_path, access_rules)
        if previous_file is not None and previous_file.get("sha256") == content_hash:
            reused_files += 1
            for saved in previous_chunks[relative_path]:
                if saved.get("required_labels", []) != labels:
                    relabeled_chunks += 1
                chunks.append(
                    Chunk(
                        id=saved["id"],
                        path=saved["path"],
                        start_line=saved["start_line"],
                        end_line=saved["end_line"],
                        text=saved["text"],
                        terms=dict(saved["terms"]),
                        length=saved["length"],
                        vector=saved.get("vector"),
                        required_labels=labels,
                    )
                )
                reused_chunks += 1
            continue
        if previous_file is None:
            added_files += 1
        else:
            changed_files += 1
        for start_line, end_line, content in _line_chunks(text):
            tokens = tokenize(content)
            if not tokens:
                continue
            terms = dict(Counter(tokens))
            vector = _hash_vector(tokens) if vector_mode == "hash" else None
            chunks.append(
                Chunk(
                    id=_chunk_id(relative_path, start_line, end_line, content),
                    path=relative_path,
                    start_line=start_line,
                    end_line=end_line,
                    text=content,
                    terms=terms,
                    length=len(tokens),
                    vector=vector,
                    required_labels=labels,
                )
            )

    source_files.sort(key=lambda item: item["path"])
    deleted_paths = sorted(set(previous_files) - seen_paths)
    corpus_changed = previous_index is None or bool(added_files or changed_files or deleted_paths)

    vector_model = None
    if vector_mode == "cooccurrence":
        if previous_index is not None and not corpus_changed:
            vector_model = previous_index["vector_model"]
        else:
            tokenized_chunks = [tokenize(chunk.text) for chunk in chunks]
            vector_model = _fit_cooccurrence_model(tokenized_chunks)
            chunks = [
                replace(chunk, vector=_cooccurrence_vector(tokens, vector_model))
                for chunk, tokens in zip(chunks, tokenized_chunks)
            ]
    elif vector_mode == "neural":
        assert embedding_provider is not None
        provider_metadata = embedding_provider.metadata
        dimensions = provider_metadata.get("dimensions")
        if isinstance(dimensions, bool) or not isinstance(dimensions, int) or dimensions < 1:
            raise ProviderMismatch("embedding provider metadata has invalid dimensions")
        pending_indexes = [index for index, chunk in enumerate(chunks) if chunk.vector is None]
        if pending_indexes:
            vectors = _provider_vectors(
                embedding_provider,
                [chunks[index].text for index in pending_indexes],
                purpose="documents",
                expected_dimensions=dimensions,
            )
            for chunk_index, vector in zip(pending_indexes, vectors):
                chunks[chunk_index] = replace(chunks[chunk_index], vector=vector)
    else:
        pending_indexes = []

    embedding_metadata = None
    if vector_mode == "hash":
        embedding_metadata = {
            "model_id": "hash-projection-v1",
            "type": "mechanical_test",
            "dimensions": 128,
            "semantic": False,
        }
    elif vector_model is not None:
        embedding_metadata = {
            "model_id": vector_model["model_id"],
            "model_family": vector_model["model_family"],
            "type": "distributional",
            "dimensions": vector_model["dimensions"],
            "semantic": True,
            "window": vector_model["window"],
            "max_terms": MAX_COOCCURRENCE_TERMS,
        }
    elif vector_mode == "neural":
        assert embedding_provider is not None
        embedding_metadata = embedding_provider.metadata

    index = {
        "version": INDEX_VERSION,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "root": str(root),
        "vector_mode": vector_mode,
        "embedding": embedding_metadata,
        "access": {"semantics": ACCESS_SEMANTICS},
        "chunking": chunking,
        "source_files": source_files,
        "stats": {
            "files": len(source_files),
            "chunks": len(chunks),
            "skipped": skipped,
            "incremental": {
                "enabled": previous_index is not None,
                "corpus_changed": corpus_changed,
                "reused_files": reused_files,
                "reused_chunks": reused_chunks,
                "relabeled_chunks": relabeled_chunks,
                "added_files": added_files,
                "changed_files": changed_files,
                "deleted_files": len(deleted_paths),
                "stale_files": stale_files,
                "embedded_chunks": (
                    len(chunks)
                    if vector_mode == "cooccurrence" and corpus_changed
                    else len(pending_indexes)
                    if vector_mode == "neural"
                    else 0
                ),
            },
        },
        "chunks": [asdict(chunk) for chunk in chunks],
    }
    if vector_model is not None:
        index["vector_model"] = vector_model
    return index


def save_index(index: dict, output: Path) -> None:
    output = output.expanduser()
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    temporary.write_text(json.dumps(index, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    temporary.replace(output)


def load_index(path: Path) -> dict:
    index = json.loads(path.expanduser().read_text(encoding="utf-8"))
    if index.get("version") != INDEX_VERSION:
        raise ValueError(f"unsupported index version: {index.get('version')!r}")
    if index.get("vector_mode") == "cooccurrence":
        model = index.get("vector_model")
        embedding = index.get("embedding")
        if not isinstance(model, dict) or not isinstance(embedding, dict):
            raise ValueError("cooccurrence index is missing model metadata")
        model["model_family"] = model.get("model_family", "cooccurrence-ppmi-v1")
        model["model_id"] = _cooccurrence_model_id(model)
        embedding["model_family"] = model["model_family"]
        embedding["model_id"] = model["model_id"]
    for chunk in index.get("chunks", []):
        chunk["required_labels"] = sorted(set(chunk.get("required_labels", [])))
    index.setdefault("access", {"semantics": ACCESS_SEMANTICS})
    return index


def _bm25_scores(chunks: list[dict], query_terms: list[str]) -> dict[str, float]:
    if not chunks or not query_terms:
        return {}
    document_frequency: Counter[str] = Counter()
    for chunk in chunks:
        document_frequency.update(chunk["terms"].keys())
    average_length = sum(chunk["length"] for chunk in chunks) / len(chunks)
    scores: dict[str, float] = defaultdict(float)
    k1, b = 1.2, 0.75
    for chunk in chunks:
        for term in set(query_terms):
            frequency = chunk["terms"].get(term, 0)
            if not frequency:
                continue
            df = document_frequency[term]
            idf = math.log(1.0 + (len(chunks) - df + 0.5) / (df + 0.5))
            denominator = frequency + k1 * (1.0 - b + b * chunk["length"] / average_length)
            scores[chunk["id"]] += idf * (frequency * (k1 + 1.0) / denominator)
    return dict(scores)


def embed_query(
    index: dict,
    query: str,
    embedding_provider: EmbeddingProvider | None = None,
) -> list[float]:
    query_terms = tokenize(query)
    if not query_terms:
        return []
    vector_mode = index.get("vector_mode", "none")
    if vector_mode == "hash":
        return _hash_vector(query_terms)
    elif vector_mode == "cooccurrence":
        return _cooccurrence_vector(query_terms, index["vector_model"])
    elif vector_mode == "neural":
        if embedding_provider is None:
            raise ProviderMismatch("neural query requires the index's embedding provider")
        embedding = index.get("embedding") or {}
        provider_metadata = embedding_provider.metadata
        if (
            provider_metadata.get("model_id") != embedding.get("model_id")
            or provider_metadata.get("dimensions") != embedding.get("dimensions")
        ):
            raise ProviderMismatch("query embedding provider does not match the index")
        return _provider_vectors(
            embedding_provider,
            [query],
            purpose="queries",
            expected_dimensions=embedding["dimensions"],
        )[0]
    return []


def _cosine_scores(
    index: dict,
    chunks: list[dict],
    query: str,
    embedding_provider: EmbeddingProvider | None,
) -> dict[str, float]:
    if not tokenize(query):
        return {}
    query_vector = embed_query(index, query, embedding_provider)
    if not any(query_vector):
        return {}
    return {
        chunk["id"]: sum(left * right for left, right in zip(query_vector, chunk["vector"]))
        for chunk in chunks
        if chunk.get("vector") is not None
    }


def _ranks(scores: dict[str, float], *, positive_only: bool = False) -> dict[str, int]:
    ordered = sorted(
        ((identifier, score) for identifier, score in scores.items() if not positive_only or score > 0.0),
        key=lambda item: (-item[1], item[0]),
    )
    return {identifier: rank for rank, (identifier, _) in enumerate(ordered, start=1)}


def search(
    index: dict,
    query: str,
    *,
    top_k: int = 5,
    candidate_k: int = 100,
    path_prefix: str | None = None,
    retrieval_mode: str = "hybrid",
    embedding_provider: EmbeddingProvider | None = None,
    principal_labels: Iterable[str] = (),
) -> list[dict]:
    if top_k < 1:
        raise ValueError("top_k must be at least 1")
    if candidate_k < top_k:
        raise ValueError("candidate_k must be at least top_k")
    if not isinstance(retrieval_mode, str) or retrieval_mode not in {"lexical", "vector", "hybrid"}:
        raise ValueError("retrieval_mode must be 'lexical', 'vector', or 'hybrid'")
    query_terms = tokenize(query)
    if not query_terms:
        return []
    principal_labels = tuple(principal_labels)
    chunks = [
        chunk
        for chunk in index["chunks"]
        if (path_prefix is None or chunk["path"].startswith(path_prefix))
        and is_authorized(chunk.get("required_labels", []), principal_labels)
    ]
    lexical_scores = _bm25_scores(chunks, query_terms) if retrieval_mode != "vector" else {}
    vector_scores = (
        _cosine_scores(index, chunks, query, embedding_provider)
        if retrieval_mode != "lexical"
        else {}
    )
    lexical_ranks = _ranks(lexical_scores, positive_only=True)
    vector_ranks = _ranks(vector_scores, positive_only=True)
    lexical_ranks = {identifier: rank for identifier, rank in lexical_ranks.items() if rank <= candidate_k}
    vector_ranks = {identifier: rank for identifier, rank in vector_ranks.items() if rank <= candidate_k}

    # Reciprocal-rank fusion is stable even when component score scales differ.
    fused: dict[str, float] = defaultdict(float)
    for identifier, rank in lexical_ranks.items():
        fused[identifier] += 1.0 / (60.0 + rank)
    for identifier, rank in vector_ranks.items():
        fused[identifier] += 1.0 / (60.0 + rank)

    by_id = {chunk["id"]: chunk for chunk in chunks}
    results = []
    for identifier, fused_score in sorted(fused.items(), key=lambda item: (-item[1], item[0]))[:top_k]:
        chunk = by_id[identifier]
        results.append(
            {
                "chunk_id": identifier,
                "citation": {
                    "path": chunk["path"],
                    "start_line": chunk["start_line"],
                    "end_line": chunk["end_line"],
                },
                "content": chunk["text"],
                "score": fused_score,
                "ranking": {
                    "lexical": {
                        "rank": lexical_ranks.get(identifier),
                        "score": lexical_scores.get(identifier),
                    },
                    "vector": {
                        "rank": vector_ranks.get(identifier),
                        "score": vector_scores.get(identifier),
                        "mode": index.get("vector_mode", "none"),
                    },
                },
            }
        )
    return results


def context_envelope(
    index: dict,
    query: str,
    *,
    top_k: int = 5,
    candidate_k: int = 100,
    path_prefix: str | None = None,
    retrieval_mode: str = "hybrid",
    embedding_provider: EmbeddingProvider | None = None,
    principal_labels: Iterable[str] = (),
) -> dict:
    principal_labels = tuple(principal_labels)
    results = search(
        index,
        query,
        top_k=top_k,
        candidate_k=candidate_k,
        path_prefix=path_prefix,
        retrieval_mode=retrieval_mode,
        embedding_provider=embedding_provider,
        principal_labels=principal_labels,
    )
    return {
        "tool": "search_knowledge",
        "query": query,
        "index": {"root": index["root"], "version": index["version"]},
        "retrieval": {
            "mode": retrieval_mode,
            "candidate_k": candidate_k,
            "vector_mode": index.get("vector_mode", "none"),
            "embedding": index.get("embedding"),
            "authorization": {
                "semantics": index.get("access", {}).get("semantics", ACCESS_SEMANTICS),
                "principal_label_count": len(set(principal_labels)),
            },
        },
        "results": results,
        "answer_policy": {
            "ground_in_results": True,
            "cite_path_and_lines": True,
            "say_when_evidence_is_insufficient": True,
        },
    }
