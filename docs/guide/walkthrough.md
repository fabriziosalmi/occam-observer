# Occam Observer — end-to-end walkthrough

Tutto vero, niente mock. Un piccolo repo Python simulato, una PR con secret
injection + dead-code helper, poi tutti gli endpoint in ordine realistico:
planner → worker → refiner → cross-cutting.

## Setup usato

- Repo demo in Python con `src/db.py`, `tests/test_db.py`, `pyproject.toml`
- Branch `feat/caching` su commit `FEAT` (con `API_KEY` leak + `eval()` helper)
- `main` su `BASE` (versione pulita)
- Gateway Go su `127.0.0.1:29999`
- SQLite TSDB su `/tmp/demo_snapshots.db`


---

## 1. `GET /healthz` — the process is up
```bash
curl -s http://127.0.0.1:29999/healthz
```
```json
{
  "status": "ok",
  "uptime_seconds": 28.1
}
```

## 2. `GET /readyz` — ready to serve requests
```bash
curl -s http://127.0.0.1:29999/readyz
```
```json
{
  "status": "ready"
}
```

## 3. `GET /repo/context` — planner's repo-wide snapshot
```bash
curl -s "http://127.0.0.1:29999/repo/context?target=$REPO"
```
```json
{
  "hot_files": [
    {
      "path": "src/db.py",
      "changes": 41
    },
    {
      "path": "tests/test_db.py",
      "changes": 7
    },
    {
      "path": "pyproject.toml",
      "changes": 5
    },
    {
      "path": "README.md",
      "changes": 2
    }
  ],
  "languages": [
    {
      "name": "Python",
      "files": 2,
      "bytes": 1212
    },
    {
      "name": "Markdown",
      "files": 1,
      "bytes": 78
    },
    {
      "name": "TOML",
      "files": 1,
      "bytes": 93
    }
  ],
  "recent_churn": {
    "deletions": 5,
    "files_touched": 4,
    "insertions": 50,
    "since_days": 7
  },
  "stable_files": [],
  "stack": [
    "python/poetry"
  ],
  "target": "/tmp/demo_repo_nVGaMX"
}
```

## 4. `GET /repo/churn/:path` — how often does this file move?
```bash
curl -s "http://127.0.0.1:29999/repo/churn/src/db.py?target=$REPO&since=30d"
```
```json
{
  "contributors": [
    "alice@example.com",
    "gitoma-bot@demo"
  ],
  "modifications": 2,
  "path": "src/db.py",
  "reverts": 0,
  "since": "30d"
}
```

