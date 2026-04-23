#!/usr/bin/env python3
"""Python AST analyzer — POC for the tree-sitter-class upgrade.

Replaces regex-based entropy on Python files with a real AST walk via the
stdlib `ast` module. No external dependency (batteries-included POC); a full
multi-language tree-sitter analyzer would live next to this file and follow
the same stdin/stdout contract.

Contract:
  argv:  $1 = absolute target path,  $2 = diff mode (unused here — the diff
                                            on stdin enumerates the files)
  stdin: unified diff from the engine
  stdout: one JSON object {name, version, findings}

Findings emitted:
  * cyclomatic_complexity_high — functions with McCabe complexity >= 10
  * eval_exec_usage            — calls to eval() or exec() (taint sink)
  * shell_equals_true          — subprocess.* (..., shell=True) (command-injection smell)
  * pickle_load_usage          — pickle.load{,s} on untrusted input (deser. sink)
  * syntax_error               — file fails to parse
"""
from __future__ import annotations

import ast
import json
import os
import re
import sys

ANALYZER_NAME = "python-ast"
ANALYZER_VERSION = "0.1.0"
CYCLOMATIC_THRESHOLD = 10


def read_diff_files(diff: str) -> list[str]:
    """Extract post-image file paths (+++ b/…) touched by the diff, filtering to .py."""
    out = []
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            p = line[len("+++ b/"):]
            if p.endswith(".py"):
                out.append(p)
    return sorted(set(out))


def mccabe(node: ast.AST) -> int:
    """Cheap cyclomatic complexity: 1 + count of branching constructs in subtree."""
    score = 1
    for child in ast.walk(node):
        if isinstance(child, (ast.If, ast.For, ast.AsyncFor, ast.While,
                              ast.With, ast.AsyncWith, ast.Try,
                              ast.ExceptHandler, ast.BoolOp,
                              ast.comprehension)):
            score += 1
        elif isinstance(child, ast.IfExp):
            score += 1
    return score


def walk_file(path: str, rel: str, findings: list[dict]) -> None:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            src = fh.read()
    except OSError:
        return
    try:
        tree = ast.parse(src, filename=rel)
    except SyntaxError as e:
        findings.append({
            "severity": "high",
            "kind": "bug",
            "rule_id": "python-ast/syntax-error",
            "file": rel,
            "line": e.lineno or 0,
            "message": f"Python syntax error: {e.msg}",
            "text": (e.text or "").strip()[:200],
        })
        return

    # 1. High cyclomatic complexity per function
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            score = mccabe(node)
            if score >= CYCLOMATIC_THRESHOLD:
                findings.append({
                    "severity": "medium" if score < 20 else "high",
                    "kind": "debt",
                    "rule_id": "python-ast/high-cyclomatic",
                    "file": rel,
                    "line": node.lineno,
                    "message": f"function '{node.name}' cyclomatic complexity = {score}",
                    "text": f"def {node.name}(...)",
                })

    # 2. eval/exec usage
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            fn = node.func
            fname = None
            if isinstance(fn, ast.Name):
                fname = fn.id
            elif isinstance(fn, ast.Attribute):
                fname = fn.attr
            if fname in ("eval", "exec"):
                findings.append({
                    "severity": "critical",
                    "kind": "security",
                    "rule_id": f"python-ast/{fname}-usage",
                    "file": rel,
                    "line": node.lineno,
                    "message": f"use of {fname}() — code-injection sink",
                    "text": f"{fname}(...)",
                })

    # 3. subprocess with shell=True
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            is_subprocess = False
            fn = node.func
            if isinstance(fn, ast.Attribute) and isinstance(fn.value, ast.Name):
                is_subprocess = fn.value.id == "subprocess"
            for kw in node.keywords or []:
                if kw.arg == "shell":
                    v = kw.value
                    if isinstance(v, ast.Constant) and v.value is True:
                        if is_subprocess:
                            findings.append({
                                "severity": "high",
                                "kind": "security",
                                "rule_id": "python-ast/subprocess-shell-true",
                                "file": rel,
                                "line": node.lineno,
                                "message": "subprocess called with shell=True — command-injection risk",
                                "text": "subprocess.*(..., shell=True)",
                            })

    # 4. pickle.load / pickle.loads
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
            if (isinstance(node.func.value, ast.Name)
                    and node.func.value.id == "pickle"
                    and node.func.attr in ("load", "loads")):
                findings.append({
                    "severity": "high",
                    "kind": "security",
                    "rule_id": "python-ast/pickle-load",
                    "file": rel,
                    "line": node.lineno,
                    "message": "pickle.{load,loads} — arbitrary code execution on untrusted input",
                    "text": f"pickle.{node.func.attr}(...)",
                })


def main() -> int:
    if len(sys.argv) < 2:
        json.dump({"name": ANALYZER_NAME, "version": ANALYZER_VERSION, "findings": []}, sys.stdout)
        return 0
    target = sys.argv[1]
    if not os.path.isdir(target):
        json.dump({"name": ANALYZER_NAME, "version": ANALYZER_VERSION, "findings": []}, sys.stdout)
        return 0

    diff = sys.stdin.read() if not sys.stdin.isatty() else ""
    files = read_diff_files(diff)
    findings: list[dict] = []
    for rel in files:
        abs_path = os.path.join(target, rel)
        if os.path.isfile(abs_path):
            walk_file(abs_path, rel, findings)

    # Cap findings to 50 so a pathological file doesn't flood the JSON payload.
    findings = findings[:50]
    json.dump(
        {"name": ANALYZER_NAME, "version": ANALYZER_VERSION, "findings": findings},
        sys.stdout,
        ensure_ascii=False,
    )
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
