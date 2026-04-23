# Occam Observer — end-to-end walkthrough

Tutto vero, niente mock. Un piccolo repo Python, una PR con secret
injection + taint-sink helper, poi tutti gli endpoint in ordine realistico:
planner → worker → refiner → cross-cutting → operations → MCP.

## Setup

- Repo demo Python con `src/db.py`, `tests/test_db.py`, `pyproject.toml`
- Branch `feat/caching` (autore `gitoma-bot`) vs `main` (autore `Alice`):
  aggiunge `API_KEY` in chiaro, `eval_predicate()`, `DEMO_DB` env var
- Gateway Go su `127.0.0.1:29998`
- SQLite TSDB su `/tmp/demo_snap_v020.db`
- `ENGINE_SCRIPT` punta a `telemetry_observer.sh`

---

## 1. `GET /healthz` — liveness
```bash
curl -s http://127.0.0.1:29998/healthz
```
```json
{
  "status": "ok",
  "uptime_seconds": 37.8
}
```

## 2. `GET /readyz` — readiness
```bash
curl -s http://127.0.0.1:29998/readyz
```
```json
{
  "status": "ready"
}
```

## 3. `GET /repo/context` — planner's repo-wide snapshot
```bash
curl -s "http://127.0.0.1:29998/repo/context?target=$REPO"
```
```json
{
  "hot_files": [
    {
      "path": "src/db.py",
      "changes": 35
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
      "bytes": 1091
    },
    {
      "name": "Markdown",
      "files": 1,
      "bytes": 31
    },
    {
      "name": "TOML",
      "files": 1,
      "bytes": 93
    }
  ],
  "recent_churn": {
    "deletions": 3,
    "files_touched": 4,
    "insertions": 46,
    "since_days": 7
  },
  "stable_files": [],
  "stack": [
    "python/poetry"
  ],
  "target": "/tmp/demo_repo_v020_VWEjRC"
}
```

## 4. `GET /repo/churn/:path` — is this file a hotspot?
```bash
curl -s "http://127.0.0.1:29998/repo/churn/src/db.py?target=$REPO&since=30d"
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

## 5. `GET /repo/blame/:path` — per-line blame (first 10 rows)
```bash
curl -s "http://127.0.0.1:29998/repo/blame/src/db.py?target=$REPO" | jq '.[0:10]'
```
```json
[
  {
    "author": "Alice",
    "commit": "40bda486d822",
    "email": "alice@example.com",
    "line": 1,
    "when": "2026-04-23T14:47:02Z"
  },
  {
    "author": "gitoma-bot",
    "commit": "af28e6b03244",
    "email": "gitoma-bot@demo",
    "line": 2,
    "when": "2026-04-23T14:47:02Z"
  },
  {
    "author": "Alice",
    "commit": "40bda486d822",
    "email": "alice@example.com",
    "line": 3,
    "when": "2026-04-23T14:47:02Z"
  },
  {
    "author": "Alice",
    "commit": "40bda486d822",
    "email": "alice@example.com",
    "line": 4,
    "when": "2026-04-23T14:47:02Z"
  },
  {
    "author": "Alice",
    "commit": "40bda486d822",
    "email": "alice@example.com",
    "line": 5,
    "when": "2026-04-23T14:47:02Z"
  },
  {
    "author": "gitoma-bot",
    "commit": "af28e6b03244",
    "email": "gitoma-bot@demo",
    "line": 6,
    "when": "2026-04-23T14:47:02Z"
  },
  {
    "author": "gitoma-bot",
    "commit": "af28e6b03244",
    "email": "gitoma-bot@demo",
    "line": 7,
    "when": "2026-04-23T14:47:02Z"
  },
  {
    "author": "gitoma-bot",
    "commit": "af28e6b03244",
    "email": "gitoma-bot@demo",
    "line": 8,
    "when": "2026-04-23T14:47:02Z"
  },
  {
    "author": "gitoma-bot",
    "commit": "af28e6b03244",
    "email": "gitoma-bot@demo",
    "line": 9,
    "when": "2026-04-23T14:47:02Z"
  },
  {
    "author": "gitoma-bot",
    "commit": "af28e6b03244",
    "email": "gitoma-bot@demo",
    "line": 10,
    "when": "2026-04-23T14:47:02Z"
  }
]
```

## 6. `GET /file/fingerprint` — identity hashes
```bash
curl -s "http://127.0.0.1:29998/file/fingerprint?path=$REPO/src/db.py"
```
```json
{
  "ast_hash": "sha256:80cd72d2de085f042834cca71b1c74cddffde4a64f81c3ea93e6e2c970f8690a",
  "content_hash": "sha256:6f5fe7f9f3e21b3d4b4e024a9519f8b66ec76c631dfd18a3922ec974e9158d14",
  "path": "/tmp/demo_repo_v020_VWEjRC/src/db.py",
  "sha": "b0f311595ed747ad9b1b844d3d322164c1d242ef",
  "test_coverage_hash": null
}
```

## 7. `GET /file/imports` — what does this file pull in?
```bash
curl -s "http://127.0.0.1:29998/file/imports?path=$REPO/src/db.py"
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

