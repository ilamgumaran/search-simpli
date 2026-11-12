#!/usr/bin/env python3
"""What an answering agent did, as its own runtime recorded it (S5-T10 ruling 3).

    agent_log.py --log AGENT.jsonl --brief BRIEF.txt --agent-dir DIR --out FILE

Reads the agent runtime's session log of one answering agent (kept outside the
repository) and writes a summary that holds no fixture text: the model ids the
runtime reports for the agent's turns, whether the agent's first prompt is the
brief file byte for byte, every tool the agent used, each shell command with
the machine's folder prefixes replaced by placeholders, whether every command
is one call of the client (`cd DIR && python3 mcp_call.py Qn tools|call ...`),
and the kinds of context the runtime attached (names only, not contents).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


def shell_parts(command: str) -> list:
    """Split on ;, && and newlines outside single quotes (the agents' quoting)."""
    parts, current, quoted, i = [], "", False, 0
    while i < len(command):
        ch = command[i]
        if ch == "'":
            quoted = not quoted
        if not quoted and (ch in ";\n" or command.startswith("&&", i)):
            parts.append(current)
            current = ""
            i += 2 if ch == "&" else 1
            continue
        current += ch
        i += 1
    parts.append(current)
    return [p.strip() for p in parts if p.strip()]


def classify(part: str, cd_part: str, client, trim) -> str:
    if part == cd_part:
        return "cd"
    pipe = None
    quoted = False
    for i, ch in enumerate(part):
        if ch == "'":
            quoted = not quoted
        if ch == "|" and not quoted:
            pipe = i
            break
    head, tail = (part, None) if pipe is None else (part[:pipe].strip(), part[pipe + 1:].strip())
    if client.match(head):
        if tail is None:
            return "client call"
        return "client call | output trimmed" if trim.match(tail) else "client call | " + tail
    if re.fullmatch(r"echo( ['\"][^'\"]*['\"])?", part):
        return "echo"
    return "other: " + part


def main(argv: list = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--brief", type=Path, required=True)
    parser.add_argument("--agent-dir", type=Path, required=True)
    parser.add_argument("--scratch", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    brief = args.brief.read_text(encoding="utf-8")
    pairs = [(str(args.scratch), "<scratch>"), (str(Path.home()), "<home>")]

    def scrub(text: str) -> str:
        for prefix, placeholder in pairs:
            text = text.replace(prefix, placeholder)
        return text

    cd_part = "cd " + str(args.agent_dir)
    client = re.compile(r"^python3 mcp_call\.py Q[1-9] (tools|call [a-z_]+( '[^']*')?)$")
    trim = re.compile(r"^head -[cn] ?\d+$")
    models, tools, commands, attachments, first_prompt = set(), [], [], [], None
    for line in args.log.read_text(encoding="utf-8").splitlines():
        entry = json.loads(line)
        kind, message = entry.get("type"), entry.get("message") or {}
        if kind == "user" and first_prompt is None and isinstance(message.get("content"), str):
            first_prompt = message["content"]
        if kind == "attachment":
            att = entry.get("attachment") or {}
            attachments.append(att.get("type") or "unknown")
        if kind == "assistant":
            if message.get("model"):
                models.add(message["model"])
            for block in message.get("content") or []:
                if block.get("type") == "tool_use":
                    tools.append(block.get("name"))
                    if block.get("name") == "Bash":
                        commands.append(block.get("input", {}).get("command", ""))
    split = []
    for command in commands:
        kinds = [classify(part, cd_part, client, trim) for part in shell_parts(command)]
        split.append({"command": scrub(command), "parts": [scrub(k) for k in kinds]})
    # A client call whose output is piped to a filter other than head is still
    # one call of the client (one transcript entry); it is counted and named.
    piped = [k for c in split for k in c["parts"]
             if k.startswith("client call | ") and k != "client call | output trimmed"]
    others = sorted({k for c in split for k in c["parts"]
                     if k not in ("cd", "client call", "client call | output trimmed")})
    summary = {
        "log_sha256": hashlib.sha256(args.log.read_bytes()).hexdigest(),
        "models_reported_by_runtime": sorted(models),
        "first_prompt_equals_brief": first_prompt == brief or (first_prompt or "").rstrip("\n") == brief.rstrip("\n"),
        "tools_used": {name: tools.count(name) for name in sorted(set(tools))},
        "only_bash_used": set(tools) <= {"Bash"},
        "bash_commands": split,
        "client_calls": sum(1 for c in split for k in c["parts"] if k.startswith("client call")),
        "client_calls_with_output_trimmed": sum(c["parts"].count("client call | output trimmed") for c in split),
        "client_calls_piped_to_other_filter": piped,
        "shell_parts_other_than_cd_and_client_calls": others,
        "every_command_is_cd_and_client_calls_only": not others,
        "runtime_attachment_kinds": {k: attachments.count(k) for k in sorted(set(attachments))},
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(summary, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({k: summary[k] for k in ("models_reported_by_runtime", "first_prompt_equals_brief", "tools_used",
                                              "client_calls", "client_calls_with_output_trimmed",
                                              "client_calls_piped_to_other_filter",
                                              "shell_parts_other_than_cd_and_client_calls", "runtime_attachment_kinds")}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