## 5. `GET /repo/blame/:path` — per-line blame + agent + revert detection
```bash
curl -s "http://127.0.0.1:29999/repo/blame/src/db.py?target=$REPO"
```
```json
[
  {
    "author": "Alice",
    "commit": "093f8d97667f",
    "email": "alice@example.com",
    "line": 1,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "gitoma-bot",
    "commit": "4d57183314d5",
    "email": "gitoma-bot@demo",
    "line": 2,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "Alice",
    "commit": "093f8d97667f",
    "email": "alice@example.com",
    "line": 3,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "Alice",
    "commit": "093f8d97667f",
    "email": "alice@example.com",
    "line": 4,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "Alice",
    "commit": "093f8d97667f",
    "email": "alice@example.com",
    "line": 5,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "gitoma-bot",
    "commit": "4d57183314d5",
    "email": "gitoma-bot@demo",
    "line": 6,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "gitoma-bot",
    "commit": "4d57183314d5",
    "email": "gitoma-bot@demo",
    "line": 7,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "gitoma-bot",
    "commit": "4d57183314d5",
    "email": "gitoma-bot@demo",
    "line": 8,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "gitoma-bot",
    "commit": "4d57183314d5",
    "email": "gitoma-bot@demo",
    "line": 9,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "gitoma-bot",
    "commit": "4d57183314d5",
    "email": "gitoma-bot@demo",
    "line": 10,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "gitoma-bot",
    "commit": "4d57183314d5",
    "email": "gitoma-bot@demo",
    "line": 11,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "gitoma-bot",
    "commit": "4d57183314d5",
    "email": "gitoma-bot@demo",
    "line": 12,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "Alice",
    "commit": "093f8d97667f",
    "email": "alice@example.com",
    "line": 13,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "Alice",
    "commit": "093f8d97667f",
    "email": "alice@example.com",
    "line": 14,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "Alice",
    "commit": "093f8d97667f",
    "email": "alice@example.com",
    "line": 15,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "Alice",
    "commit": "093f8d97667f",
    "email": "alice@example.com",
    "line": 16,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "Alice",
    "commit": "093f8d97667f",
    "email": "alice@example.com",
    "line": 17,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "Alice",
    "commit": "093f8d97667f",
    "email": "alice@example.com",
    "line": 18,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "Alice",
    "commit": "093f8d97667f",
    "email": "alice@example.com",
    "line": 19,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "gitoma-bot",
    "commit": "4d57183314d5",
    "email": "gitoma-bot@demo",
    "line": 20,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "gitoma-bot",
    "commit": "4d57183314d5",
    "email": "gitoma-bot@demo",
    "line": 21,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "Alice",
    "commit": "093f8d97667f",
    "email": "alice@example.com",
    "line": 22,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "Alice",
    "commit": "093f8d97667f",
    "email": "alice@example.com",
    "line": 23,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "Alice",
    "commit": "093f8d97667f",
    "email": "alice@example.com",
    "line": 24,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "Alice",
    "commit": "093f8d97667f",
    "email": "alice@example.com",
    "line": 25,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "Alice",
    "commit": "093f8d97667f",
    "email": "alice@example.com",
    "line": 26,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "Alice",
    "commit": "093f8d97667f",
    "email": "alice@example.com",
    "line": 27,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "gitoma-bot",
    "commit": "4d57183314d5",
    "email": "gitoma-bot@demo",
    "line": 28,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "gitoma-bot",
    "commit": "4d57183314d5",
    "email": "gitoma-bot@demo",
    "line": 29,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "gitoma-bot",
    "commit": "4d57183314d5",
    "email": "gitoma-bot@demo",
    "line": 30,
    "when": "2026-04-23T14:30:40Z"
  },
  {
    "author": "gitoma-bot",
    "commit": "4d57183314d5",
    "email": "gitoma-bot@demo",
    "line": 31,
    "when": "2026-04-23T14:30:40Z"
  }
]
```

## 6. `GET /file/fingerprint` — stable identity hashes
```bash
curl -s "http://127.0.0.1:29999/file/fingerprint?path=$REPO/src/db.py"
```
```json
{
  "ast_hash": "sha256:21fb19332fcd4d7d16bb49ef3286aef3cfda181feb73657919fbe7ba73c117eb",
  "content_hash": "sha256:2b8011b6f79f7655a5b411bbc492e31abf0b84b9faca61fc8af3a6946cb2d712",
  "path": "/tmp/demo_repo_nVGaMX/src/db.py",
  "sha": "a7142ed92064fc89d55ab0b48f0a06ba240bbd20",
  "test_coverage_hash": null
}
```

## 7. `GET /file/imports` — worker needs to know what ships in/out
```bash
curl -s "http://127.0.0.1:29999/file/imports?path=$REPO/src/db.py"
```
```json
[
  {
    "module": "os",
    "line": 2
  },
  {
    "module": "sqlite3",
    "line": 3
  },
  {
    "module": "typing",
    "symbol_imported": "Optional",
    "line": 4
  }
]
```

## 8. `GET /file/exports` — "don't break these" — public surface
```bash
curl -s "http://127.0.0.1:29999/file/exports?path=$REPO/src/db.py"
```
```json
[
  {
    "name": "API_KEY",
    "kind": "variable",
    "lineno": 7,
    "public": true
  },
  {
    "name": "get_conn",
    "kind": "function",
    "lineno": 9,
    "public": true
  },
  {
    "name": "init_schema",
    "kind": "function",
    "lineno": 16,
    "public": true
  },
  {
    "name": "lookup",
    "kind": "function",
    "lineno": 25,
    "public": true
  },
  {
    "name": "eval_predicate",
    "kind": "function",
    "lineno": 29,
    "public": true
  }
]
```

## 9. `GET /symbol` — signature + in-file callers/callees
```bash
curl -s "http://127.0.0.1:29999/symbol?path=$REPO/src/db.py&name=get_conn"
```
```json
{
  "name": "get_conn",
  "kind": "function",
  "signature": "def get_conn(db: Optional[str]=None) -> sqlite3.Connection",
  "lineno": 9,
  "callers": [],
  "callees": [
    {
      "name": "sqlite3.connect"
    },
    {
      "name": "os.environ.get"
    }
  ]
}
```

