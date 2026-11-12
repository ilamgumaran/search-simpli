# S5-T10 evidence: a real agent answers through `searchd mcp`

The record of [S5-T10](../../tasks/S5-T10.md) (review R11, CAP-13 *Validated* evidence).
Invented content only (the J2 fixture).

| File | What it is |
| --- | --- |
| `tasks.json` | The frozen task set: 30 questions in six categories with their expected outcomes, the five batches and their order, and the refresh. Committed before any agent ran. |
| `harness/snapshot.py` | Builds the S0 snapshot (J2's three roots, file-name channel on), the refreshed S1 index for a run (a copy of S0's index plus the refresh through `searchd apply`), each answering agent's client folder and its brief. |
| `harness/mcp_call_template.py` | The answering agent's only tool: a command-line MCP client that starts `searchd mcp <index> --roots school,home` (read-only default mode) per call and appends every request and result to a hash-chained transcript it writes itself. |
| `harness/brief_template.txt` | The answering agent's whole prompt: the client, the skill text verbatim, the questions, the answer format. |
| `harness/judge.py` | The machine-decidable checks (ruling 4), the CAP-13 section 9 replay through `searchd serve`, the counts, and the scrub of absolute paths. |
| `harness/agent_log.py` | A summary of one answering agent's own runtime log: the models, the tools it used, each shell command classified (`cd`, a client call, a client call with its output filtered, anything else), whether its first prompt is the brief, and the kinds of context the runtime attached (names only). The raw logs are not kept. |
| `identifiers/s0.json`, `identifiers/s1-runN.json` | Ruling 1: source commit, binary hash and size, the tasks file's hash, the unscoped and the agent's `index_status`, the policies, the server's `initialize` and tools list (with its hash), and the apply report. |
| `runN/transcripts/runN-bK.jsonl` | The client's hash-chained record of every request and result of batch K (scrubbed; the chain is hashed over the scrubbed form and verifies on these copies). |
| `runN/answers/runN-bK.txt` | The answering agent's final message, as returned. |
| `runN/briefs/runN-bK.txt` | The prompt the agent was given, byte for byte (scrubbed). |
| `runN/agentlogs/runN-bK.json` | `agent_log.py`'s summary of that agent's runtime log. |
| `runN/checks.json`, `runN/parity.json` | `judge.py check` and `judge.py parity` on the run (machine). |
| `runN/reading.json` | The builder's reading: the verdict and any rule breach per task, under the rules written in the file (read). |

In the scrubbed files `<scratch>` stands for the task's scratch folder and `<home>` for the home folder.

Reproduce (from the repository root, `searchd` built `ReleaseSmall` from this commit):

```sh
python3 docs/evidence/s5-t10/harness/snapshot.py s0 --searchd BIN --work WORK
python3 docs/evidence/s5-t10/harness/judge.py verify-tasks --corpus WORK/corpus-s0
python3 docs/evidence/s5-t10/harness/snapshot.py agent-dir --searchd BIN --work WORK --run 1 --batch b1
python3 docs/evidence/s5-t10/harness/snapshot.py brief --work WORK --run 1 --batch b1
# ... an agent session answers from the brief; then, before the refresh batch:
python3 docs/evidence/s5-t10/harness/snapshot.py s1 --searchd BIN --work WORK --run 1
# ... b5 on S1; with each batch's transcript and answer copied to RUN/transcripts and RUN/answers:
python3 docs/evidence/s5-t10/harness/judge.py check --run-dir RUN --corpus WORK/corpus-s0 --out RUN/checks.json
python3 docs/evidence/s5-t10/harness/judge.py parity --run-dir RUN --searchd BIN --out RUN/parity.json \
  --generations '{"b1":2,"b2":2,"b3":2,"b4":2,"b5":3}'
python3 docs/evidence/s5-t10/harness/judge.py counts --checks RUN1/checks.json --reading RUN1/reading.json \
  --checks RUN2/checks.json --reading RUN2/reading.json
```

The checks recompute from the committed copies:
`judge.py check --run-dir docs/evidence/s5-t10/run2 --corpus WORK/corpus-s0` gives the committed `run2/checks.json`.
The corpus is the S0 copy of `fixtures/j2/`, which `snapshot.py s0` writes. The refreshed text of b5 is derived from it
in memory.
