#!/usr/bin/env python3
"""Python symbol indexer — serves /file/imports, /file/exports, /symbol,
and /file/fingerprint.ast_hash from the Go coordination API.

Invocation:
    python-symbol-index.py <op> <file>            # imports | exports | ast_hash
    python-symbol-index.py symbol  <file> <name>  # specific symbol

Stdout is ALWAYS JSON. On error the process exits non-zero and writes a
reason to stderr; Go callers map that to HTTP 500.

Design constraints:
  * stdlib-only (no pip)
  * one-shot per call — callers cache
  * deterministic output ordering so ast_hash is stable across runs
"""
from __future__ import annotations

import ast
import hashlib
import json
import sys
from typing import Any


def _read(path: str) -> str:
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


def _parse(path: str) -> ast.AST:
    return ast.parse(_read(path), filename=path)


# ── imports ─────────────────────────────────────────────────────────────────

def op_imports(path: str) -> list[dict[str, Any]]:
    """Flat list of every import statement. One entry per imported name."""
    out: list[dict[str, Any]] = []
    try:
        tree = _parse(path)
    except SyntaxError:
        return out
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                out.append({
                    "module": alias.name,
                    "symbol_imported": None,
                    "alias": alias.asname,
                    "line": node.lineno,
                })
        elif isinstance(node, ast.ImportFrom):
            mod = node.module or ""
            if node.level:
                mod = ("." * node.level) + mod
            for alias in node.names:
                out.append({
                    "module": mod,
                    "symbol_imported": alias.name,
                    "alias": alias.asname,
                    "line": node.lineno,
                })
    out.sort(key=lambda x: (x["line"], x["module"], x.get("symbol_imported") or ""))
    return out


# ── exports ─────────────────────────────────────────────────────────────────

def _kind(n: ast.AST) -> str:
    if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)): return "function"
    if isinstance(n, ast.ClassDef):                            return "class"
    if isinstance(n, ast.Assign):                              return "variable"
    if isinstance(n, ast.AnnAssign):                           return "variable"
    return "other"


def op_exports(path: str) -> list[dict[str, Any]]:
    """Top-level definitions. `public` is True for names not starting with '_'."""
    out: list[dict[str, Any]] = []
    try:
        tree = _parse(path)
    except SyntaxError:
        return out
    for node in tree.body:
        names: list[str] = []
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names = [node.name]
        elif isinstance(node, ast.Assign):
            for tgt in node.targets:
                if isinstance(tgt, ast.Name):
                    names.append(tgt.id)
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            names = [node.target.id]
        for name in names:
            out.append({
                "name":   name,
                "kind":   _kind(node),
                "lineno": node.lineno,
                "public": not name.startswith("_"),
            })
    out.sort(key=lambda x: x["lineno"])
    return out


# ── symbol detail ───────────────────────────────────────────────────────────

def _signature(fn: ast.AST) -> str:
    """Best-effort reconstruction of a def signature from the AST."""
    if not isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef)):
        if isinstance(fn, ast.ClassDef):
            bases = ", ".join(ast.unparse(b) for b in fn.bases)
            return f"class {fn.name}({bases})"
        return ""
    try:
        args  = ast.unparse(fn.args)
    except Exception:
        args = "..."
    ret = ""
    if fn.returns is not None:
        try:
            ret = " -> " + ast.unparse(fn.returns)
        except Exception:
            ret = ""
    prefix = "async def" if isinstance(fn, ast.AsyncFunctionDef) else "def"
    return f"{prefix} {fn.name}({args}){ret}"


def _callee_name(call: ast.Call) -> str:
    fn = call.func
    if isinstance(fn, ast.Name):
        return fn.id
    if isinstance(fn, ast.Attribute):
        parts: list[str] = [fn.attr]
        cur: ast.AST = fn.value
        while isinstance(cur, ast.Attribute):
            parts.append(cur.attr)
            cur = cur.value
        if isinstance(cur, ast.Name):
            parts.append(cur.id)
        return ".".join(reversed(parts))
    return ""