## 10. `GET /contract` — the public API summary
```bash
curl -s "http://127.0.0.1:29999/contract?path=$REPO/src/db.py"
```
```json
{
  "coupling_score": 0,
  "path": "/tmp/demo_repo_nVGaMX/src/db.py",
  "public_api": [
    {
      "name": "API_KEY",
      "kind": "variable",
      "lineno": 7,
      "public": true
    },
    {
      "name": "get_conn",
      "kind": "function",
      "lineno": 9,
      "public": true
    },
    {
      "name": "init_schema",
      "kind": "function",
      "lineno": 16,
      "public": true
    },
    {
      "name": "lookup",
      "kind": "function",
      "lineno": 25,
      "public": true
    },
    {
      "name": "eval_predicate",
      "kind": "function",
      "lineno": 29,
      "public": true
    }
  ],
  "test_coverage": 0,
  "v1_note": "test_coverage and coupling_score require test-runs integration and a cross-file symbol index (deferred)"
}
```

## 11. `GET /diff` — semantic delta between main and feat/caching
```bash
curl -s "http://127.0.0.1:29999/diff?target=$REPO&base=main&branch=feat/caching"
```
```json
{
  "ast_top_level_delta": {
    "added": [
      {
        "file": "src/db.py",
        "name": "eval_predicate",
        "kind": "function"
      },
      {
        "file": "src/db.py",
        "name": "API_KEY",
        "kind": "variable"
      }
    ],
    "modified": [
      {
        "file": "src/db.py",
        "name": "get_conn",
        "kind": "function"
      },
      {
        "file": "src/db.py",
        "name": "init_schema",
        "kind": "function"
      },
      {
        "file": "src/db.py",
        "name": "lookup",
        "kind": "function"
      }
    ],
    "removed": []
  },
  "base": "main",
  "branch": "feat/caching",
  "target": "/tmp/demo_repo_nVGaMX",
  "tests_delta": {
    "status": "not_implemented"
  },
  "touched_files": [
    "src/db.py"
  ]
}
```

## 12. `GET /analyze` — the full telemetry payload (what /ui/ reads)
```bash
curl -s "http://127.0.0.1:29999/analyze?path=$REPO"
```
```json
{
  "version": "3.1.0",
  "trace_id": "e3229cae358f2e01",
  "timestamp": "2026-04-23T16:31:21+0200",
  "branch": "feat/caching",
  "commit": "4d57183",
  "target": "/tmp/demo_repo_nVGaMX",
  "diff_mode": "head",
  "is_idle": false,
  "metrics": {
    "security_violations": 0,
    "mass_insertions": 0,
    "mass_deletions": 0,
    "mass_files_changed": 0,
    "entropy_nodes": 0,
    "test_files_modified": 0,
    "debt_issues": 0
  },
  "snippets": {
    "security": "",
    "debt": ""
  },
  "git": {
    "author": "gitoma-bot <gitoma-bot@demo>",
    "message": "feat(db): env-var dsn, created_at, helper predicate",
    "time": "2026-04-23T16:30:40+02:00",
    "remote": "",
    "is_dirty": false
  },
  "intelligence": {
    "file_types": {
      "logic": [],
      "config": [],
      "docs": [],
      "media": []
    },
    "infrastructure_changes": [],
    "schema_mutations": [],
    "network_outbound": [],
    "signatures_added": [],
    "dependencies_added": [],
    "syntax_valid": [],
    "syntax_invalid": [],
    "violations": [],
    "analyzers": []
  },
  "health_score": 100,
  "check": {
    "level": "none",
    "reasons": []
  },
  "performance": {
    "engine_duration_ms": 0,
    "diff_bytes": 0,
    "analyzers_run": []
  },
  "thresholds": {
    "mass_warn": 150,
    "mass_critical": 300,
    "entropy_warn": 5,
    "entropy_critical": 10
  }
}
```

