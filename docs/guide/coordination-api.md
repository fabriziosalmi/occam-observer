# Coordination API

Endpoints built to serve multi-agent coding systems (planners, workers,
refiners) that need a single source of truth for repo context, code
structure, and agent activity. Born out of real needs from `gitoma` and
similar autonomous-coder projects.

All endpoints live on the same Go gateway as the telemetry API
(`127.0.0.1:9999` by default) and are equally available through the MCP
server. Contracts below are normative: the shape is stable, fields may be
added but not removed or renamed without a `version` bump.

## Status legend

- **ready** — shipped and covered by a smoke test
- **partial** — shipped; a specific field is best-effort and documented below
- **stub** — endpoint exists, returns `{"status":"not_implemented","reason":"..."}`
  with HTTP 501 so clients can probe capability without errors

## PLANNER (phase 2, one-shot)

### `GET /repo/context?target=<abs>` — ready

Structural snapshot of a repo. Cheap to compute; safe to call every planning
round.

```json
{
  "target": "/abs/repo",
  "languages": [
    {"name": "Python",     "files": 42, "bytes": 180321},
    {"name": "TypeScript", "files": 18, "bytes":  62110}
  ],
  "stack": ["python/poetry", "npm"],
  "recent_churn": {
    "since_days": 7,
    "insertions": 1243,
    "deletions":  312,
    "files_touched": 17
  },
  "hot_files":    [{"path": "src/db.py", "changes": 12}],
  "stable_files": [{"path": "LICENSE",   "last_touched": "2024-11-12"}]
}
```

Stack detection rules (first match wins, multiple stacks possible):
`pyproject.toml` → `python/poetry` or `python/hatch`; `requirements*.txt` →
`python/pip`; `go.mod` → `go`; `package.json` → `npm`; `Cargo.toml` →
`rust/cargo`; `Dockerfile` → adds `docker`; `docker-compose.yml` → adds
`docker-compose`; any `.github/workflows/*` → adds `github-actions`.

### `GET /repo/blame/:path?target=<abs>` — ready

Per-line blame with revert detection.

```json
[
  {
    "line":   42,
    "commit": "a1b2c3d",
    "author": "alice@example.com",
    "agent":  "gitoma",
    "run_id": "run-42",
    "when":   "2026-04-22T10:00:00Z",
    "reverted_by": "d4e5f6a"
  }
]
```

- `agent` and `run_id` come from the `observations` table joined on `commit_sha`.
  Null when the commit was not recorded by any MCP agent.
- `reverted_by` is populated when a later commit message matches `^Revert ` and
  its diff inverts the blamed commit. Best-effort — not a guarantee.

### `GET /repo/agent-log?since=24h&limit=100` — ready

Append-only event log of agent activity. Backed by the `observations` table;
written via `POST /observation`.

```json
[
  {
    "id":            187,
    "ts":            "2026-04-23T14:00:00Z",
    "run_id":        "gitoma-run-42",
    "agent":         "gitoma",
    "subtask_id":    "sub-3",
    "model":         "claude-opus-4.7",
    "branch":        "feat/refactor-db",
    "commit_sha":    "a1b2c3d",
    "outcome":       "success",
    "touched_files": ["src/db.py", "tests/test_db.py"],
    "failure_modes": []
  }
]
```

`since` accepts a duration (`24h`, `7d`, `30m`) or an ISO-8601 lower bound on
`ts`. Limit capped at 1000.

### `GET /repo/test-map?target=<abs>` — stub (501)

Would return a forward + inverse mapping between test files and the source
they exercise. Deferred until a test-runner wrapper contract is agreed
(per-language). Current response:

```json
{"status": "not_implemented", "reason": "needs test-runner integration (pytest/jest/go test)"}
```

### `GET /repo/failing-tests?target=<abs>` — stub (501)

Same reason. Needs a way to ingest the last known test state — planned to
hang off a new `test_runs` table written by a future `analyzers/pytest.sh`
or similar adapter.

## WORKER (phase 3, per-subtask)

### `GET /symbol?path=<abs>&name=<symbol>` — partial (Python v1)

Returns structured info about a symbol defined in the given file.

```json
{
  "name":      "get_conn",
  "kind":      "function",
  "signature": "def get_conn(db: str = 'app.db') -> sqlite3.Connection",
  "lineno":    12,
  "callers":   [{"file": "src/db.py", "line": 48}],
  "callees":   [{"name": "sqlite3.connect"}],
  "test_coverage": []
}
```

- **v1 scope:** Python only, via `analyzers/python-symbol-index.py` (stdlib
  `ast`). `callers`/`callees` are **in-file only** (cross-file symbol index
  deferred — needs a repo-wide AST cache with invalidation).
- `test_coverage` is always `[]` until test integration ships.

### `GET /file/imports?path=<abs>` — ready (Python)

```json
[
  {"module": "sqlite3", "symbol_imported": null, "line": 1},
  {"module": "typing",  "symbol_imported": "Optional", "line": 2}
]
```

Non-Python files return an empty array with `language: "other"` in the
response envelope.

### `GET /file/exports?path=<abs>` — ready (Python)

Top-level public definitions (name does not start with `_`).

```json
[
  {"name": "get_conn", "kind": "function", "lineno": 12, "public": true},
  {"name": "Schema",   "kind": "class",    "lineno": 34, "public": true}
]
```