def op_symbol(path: str, name: str) -> dict[str, Any]:
    """Return the definition of `name` plus in-file callers/callees."""
    try:
        tree = _parse(path)
    except SyntaxError as e:
        return {"error": "syntax_error", "message": e.msg, "line": e.lineno}

    # find the target definition (top-level first, then any)
    target: ast.AST | None = None
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and node.name == name:
            target = node
            break
    if target is None:
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and node.name == name:
                target = node
                break
    if target is None:
        return {"error": "not_found", "name": name, "file": path}

    # in-file callers: any Call whose callee resolves to `name`
    callers: list[dict[str, Any]] = []
    for n in ast.walk(tree):
        if isinstance(n, ast.Call):
            callee = _callee_name(n)
            if callee == name and getattr(n, "lineno", None) != getattr(target, "lineno", None):
                callers.append({"file": path, "line": n.lineno})

    # in-scope callees: calls made inside the target's body
    callees_seen: set[str] = set()
    callees: list[dict[str, Any]] = []
    for n in ast.walk(target):
        if isinstance(n, ast.Call):
            c = _callee_name(n)
            if c and c != name and c not in callees_seen:
                callees_seen.add(c)
                callees.append({"name": c})

    return {
        "name":       getattr(target, "name", name),
        "kind":       _kind(target),
        "signature":  _signature(target),
        "lineno":     getattr(target, "lineno", 0),
        "callers":    callers,
        "callees":    callees,
        "test_coverage": [],  # v1: not implemented
    }


# ── ast_hash ────────────────────────────────────────────────────────────────

def _normalize(node: ast.AST) -> Any:
    """Serialize an AST to a whitespace-/line-insensitive canonical form.

    We strip lineno/col_offset and any context marker that doesn't affect
    semantics, then encode the tree as nested lists. Two files that differ
    only in formatting produce the same hash.
    """
    if isinstance(node, ast.AST):
        fields = []
        for field, value in ast.iter_fields(node):
            if field in ("lineno", "col_offset", "end_lineno", "end_col_offset",
                         "type_comment"):
                continue
            fields.append((field, _normalize(value)))
        return [type(node).__name__, fields]
    if isinstance(node, list):
        return [_normalize(x) for x in node]
    return node


def op_ast_hash(path: str) -> str:
    try:
        tree = _parse(path)
    except SyntaxError:
        return "sha256:syntax_error"
    canon = json.dumps(_normalize(tree), sort_keys=True, separators=(",", ":"))
    return "sha256:" + hashlib.sha256(canon.encode("utf-8")).hexdigest()


# ── main ────────────────────────────────────────────────────────────────────

def main() -> int:
    if len(sys.argv) < 3:
        sys.stderr.write("usage: python-symbol-index.py <op> <file> [name]\n")
        return 2
    op   = sys.argv[1]
    file = sys.argv[2]

    try:
        if op == "imports":
            json.dump(op_imports(file), sys.stdout, ensure_ascii=False)
        elif op == "exports":
            json.dump(op_exports(file), sys.stdout, ensure_ascii=False)
        elif op == "symbol":
            if len(sys.argv) < 4:
                sys.stderr.write("symbol op requires a <name> argument\n")
                return 2
            result = op_symbol(file, sys.argv[3])
            json.dump(result, sys.stdout, ensure_ascii=False)
            if result.get("error") == "not_found":
                return 1
        elif op == "ast_hash":
            sys.stdout.write(op_ast_hash(file))
        else:
            sys.stderr.write(f"unknown op: {op}\n")
            return 2
        sys.stdout.write("\n")
        return 0
    except FileNotFoundError:
        sys.stderr.write(f"file not found: {file}\n")
        return 1
    except Exception as e:  # noqa: BLE001 — json out, stderr detail
        sys.stderr.write(f"indexer error: {type(e).__name__}: {e}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