## 13. `POST /observation` — the agent logs what it did
```bash
curl -s -X POST -H 'content-type: application/json' -d '{
  "run_id":        "gitoma-run-42",
  "agent":         "gitoma",
  "subtask_id":    "sub-3-cache-dsn",
  "model":         "claude-opus-4.7",
  "branch":        "feat/caching",
  "commit_sha":    "4d57183314d5d6dddaaa5c64af13287a92729cbb",
  "outcome":       "success",
  "touched_files": ["src/db.py"],
  "failure_modes": [],
  "confidence":    0.78
}' "http://127.0.0.1:29999/observation"
```
```json
{
  "id": 1,
  "ts": "2026-04-23T14:31:52Z"
}
```

## 14. `GET /repo/agent-log` — planner reads the history
```bash
curl -s "http://127.0.0.1:29999/repo/agent-log?since=24h&limit=10"
```
```json
[
  {
    "agent": "gitoma",
    "branch": "feat/caching",
    "commit_sha": null,
    "confidence": 0.35,
    "failure_modes": [
      "mypy-strict-mode-error",
      "missing-return-annotation"
    ],
    "id": 2,
    "model": "claude-opus-4.7",
    "outcome": "fail",
    "run_id": "gitoma-run-42",
    "subtask_id": "sub-4-type-hints",
    "touched_files": [
      "src/db.py"
    ],
    "ts": "2026-04-23T14:31:52Z"
  },
  {
    "agent": "gitoma",
    "branch": "feat/caching",
    "commit_sha": "4d57183314d5d6dddaaa5c64af13287a92729cbb",
    "confidence": 0.78,
    "failure_modes": [],
    "id": 1,
    "model": "claude-opus-4.7",
    "outcome": "success",
    "run_id": "gitoma-run-42",
    "subtask_id": "sub-3-cache-dsn",
    "touched_files": [
      "src/db.py"
    ],
    "ts": "2026-04-23T14:31:52Z"
  }
]
```

## 15. `GET /agent/identity/:commit` — who wrote this SHA?
```bash
curl -s "http://127.0.0.1:29999/agent/identity/4d57183314d5d6dddaaa5c64af13287a92729cbb"
```
```json
{
  "agent": "gitoma",
  "confidence": 0.78,
  "model": "claude-opus-4.7",
  "run_id": "gitoma-run-42",
  "subtask_id": "sub-3-cache-dsn",
  "ts": "2026-04-23T14:31:52Z"
}
```

## 16. `POST /claim` — worker takes an exclusive lock on the file
```bash
curl -s -X POST -H 'content-type: application/json' \
  -d '{"path":"/repo/src/db.py","agent":"gitoma","run_id":"run-42","ttl_seconds":120}' \
  "http://127.0.0.1:29999/claim"
```
```json
{
  "expires_at": "2026-04-23T14:33:52Z",
  "lock_id": "6f13e0cf0f8408dc"
}
```

## 17. `POST /claim` (conflict) — a second agent tries the same file
```bash
# Another worker tries to claim the same path:
curl -si -X POST -H 'content-type: application/json' \
  -d '{"path":"/repo/src/db.py","agent":"other-agent"}' "http://127.0.0.1:29999/claim"
```
```
HTTP/1.1 409 Conflict
Content-Type: application/json
Content-Length: 139
{"error":"already_claimed","held_by":{"agent":"gitoma","expires_at":"2026-04-23T14:33:52Z","lock_id":"6f13e0cf0f8408dc","run_id":"run-42"}}
```

## 18. `GET /claim?path=…` — who holds what, right now?
```bash
curl -s "http://127.0.0.1:29999/claim?path=$REPO/src/db.py"
```
```json
[
  {
    "acquired": "2026-04-23T14:31:52Z",
    "agent": "gitoma",
    "expires_at": "2026-04-23T14:33:52Z",
    "lock_id": "6f13e0cf0f8408dc",
    "path": "/tmp/demo_repo_nVGaMX/src/db.py",
    "run_id": "run-42"
  }
]
```

## 19. `DELETE /claim?lock_id=…` — worker releases the lock
```bash
curl -s -X DELETE "http://127.0.0.1:29999/claim?lock_id=$LOCK_ID"
```
```json
{
  "released": true
}
```

