# LLM retrieval contract

The model receives evidence, not unrestricted filesystem access. Each result contains a stable chunk id, a relative path, a line range, the passage text, and ranking metadata.

The answer layer must cite its evidence and state when retrieval is insufficient. Tool calls should support a path prefix so an agent can narrow the search to a repository, skill, or permission boundary.
