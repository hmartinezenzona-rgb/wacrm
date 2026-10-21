#!/usr/bin/env python3
"""Delegate a text-only coding task to Hermes (one-shot, no tools) and optionally apply the answer.

    delegar_hermes.py --task task.md [--context path ...] [--apply-to DIR] [--out answer.md] [--timeout 600]

The prompt goes to third-party LLM providers, so context files are screened: secret-looking paths and
secret-looking content are REFUSED before hermes runs. Hermes must answer with `FILE: <path>` lines each
followed by one fenced block holding the complete file. With --apply-to, each block is written under that
directory; absolute paths and `..` are refused. Stdout ends with a JSON summary {seconds, files, exit}.
"""
import argparse
import fnmatch
import json
import re
import subprocess
import sys
import time
from pathlib import Path

SECRET_NAME_WORDS = ("token", "key", "secret", "credential")
SECRET_DIRS = (Path.home() / ".config" / "wacrm",)
SECRET_FILES = (Path.home() / ".n8n-api-key",)
SECRET_CONTENT = (
    re.compile(r"sbp_"),
    re.compile(r"eyJhbGci"),
    re.compile(r"X-N8N-API-KEY", re.I),
    re.compile(r"postgres(?:ql)?://[^\s/:@]+:[^\s/@]+@", re.I),
)
ANSWER_FORMAT = (
    "Answer with text only; do not use any tool and do not read or write files.\n"
    "Required answer format: for each file, one line `FILE: <relative path>` followed by ONE fenced code block\n"
    "with the COMPLETE file content. Nothing else: no explanations, no extra text."
)
FILE_BLOCK = re.compile(r"^FILE:[ \t]*(\S+)[ \t]*\n```[^\n]*\n(.*?)\n```[ \t]*$", re.S | re.M)


class Refused(Exception):
    """A guard refused the request."""


def check_context_path(path: Path) -> None:
    resolved = path.resolve()
    name = resolved.name.lower()
    if name == ".env" or fnmatch.fnmatch(name, "*.env") or name.startswith(".env"):
        raise Refused(f"{path}: env file")
    if any(word in name for word in SECRET_NAME_WORDS):
        raise Refused(f"{path}: name looks like a secret")
    if resolved in {p.resolve() for p in SECRET_FILES}:
        raise Refused(f"{path}: secret file")
    for d in SECRET_DIRS:
        if d.resolve() == resolved or d.resolve() in resolved.parents:
            raise Refused(f"{path}: under {d}")


def check_context_content(path: Path, text: str) -> None:
    for pattern in SECRET_CONTENT:
        if pattern.search(text):
            raise Refused(f"{path}: content matches secret pattern {pattern.pattern!r}")


def read_context(path: Path) -> str:
    check_context_path(path)
    text = path.read_text(encoding="utf-8")
    check_context_content(path, text)
    return text


def build_prompt(task_text: str, contexts: list[tuple[str, str]]) -> str:
    parts = [ANSWER_FORMAT, "## Task\n" + task_text.strip()]
    for name, text in contexts:
        parts.append(f"## Context file: {name}\n````\n{text.rstrip()}\n````")
    return "\n\n".join(parts) + "\n"


def parse_answer(answer: str) -> list[tuple[str, str]]:
    return [(m.group(1), m.group(2).rstrip("\n") + "\n") for m in FILE_BLOCK.finditer(answer)]


def safe_target(root: Path, rel: str) -> Path:
    if rel.startswith("/") or ".." in Path(rel).parts:
        raise Refused(f"answer path escapes the target directory: {rel}")
    target = (root / rel).resolve()
    if root.resolve() not in target.parents:
        raise Refused(f"answer path escapes the target directory: {rel}")
    return target


def apply_files(root: Path, files: list[tuple[str, str]]) -> list[str]:
    targets = [(rel, safe_target(root, rel), body) for rel, body in files]  # validate all before writing
    for _, target, body in targets:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(body, encoding="utf-8")
    return [rel for rel, _, _ in targets]


def run_hermes(prompt: str, timeout: int) -> subprocess.CompletedProcess:
    cmd = ["hermes", "-z", prompt, "-t", "todo", "--in", "/tmp"]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)


def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--task", required=True, type=Path)
    p.add_argument("--context", action="append", default=[], type=Path)
    p.add_argument("--apply-to", type=Path)
    p.add_argument("--out", type=Path)
    p.add_argument("--timeout", type=int, default=600)
    return p.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    try:
        task_text = args.task.read_text(encoding="utf-8")
        check_context_content(args.task, task_text)
        contexts = [(str(p), read_context(p)) for p in args.context]
    except Refused as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        return 2
    started = time.time()
    try:
        proc = run_hermes(build_prompt(task_text, contexts), args.timeout)
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"ERROR: hermes did not run: {exc}", file=sys.stderr)
        print(json.dumps({"seconds": round(time.time() - started), "files": [], "exit": -1}))
        return 1
    seconds = round(time.time() - started)
    if args.out:
        args.out.write_text(proc.stdout, encoding="utf-8")
    written: list[str] = []
    code = proc.returncode
    if proc.returncode != 0:
        print(proc.stderr[-400:], file=sys.stderr)
    elif args.apply_to:
        try:
            written = apply_files(args.apply_to, parse_answer(proc.stdout))
        except Refused as exc:
            print(f"REFUSED: {exc}", file=sys.stderr)
            code = 2
    print(json.dumps({"seconds": seconds, "files": written, "exit": proc.returncode}))
    return 1 if proc.returncode != 0 else code


if __name__ == "__main__":
    sys.exit(main())
