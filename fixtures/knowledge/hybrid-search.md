# Hybrid search

Lexical search is precise when a query contains names, identifiers, quoted phrases, or rare terms. A BM25-style inverted index is a strong default.

Semantic search compares embedding vectors. It can retrieve passages that express a related meaning with different words, but it needs a real embedding model and careful evaluation.

The first hybrid implementation should retrieve candidates independently and combine their ranks with reciprocal-rank fusion. Fusion avoids pretending that BM25 and cosine scores share the same scale. Later, a reranker can inspect the strongest candidates.
