# S5-T10 evidence: a real agent answers through `searchd mcp`

The record of [S5-T10](../../tasks/S5-T10.md) (review R11, CAP-13 *Validated* evidence).
Invented content only (the J2 fixture).

| File | What it is |
| --- | --- |
| `tasks.json` | The frozen task set: 30 questions in six categories with their expected outcomes, the five batches and their order, and the refresh. Committed before any agent ran. |
| `harness/snapshot.py` | Builds the S0 snapshot (J2's three roots, file-name channel on), the refreshed S1 index for a run (a copy of S0's index plus the refresh through `searchd apply`), each answering agent's client folder and its brief. |
| `harness/mcp_call_template.py` | The answering agent's only tool: a command-line MCP client that starts `searchd mcp <index> --roots school,home` (read-only default mode) per call and appends every request and result to a hash-chained transcript it writes itself. |
| `harness/brief_template.txt` | The answering agent's whole prompt: the client, the skill text verbatim, the questions, the answer format. |
| `harness/judge.py` | The machine-decidable checks (ruling 4), the CAP-13 section 9 replay through `searchd serve`, and the counts. |

Reproduce (from the repository root, `searchd` built `ReleaseSmall` from this commit):

```sh
python3 docs/evidence/s5-t10/harness/snapshot.py s0 --searchd BIN --work WORK
python3 docs/evidence/s5-t10/harness/judge.py verify-tasks --corpus WORK/corpus-s0
python3 docs/evidence/s5-t10/harness/snapshot.py agent-dir --searchd BIN --work WORK --run 1 --batch b1
python3 docs/evidence/s5-t10/harness/snapshot.py brief --work WORK --run 1 --batch b1
# ... an agent session answers from the brief; then, before the refresh batch:
python3 docs/evidence/s5-t10/harness/snapshot.py s1 --searchd BIN --work WORK --run 1
```