## 20. `GET /trend` — how has this repo's health moved?
```bash
curl -s "http://127.0.0.1:29999/trend?target=$REPO&limit=5"
```
```json
[
  {
    "id": 4,
    "ts": "2026-04-23T16:31:21+0200",
    "target": "/tmp/demo_repo_nVGaMX",
    "branch": "feat/caching",
    "commit_sha": "4d57183",
    "health_score": 100,
    "security_violations": 0,
    "mass_insertions": 0,
    "mass_deletions": 0,
    "mass_files_changed": 0,
    "entropy_nodes": 0,
    "test_files_modified": 0,
    "debt_issues": 0,
    "check_level": "none",
    "diff_mode": "head"
  },
  {
    "id": 3,
    "ts": "2026-04-23T16:30:53+0200",
    "target": "/tmp/demo_repo_nVGaMX",
    "branch": "feat/caching",
    "commit_sha": "4d57183",
    "health_score": 100,
    "security_violations": 0,
    "mass_insertions": 0,
    "mass_deletions": 0,
    "mass_files_changed": 0,
    "entropy_nodes": 0,
    "test_files_modified": 0,
    "debt_issues": 0,
    "check_level": "none",
    "diff_mode": "head"
  },
  {
    "id": 2,
    "ts": "2026-04-23T16:30:53+0200",
    "target": "/tmp/demo_repo_nVGaMX",
    "branch": "main",
    "commit_sha": "093f8d9",
    "health_score": 100,
    "security_violations": 0,
    "mass_insertions": 0,
    "mass_deletions": 0,
    "mass_files_changed": 0,
    "entropy_nodes": 0,
    "test_files_modified": 0,
    "debt_issues": 0,
    "check_level": "none",
    "diff_mode": "head"
  },
  {
    "id": 1,
    "ts": "2026-04-23T16:30:53+0200",
    "target": "/tmp/demo_repo_nVGaMX",
    "branch": "feat/caching",
    "commit_sha": "4d57183",
    "health_score": 100,
    "security_violations": 0,
    "mass_insertions": 0,
    "mass_deletions": 0,
    "mass_files_changed": 0,
    "entropy_nodes": 0,
    "test_files_modified": 0,
    "debt_issues": 0,
    "check_level": "none",
    "diff_mode": "head"
  }
]
```

## 21. `GET /metrics` — Prometheus scrape target
```bash
curl -s http://127.0.0.1:29999/metrics
```
```
# HELP occam_up 1 if the API process is up
# TYPE occam_up gauge
occam_up 1
# HELP occam_uptime_seconds Seconds since process start
# TYPE occam_uptime_seconds gauge
occam_uptime_seconds 60.292
# HELP occam_analyses_total Number of /analyze requests handled, by outcome
# TYPE occam_analyses_total counter
occam_analyses_total{result="ok"} 4
occam_analyses_total{result="error"} 0
# HELP occam_analyze_duration_seconds Summary of /analyze wall time
# TYPE occam_analyze_duration_seconds summary
occam_analyze_duration_seconds_count 4
occam_analyze_duration_seconds_sum 1.067878
# HELP occam_trend_requests_total Number of /trend requests handled, by outcome
# TYPE occam_trend_requests_total counter
occam_trend_requests_total{result="ok"} 1
occam_trend_requests_total{result="error"} 0
# HELP occam_cache_age_seconds Age of the write-through JSON cache (-1 if absent)
# TYPE occam_cache_age_seconds gauge
occam_cache_age_seconds 3184.493
# HELP occam_snapshots_total Rows in the TSDB (refreshed every 30s)
# TYPE occam_snapshots_total gauge
occam_snapshots_total 4
```

## 22. Stubs — the 501 shape (so agents can probe capability)
```bash
curl -si "http://127.0.0.1:29999/file/frozen-regions?path=$REPO/src/db.py"
```
```
HTTP/1.1 501 Not Implemented
Content-Type: application/json
Content-Length: 143
{"path":"/file/frozen-regions","reason":"needs frozen-region contract design (inline markers vs .occam-frozen.yml)","status":"not_implemented"}
```

---

---

## 23. MCP tool call — same result, stdio JSON-RPC 2.0

For agents that speak MCP (Claude Desktop, Cursor, Windsurf, VS Code,
Zed, Continue), every endpoint above is also a tool. Handshake +
`tools/list` + a real call:

```bash
printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","clientInfo":{"name":"demo","version":"1"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"occam_symbol","arguments":{"path":"/abs/repo/src/db.py","name":"get_conn"}}}' \
  | OCCAM_API_URL="http://127.0.0.1:29999" \
    ENGINE_SCRIPT="$PWD/telemetry_observer.sh" \
    OCCAM_DB="/tmp/demo_snapshots.db" \
    occam-mcp \
  | jq -c .
```