### `GET /file/frozen-regions?path=<abs>` — stub (501)

Needs a contract. Two options under consideration:

1. Inline comment markers: `# occam:frozen` / `# occam:end-frozen`
2. External `.occam-frozen.yml` with `{file, start_line, end_line, reason}` entries

Current response:

```json
{"status": "not_implemented", "reason": "needs frozen-region contract design (inline markers vs .occam-frozen.yml)"}
```

### `GET /file/last-safe?path=<abs>` — stub (501)

"Last commit at which this file's tests passed". Requires the test-runs
table; 501 for now.

### `POST /claim` — ready

Optimistic file lock for coordinated workers.

```http
POST /claim
Content-Type: application/json

{
  "path":         "/abs/path/to/file.py",
  "agent":        "gitoma",
  "run_id":       "run-42",
  "ttl_seconds":  600
}
```

Success (claim granted):

```json
{"lock_id": "c8a1e4f2-…", "expires_at": "2026-04-23T14:10:00Z"}
```

Conflict (409 — already claimed):

```json
{"error": "already_claimed", "held_by": {"agent": "other", "run_id": "run-41", "expires_at": "..."}}
```

Claims expire lazily (on next `POST /claim` or `GET /claim`). `ttl_seconds`
is clamped to `[30, 3600]`.

### `DELETE /claim?lock_id=<id>` — ready

Releases the claim. Idempotent: returns `{"released": true}` whether the
lock existed or not (protects against double-release on retries).

### `GET /claim?path=<abs>` (single) or `GET /claim` (all active) — ready

Introspection.

## REFINER / CRITICS (phase 3.5)

### `GET /diff?target=<abs>&base=<rev>&branch=<rev>` — partial

```json
{
  "touched_files": ["src/db.py", "tests/test_db.py"],
  "ast_top_level_delta": {
    "added":    [{"file": "src/db.py", "name": "init_schema", "kind": "function"}],
    "removed":  [],
    "modified": [{"file": "src/db.py", "name": "get_conn",   "kind": "function"}]
  },
  "tests_delta": {"status": "not_implemented"}
}
```

`ast_top_level_delta` is Python-only v1. `tests_delta` stubbed until test
integration.

### `GET /run/:id/tests/delta` — stub (501)
### `GET /scorecard/:run_id` — stub (501)

Both depend on test-runs; same reason as above.

## CROSS-CUTTING

### `GET /agent/identity/:commit` — ready

Lookup an agent event by commit SHA.

```json
{
  "agent":      "gitoma",
  "run_id":     "run-42",
  "subtask_id": "sub-3",
  "model":      "claude-opus-4.7",
  "confidence": 0.78,
  "ts":         "2026-04-23T14:00:00Z"
}
```

404 when no observation with that SHA is recorded.

### `GET /file/fingerprint?path=<abs>` — partial

```json
{
  "path":            "src/db.py",
  "sha":             "git-index-sha",
  "content_hash":    "sha256:…",
  "ast_hash":        "sha256:…",
  "test_coverage_hash": null
}
```

- `sha` is the blob SHA in the git index (`git ls-files -s`); null if untracked.
- `content_hash` is sha256 of on-disk bytes.
- `ast_hash` is sha256 of a whitespace-insensitive AST dump (Python only).
  Two files with identical structure but different indentation have the same
  `ast_hash`.
- `test_coverage_hash` always null v1.

### `GET /repo/churn/:path?target=<abs>&since=30d` — ready

```json
{
  "modifications": 14,
  "reverts":        2,
  "contributors":  ["alice@x", "gitoma-bot@x"]
}
```

Revert heuristic: commit message matching `^Revert ` OR containing `revert`
adjacent to the commit SHA being reverted.

### `GET /contract?path=<abs>` — partial

```json
{
  "public_api":     [{"name": "get_conn", "kind": "function"}],
  "test_coverage":  0.0,
  "coupling_score": 0
}
```

- `public_api` is sourced from `/file/exports` (Python).
- `test_coverage` and `coupling_score` always 0 v1 until test integration +
  cross-file symbol index exist.

### `POST /observation` — ready

Append-only log entry. Agents call this at the end of a run / subtask.

```http
POST /observation
Content-Type: application/json

{
  "run_id":        "gitoma-run-42",
  "agent":         "gitoma",
  "subtask_id":    "sub-3",
  "model":         "claude-opus-4.7",
  "branch":        "feat/refactor-db",
  "commit_sha":    "a1b2c3d",
  "outcome":       "success",
  "touched_files": ["src/db.py"],
  "failure_modes": [],
  "confidence":    0.78,
  "extra":         {"anything": "else"}
}
```

Response: `{"id": 187, "ts": "2026-04-23T14:00:00Z"}`. Only `run_id`,
`agent`, and `outcome` are required.

## MCP tool mapping

Each endpoint above is also exposed as an MCP tool so agents can call it
without HTTP. See [MCP guide](./mcp) for the full tool list. Naming
convention: `occam_<endpoint_noun>` — for example `/repo/context` → tool
`occam_repo_context`, `POST /observation` → `occam_observation`.

## Stability & versioning

The response `version` field in `/analyze` tracks the engine; the
coordination API is currently pinned to the same version. Breaking changes
to any "ready" endpoint will bump the major version.