## 8. `GET /file/exports` — the public surface (don't break these)
```bash
curl -s "http://127.0.0.1:29998/file/exports?path=$REPO/src/db.py"
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
    "lineno": 15,
    "public": true
  },
  {
    "name": "lookup",
    "kind": "function",
    "lineno": 24,
    "public": true
  },
  {
    "name": "eval_predicate",
    "kind": "function",
    "lineno": 28,
    "public": true
  }
]
```

## 9. `GET /symbol` — signature + in-file callers/callees
```bash
curl -s "http://127.0.0.1:29998/symbol?path=$REPO/src/db.py&name=get_conn"
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

## 10. `GET /contract` — public API summary
```bash
curl -s "http://127.0.0.1:29998/contract?path=$REPO/src/db.py"
```
```json
{
  "coupling_score": 0,
  "path": "/tmp/demo_repo_v020_VWEjRC/src/db.py",
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
      "lineno": 15,
      "public": true
    },
    {
      "name": "lookup",
      "kind": "function",
      "lineno": 24,
      "public": true
    },
    {
      "name": "eval_predicate",
      "kind": "function",
      "lineno": 28,
      "public": true
    }
  ],
  "test_coverage": 0,
  "v1_note": "test_coverage and coupling_score require test-runs integration and a cross-file symbol index (deferred)"
}
```

## 11. `GET /diff` — semantic delta main → feat/caching
```bash
curl -s "http://127.0.0.1:29998/diff?target=$REPO&base=main&branch=feat/caching"
```
```json
{
  "ast_top_level_delta": {
    "added": [
      {
        "file": "src/db.py",
        "name": "API_KEY",
        "kind": "variable"
      },
      {
        "file": "src/db.py",
        "name": "eval_predicate",
        "kind": "function"
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
  "target": "/tmp/demo_repo_v020_VWEjRC",
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
curl -s "http://127.0.0.1:29998/analyze?path=$REPO"
```
```json
{
  "version": "0.2.0",
  "trace_id": "56c36de8dfb8a118",
  "timestamp": "2026-04-23T16:47:40+0200",
  "branch": "feat/caching",
  "commit": "af28e6b",
  "target": "/tmp/demo_repo_v020_VWEjRC",
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
    "time": "2026-04-23T16:47:02+02:00",
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
  "commit_sha":    "$FEAT_COMMIT",
  "outcome":       "success",
  "touched_files": ["src/db.py"],
  "failure_modes": [],
  "confidence":    0.78
}' "http://127.0.0.1:29998/observation"
```
```json
{
  "id": 1,
  "ts": "2026-04-23T14:48:16Z"
}
```

## 14. `GET /repo/agent-log` — planner reads the history
```bash
curl -s "http://127.0.0.1:29998/repo/agent-log?since=24h&limit=10"
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
    "ts": "2026-04-23T14:48:16Z"
  },
  {
    "agent": "gitoma",
    "branch": "feat/caching",
    "commit_sha": "af28e6b03244abaa9a093ae9515e6a8e2b6c60ef",
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
    "ts": "2026-04-23T14:48:16Z"
  }
]
```

## 15. `GET /agent/identity/:commit` — who wrote this SHA?
```bash
curl -s "http://127.0.0.1:29998/agent/identity/$FEAT_COMMIT"
```
```json
{
  "agent": "gitoma",
  "confidence": 0.78,
  "model": "claude-opus-4.7",
  "run_id": "gitoma-run-42",
  "subtask_id": "sub-3-cache-dsn",
  "ts": "2026-04-23T14:48:16Z"
}
```

## 16. `POST /claim` — worker acquires an exclusive file lock
```bash
curl -s -X POST -H 'content-type: application/json' \
  -d '{"path":"/repo/src/db.py","agent":"gitoma","run_id":"run-42","ttl_seconds":120}' \
  "http://127.0.0.1:29998/claim"
```
```json
{
  "expires_at": "2026-04-23T14:50:16Z",
  "lock_id": "bd7f678dfd32d9a1"
}
```

## 17. `POST /claim` (conflict) — second agent tries same file
```bash
curl -si -X POST -H 'content-type: application/json' \
  -d '{"path":"/repo/src/db.py","agent":"other-agent"}' "http://127.0.0.1:29998/claim"
```
```
HTTP/1.1 409 Conflict
Content-Type: application/json

{"error":"already_claimed","held_by":{"agent":"gitoma","expires_at":"2026-04-23T14:50:16Z","lock_id":"bd7f678dfd32d9a1","run_id":"run-42"}}
```

## 18. `GET /claim?path=…` — who holds what right now
```bash
curl -s "http://127.0.0.1:29998/claim?path=$REPO/src/db.py"
```
```json
[
  {
    "acquired": "2026-04-23T14:48:16Z",
    "agent": "gitoma",
    "expires_at": "2026-04-23T14:50:16Z",
    "lock_id": "bd7f678dfd32d9a1",
    "path": "/tmp/demo_repo_v020_VWEjRC/src/db.py",
    "run_id": "run-42"
  }
]
```

## 19. `DELETE /claim?lock_id=…` — release (idempotent)
```bash
curl -s -X DELETE "http://127.0.0.1:29998/claim?lock_id=$LOCK_ID"
```
```json
{
  "released": true
}
```

## 20. `GET /trend` — how has the repo moved?
```bash
curl -s "http://127.0.0.1:29998/trend?target=$REPO&limit=5"
```
```json
[
  {
    "id": 4,
    "ts": "2026-04-23T16:47:40+0200",
    "target": "/tmp/demo_repo_v020_VWEjRC",
    "branch": "feat/caching",
    "commit_sha": "af28e6b",
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
    "ts": "2026-04-23T16:47:04+0200",
    "target": "/tmp/demo_repo_v020_VWEjRC",
    "branch": "feat/caching",
    "commit_sha": "af28e6b",
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
    "ts": "2026-04-23T16:47:03+0200",
    "target": "/tmp/demo_repo_v020_VWEjRC",
    "branch": "main",
    "commit_sha": "40bda48",
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
    "ts": "2026-04-23T16:47:03+0200",
    "target": "/tmp/demo_repo_v020_VWEjRC",
    "branch": "feat/caching",
    "commit_sha": "af28e6b",
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
curl -s http://127.0.0.1:29998/metrics
```
```
# HELP occam_up 1 if the API process is up
# TYPE occam_up gauge
occam_up 1
# HELP occam_uptime_seconds Seconds since process start
# TYPE occam_uptime_seconds gauge
occam_uptime_seconds 73.790
# HELP occam_analyses_total Number of /analyze requests handled, by outcome
# TYPE occam_analyses_total counter
occam_analyses_total{result="ok"} 4
occam_analyses_total{result="error"} 0
# HELP occam_analyze_duration_seconds Summary of /analyze wall time
# TYPE occam_analyze_duration_seconds summary
occam_analyze_duration_seconds_count 4
occam_analyze_duration_seconds_sum 1.295755
# HELP occam_trend_requests_total Number of /trend requests handled, by outcome
# TYPE occam_trend_requests_total counter
occam_trend_requests_total{result="ok"} 1
occam_trend_requests_total{result="error"} 0
# HELP occam_cache_age_seconds Age of the write-through JSON cache (-1 if absent)
# TYPE occam_cache_age_seconds gauge
occam_cache_age_seconds 4168.056
# HELP occam_snapshots_total Rows in the TSDB (refreshed every 30s)
# TYPE occam_snapshots_total gauge
occam_snapshots_total 4
```

## 22. Stubs — 501 shape (clients can probe capability)
```bash
curl -si "http://127.0.0.1:29998/file/frozen-regions?path=$REPO/src/db.py"
```
```
HTTP/1.1 501 Not Implemented
Content-Type: application/json

{"path":"/file/frozen-regions","reason":"needs frozen-region contract design (inline markers vs .occam-frozen.yml)","status":"not_implemented"}
```

---

## 23. MCP — same data, stdio JSON-RPC 2.0

Every endpoint above is also an MCP tool (20 total). Hand-shake +
`tools/list` + a real tool call:

```bash
printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","clientInfo":{"name":"demo","version":"1"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"occam_symbol","arguments":{"path":"/abs/repo/src/db.py","name":"get_conn"}}}' \
| OCCAM_API_URL="http://127.0.0.1:29998" \
  ENGINE_SCRIPT="$PWD/telemetry_observer.sh" \
  OCCAM_DB="/tmp/demo_snap_v020.db" \
  occam-mcp \
| jq -c .
```

Actual output (one JSON-RPC envelope per line, compacted):

```
{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"tools":{"listChanged":false}},"instructions":"Call occam_analyze with an absolute repo path to get structured telemetry. Use occam_check for gate-style pass/fail. occam_trend returns historical snapshots from SQLite.","protocolVersion":"2024-11-05","serverInfo":{"name":"occam-observer-mcp","version":"0.2.0"}}}
{"id":2,"result":{"tools_count":20,"sample":["occam_analyze","occam_check","occam_trend"]}}
{"id":3,"isError":false,"parsed_content":{"name":"get_conn","kind":"function","signature":"def get_conn(db: Optional[str]=None) -> sqlite3.Connection","lineno":9,"callers":[],"callees":[{"name":"sqlite3.connect"},{"name":"os.environ.get"}]}}
```

## 24. Error shapes — consistent JSON envelope

### Bad path (flag-like)
```bash
curl -si "http://127.0.0.1:29998/analyze?path=--evil"
```
```
HTTP/1.1 400 Bad Request
Content-Type: application/json

{"error":"path must not start with '-'"}
```

### Nonexistent path
```bash
curl -si "http://127.0.0.1:29998/analyze?path=/does/not/exist"
```
```
HTTP/1.1 400 Bad Request
Content-Type: application/json

{"error":"path does not exist"}
```

### Non-git target on a coordination endpoint
```bash
curl -si "http://127.0.0.1:29998/repo/context?target=/tmp"
```
```
HTTP/1.1 400 Bad Request
Content-Type: application/json

{"details":"/tmp","error":"target is not a git repository"}
```

---

## Cheat sheet — which endpoint solves which agent problem

| Agent phase   | Question                                   | Endpoint                                    |
|---------------|--------------------------------------------|---------------------------------------------|
| PLANNER       | "what is this repo made of?"               | `GET /repo/context`                         |
| PLANNER       | "is this file a churn hotspot?"            | `GET /repo/churn/:path`                     |
| PLANNER       | "who last touched this line?"              | `GET /repo/blame/:path`                     |
| PLANNER       | "what have we tried recently?"             | `GET /repo/agent-log?since=24h`             |
| WORKER        | "what does this symbol's contract say?"    | `GET /symbol?path=&name=`                   |
| WORKER        | "what public names am I about to break?"   | `GET /file/exports?path=`                   |
| WORKER        | "what does this file import?"              | `GET /file/imports?path=`                   |
| WORKER        | "is anyone else editing this file?"        | `POST /claim` → 200 or 409                  |
| REFINER       | "what actually changed between revs?"      | `GET /diff?base=&branch=`                   |
| REFINER       | "who authored this commit?"                | `GET /agent/identity/:commit`               |
| CROSS-CUTTING | "has this file changed semantically?"      | `GET /file/fingerprint?path=`               |
| CROSS-CUTTING | "what is this file's surface area?"        | `GET /contract?path=`                       |
| CROSS-CUTTING | "close the loop — here's what I did"       | `POST /observation`                         |
| OPERATIONS    | "is the service healthy?"                  | `GET /healthz` · `/readyz` · `/metrics`     |

All 19 endpoints are also MCP tools — same args, same JSON shape, wrapped in
an MCP `content[0].text` block. Point your MCP-capable client at `occam-mcp`
with `ENGINE_SCRIPT`, `OCCAM_DB`, and `OCCAM_API_URL` in its env.