Actual output (one JSON-RPC envelope per line, compacted for readability):

```
{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"tools":{"listChanged":false}},"instructions":"Call occam_analyze with an absolute repo path to get structured telemetry. Use occam_check for gate-style pass/fail. occam_trend returns historical snapshots from SQLite.","protocolVersion":"2024-11-05","serverInfo":{"name":"occam-observer-mcp","version":"3.1.0"}}}
{"id":2,"result":{"tools_count":20,"first_3":["occam_analyze","occam_check","occam_trend"]}}
{"id":3,"isError":false,"parsed_content":{"name":"get_conn","kind":"function","signature":"def get_conn(db: Optional[str]=None) -> sqlite3.Connection","lineno":9,"callers":[],"callees":[{"name":"sqlite3.connect"},{"name":"os.environ.get"}]}}
```

## 24. Error shapes — consistent JSON envelope on every failure path

Validation, not-found, and engine errors all return JSON so agents can parse
uniformly, never scraping text.

### Bad path (flag-like)
```bash
curl -si "http://127.0.0.1:29999/analyze?path=--evil"
```
```
HTTP/1.1 400 Bad Request
Content-Type: application/json

{"error":"path must not start with '-'"}
```

### Nonexistent path
```bash
curl -si "http://127.0.0.1:29999/analyze?path=/does/not/exist"
```
```
HTTP/1.1 400 Bad Request
Content-Type: application/json

{"error":"path does not exist"}
```

### Non-git target on a coordination endpoint
```bash
curl -si "http://127.0.0.1:29999/repo/context?target=/tmp"
```
```
HTTP/1.1 400 Bad Request
Content-Type: application/json

{"details":"/tmp","error":"target is not a git repository"}
```

### Second claim on already-held path
```bash
curl -si -X POST -H 'content-type: application/json' \
     -d '{"path":"/repo/src/db.py","agent":"a","ttl_seconds":60}' \
     "http://127.0.0.1:29999/claim"
# then, with a different agent:
curl -si -X POST -H 'content-type: application/json' \
     -d '{"path":"/repo/src/db.py","agent":"b"}' \
     "http://127.0.0.1:29999/claim"
```

```json
HTTP/1.1 409 Conflict
Content-Type: application/json

{
  "error": "already_claimed",
  "held_by": {
    "lock_id":    "2b04766e752f7115",
    "agent":      "a",
    "run_id":     null,
    "expires_at": "2026-04-23T14:26:40Z"
  }
}
```

---

## Cheat sheet — which endpoint solves which agent problem

| Agent phase       | Question                                 | Endpoint                              |
|-------------------|------------------------------------------|---------------------------------------|
| PLANNER           | "what is this repo made of?"             | `GET /repo/context`                   |
| PLANNER           | "is this file a churn hotspot?"          | `GET /repo/churn/:path`               |
| PLANNER           | "who last touched this line?"            | `GET /repo/blame/:path`               |
| PLANNER           | "what have we tried recently?"           | `GET /repo/agent-log?since=24h`       |
| WORKER            | "what does this symbol's contract say?"  | `GET /symbol?path=&name=`             |
| WORKER            | "what public names am I about to break?" | `GET /file/exports?path=`             |
| WORKER            | "what does this file import?"            | `GET /file/imports?path=`             |
| WORKER            | "is anyone else editing this file?"      | `POST /claim` → 200 or 409            |
| REFINER           | "what actually changed between revs?"    | `GET /diff?base=&branch=`             |
| REFINER           | "who authored this commit?"              | `GET /agent/identity/:commit`         |
| CROSS-CUTTING     | "has this file changed semantically?"    | `GET /file/fingerprint?path=`         |
| CROSS-CUTTING     | "what is this file's surface area?"      | `GET /contract?path=`                 |
| CROSS-CUTTING     | "close the loop — here's what I did"     | `POST /observation`                   |
| OPERATIONS        | "is the service healthy?"                | `GET /healthz` · `/readyz` · `/metrics` |

All of these are also MCP tools — same args, same JSON shape, wrapped in an
MCP `content[0].text` block. Point your MCP-capable client at `occam-mcp`
with `ENGINE_SCRIPT`, `OCCAM_DB`, and `OCCAM_API_URL` in its env.

