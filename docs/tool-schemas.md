# Tool schemas: one request schema, three provider shapes

S3-T5, contract 2.0.0. Each of the nine folder-knowledge tools has two JSON
Schema 2020-12 files in `contracts/tools/`:

| Tool | Request | Result |
| --- | --- | --- |
| `search_knowledge`, `read_chunk`, `list_sources`, `index_status` | `<tool>.request.schema.json` | `<tool>.result.schema.json` |
| `find`, `outline`, `read_span`, `list_files` | `<tool>.request.schema.json` | `<tool>.result.schema.json` |
| `apply_changes` (write; host only) | `apply_changes.request.schema.json` | `apply_changes.result.schema.json` |

`roots` (the visible roots and their counts) has no tool file: it is the
host's call, and its `roots` member has the shape of `index_status`'s
(`$defs/root_info`).

## What the files are

- A **request schema** describes the `params` object of one call, not the
  JSON-RPC envelope. It is closed (`additionalProperties: false`), every field
  has a `description`, and integer bounds and enums are the ones in
  `docs/tool-protocol.md` (`find.page_size` 1 to 100, `list_files.page_size`
  1 to 1,000, `read_span.context_lines` 0 to 20, `mode` `words | phrase |
  prefix`, `status` `indexed | pending`). It leaves out `principal_labels` and
  `query_vector`: those are the host's, and a model-facing call that sends
  them is invalid. (The engine's own `contracts/tool-request.schema.json`
  describes the raw service and keeps them.)
- A **result schema** describes the `result` member of the JSON-RPC response
  (equally the CLI's `--json` output and the C ABI's string), closed the same
  way. Nullable fields are type arrays (`["string", "null"]`). `find`'s
  `exact_match` is `true | false | null`; `null` means the phrase check did
  not run.
- Schemas are provider-neutral. They use only the keywords that
  `src/search_platform/schema_check.py` checks: `type`, `enum`, `const`,
  `required`, `properties`, `additionalProperties`, `items`, `minItems`,
  `maxItems`, `uniqueItems`, `minimum`, `maximum`, `minLength`, `maxLength`,
  `pattern` and a local `$ref` into `$defs`.

## Wrapping a request schema

An adapter reads the file and puts it, unchanged, where its provider expects
a tool's input schema. The name and description come from the adapter; the
schema is never edited, merged or "simplified".

```python
import json
from pathlib import Path

def load(tool: str, kind: str) -> dict:
    return json.loads(Path(f"contracts/tools/{tool}.{kind}.schema.json").read_text())

def as_input_schema_style(tool: str, description: str) -> dict:
    # {"name", "description", "input_schema"}
    return {"name": tool, "description": description, "input_schema": load(tool, "request")}

def as_parameters_style(tool: str, description: str) -> dict:
    # {"type": "function", "function": {"name", "description", "parameters"}}
    return {"type": "function",
            "function": {"name": tool, "description": description, "parameters": load(tool, "request")}}

def as_mcp_tool(tool: str, description: str) -> dict:
    # an entry of the tools/list result: {"name", "description", "inputSchema"}
    return {"name": tool, "description": description, "inputSchema": load(tool, "request")}
```

For `find` the three descriptors are:

```json
{"name": "find", "description": "Find words, an exact phrase (in quotes) or a prefix (trailing *) in the selected folders.",
 "input_schema": { "...": "the contents of find.request.schema.json" }}

{"type": "function", "function": {"name": "find", "description": "...",
 "parameters": { "...": "the same contents" }}}

{"name": "find", "description": "...", "inputSchema": { "...": "the same contents" }}
```

`tests/test_tool_schemas.py` builds all three for every tool and asserts that
the embedded schema equals the file, key for key.

Rules for adapters:

1. **Do not change the schema.** If a provider refuses the identifier keywords
   `$schema` and `$id`, omit exactly those two from the outgoing copy: they
   annotate, they do not constrain. Nothing else is dropped, renamed or
   loosened. Keep the file as the validation source.
2. **Validate the model's arguments** against the request schema before
   forwarding them. An invalid call is returned to the model as a tool error
   naming the problem; it is never forwarded or repaired silently.
3. **Do not expose `apply_changes`** to a model (CAP-19 FR-23). Offer it, if
   at all, to the host's own indexing code, behind the server's write flag.
4. **Do not add fields.** Scope (roots, labels) is injected by the host from
   trusted configuration, not by the model.
5. Provider limits are the adapter's to handle by omission, not by editing the
   schema: a provider that cannot take `null` in a type array or in `enum`
   needs a provider-specific tool surface, which is a new decision, not a
   quiet rewrite.

## The result schema is the adapter's own target

The result schema is not a tool descriptor and is not sent to the model. The
adapter validates every result against it before returning the text to the
model (after removing the transport: the JSON-RPC envelope, or MCP's
`content` wrapper). A result that fails is a contract fault (an engine and
adapter out of step), reported as an error, not passed on. The closed
schemas make that cheap: an extra or missing field is caught the day the
engine adds it.

`src/search_platform/schema_check.py` is the standard-library validator the
tests use (`validate(instance, schema)` returns the list of errors;
`check` raises `SchemaError`). It raises `UnsupportedKeyword` for any
keyword it does not implement, so a schema can never pass silently.
The tests validate recorded real responses from the family-folder fixture:
`searchd serve` for every tool, the CLI's `--json` for `find`, `outline`,
`read-span`, `list-files` and `apply`.

The skill that goes with the tools is `skills/folder-knowledge/SKILL.md`.
