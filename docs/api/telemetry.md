# REST API Reference

Occam Observer exposes a single HTTP gateway (Go) that agents can drive
without ever touching the bash engine directly. Default bind:
`127.0.0.1:9999`. Override via `API_PORT`.

Every `/`, `/analyze`, `/trend` request accepts an `X-Trace-Id` request
header — if you don't send one, the server generates a 16-hex-char id. The
same id is:

- echoed in the `X-Trace-Id` response header,
- forwarded to the engine as `OCCAM_TRACE_ID` (appears in every engine
  stderr log line as the `trace_id` field),
- embedded into the JSON payload (`.trace_id`) so agents can persist it.

## Endpoints

### Telemetry & observability

| Method | Path              | Purpose                                                |
|--------|-------------------|---------------------------------------------------------|
| GET    | `/`               | last cached snapshot (O(1) file read)                  |
| GET    | `/analyze`        | run the engine on demand against a local path          |
| GET    | `/trend`          | query the SQLite time-series store                     |
| GET    | `/healthz`        | liveness probe                                         |
| GET    | `/readyz`         | readiness probe                                        |
| GET    | `/metrics`        | Prometheus text exposition                             |
| GET    | `/ui/…`           | React dashboard static assets                          |

### Coordination API (multi-agent)

Documented separately — contracts, shapes, and stubs in
[Coordination API](../guide/coordination-api). Summary:

| Method       | Path                          | Status     |
|--------------|-------------------------------|------------|
| GET          | `/repo/context`               | ready      |
| GET          | `/repo/blame/:path`           | ready      |
| GET          | `/repo/churn/:path`           | ready      |
| GET          | `/repo/agent-log`             | ready      |
| GET          | `/diff`                       | ready      |
| GET          | `/file/fingerprint`           | ready      |
| GET          | `/file/imports`               | ready (py) |
| GET          | `/file/exports`               | ready (py) |
| GET          | `/symbol`                     | ready (py) |
| GET          | `/agent/identity/:commit`     | ready      |
| GET          | `/contract`                   | partial    |
| POST         | `/observation`                | ready      |
| GET/POST/DELETE | `/claim`                   | ready      |
| GET          | `/repo/test-map`              | stub (501) |
| GET          | `/repo/failing-tests`         | stub (501) |
| GET          | `/file/frozen-regions`        | stub (501) |
| GET          | `/file/last-safe`             | stub (501) |
| GET          | `/run/:id/tests/delta`        | stub (501) |
| GET          | `/scorecard/:run_id`          | stub (501) |

---

## `GET /`

Returns the most recent snapshot from `$CACHE_FILE` (default
`/tmp/occam_state.json`). If the cache has not been written yet:

```
HTTP/1.1 503 Service Unavailable
Content-Type: application/json

{"error": "cache not ready or observer not running"}
```

### Response schema (200 OK)

```json
{
  "version": "0.2.1",
  "trace_id": "b3c4d5e6f7a8b9c0",
  "timestamp": "2026-04-23T14:05:12+0200",
  "branch": "main",
  "commit": "a1b2c3d",
  "target": "/absolute/path/to/repo",
  "diff_mode": "head",
  "is_idle": false,

  "metrics": {
    "security_violations": 1,
    "mass_insertions": 42,
    "mass_deletions": 7,
    "mass_files_changed": 3,
    "entropy_nodes": 8,
    "test_files_modified": 1,
    "debt_issues": 2
  },

  "snippets": {
    "security": "API_KEY = \"…\"",
    "debt":     "# TODO: refactor"
  },

  "git": {
    "author":   "Alice Example <alice@example.com>",
    "message":  "wip: refactor auth flow",
    "time":     "2026-04-23T13:55:01+02:00",
    "remote":   "git@github.com:org/repo.git",
    "is_dirty": true
  },

  "intelligence": {
    "file_types": {
      "logic":  ["src/auth.py"],
      "config": [],
      "docs":   [],
      "media":  []
    },
    "infrastructure_changes": [],
    "schema_mutations":       [],
    "network_outbound":       [],
    "signatures_added":       ["def verify_token(...)"],
    "dependencies_added":     ["from jwt import decode"],
    "syntax_valid":           ["src/auth.py"],
    "syntax_invalid":         [],

    "violations": [
      {
        "kind":    "security",
        "file":    "src/auth.py",
        "line":    12,
        "text":    "API_KEY = \"sk-…\"",
        "blame": {
          "commit":      "uncommitted",
          "author":      "",
          "author_time": ""
        }
      }
    ],

    "analyzers": [
      {
        "name":    "python-ast",
        "version": "0.1.0",
        "findings": [
          {
            "severity": "critical",
            "kind":     "security",
            "rule_id":  "python-ast/eval-usage",
            "file":     "src/auth.py",
            "line":     33,
            "message":  "use of eval() — code-injection sink",
            "text":     "eval(...)"
          }
        ]
      }
    ]
  },

  "health_score": 45,

  "check": {
    "level":   "critical",
    "reasons": ["security_violations=1", "analyzer_critical=1"]
  },

  "performance": {
    "engine_duration_ms": 312,
    "diff_bytes":         4096,
    "analyzers_run":      ["python-ast", "semgrep"]
  },

  "thresholds": {
    "mass_warn":        150,
    "mass_critical":    300,
    "entropy_warn":     5,
    "entropy_critical": 10
  }
}
```

### Field notes

- **`is_idle`** — `true` when the chosen `diff_mode` yields no content (the
  clean-tree case). `false` when the engine actually had something to
  analyze. Clients that hide the dashboard's intelligence panel should
  branch on this; clients that treat the presence of metrics as the signal
  should instead check `metrics.mass_files_changed > 0`.
- **`trace_id`** — empty string if the engine was invoked directly (no HTTP).
- **`diff_mode`** — `head` \| `staged` \| `working`, matches the engine flag.
- **`violations[].blame.commit`** — short hash (12 chars) or the literal
  string `uncommitted` when the line has never been committed (new file or
  fresh addition by the current user).
- **`analyzers[]`** — one entry per executable in `analyzers/`. Missing
  dependencies surface as `"skipped": "<reason>"` instead of findings, so
  callers never need to special-case a missing tool.
- **`check.level`** — `none` \| `low` \| `medium` \| `high` \| `critical`.
  Derived from diff metrics and then escalated by analyzer findings.
- **`performance.engine_duration_ms`** — wall-clock time of the engine run;
  second-precision only on `bash < 5.0`.

---

## `GET /analyze`

Runs the engine synchronously against a local path and returns the same JSON
shape as `/`. Triggers a TSDB append on success.

### Query parameters

| Name    | Required | Notes                                                         |
|---------|----------|---------------------------------------------------------------|
| `path`  | yes      | absolute path, must be an existing directory, must not start with `-` |

### Validation errors

```
HTTP/1.1 400 Bad Request
{"error": "missing 'path' query parameter"}
{"error": "path must not start with '-'"}
{"error": "path does not exist"}
{"error": "path is not a directory"}
```

### Engine errors

Status `500` with either:

- the engine's own JSON payload (when it emitted valid JSON despite exit ≠ 0), or
- `{"error": "engine failed", "details": "<stderr summary>"}`.

### Example

```bash
curl -sH "X-Trace-Id: my-req-0001" \
     "http://127.0.0.1:9999/analyze?path=/abs/path/to/repo" | jq .check
```

---

## `GET /trend`

Queries the SQLite TSDB populated by the engine after every analysis.

### Query parameters

| Name     | Required | Default | Notes                                           |
|----------|----------|---------|-------------------------------------------------|
| `target` | no       | — (any) | filter by the `target` column (full path match)|
| `limit`  | no       | 100     | `1..1000`; 400 on anything outside              |
| `since`  | no       | —       | ISO-8601 lower bound on `ts`                    |

### Response (200 OK)

JSON array, newest first:

```json
[
  {
    "id": 42,
    "ts": "2026-04-23T14:05:12+0200",
    "target": "/abs/path/to/repo",
    "branch": "main",
    "commit_sha": "a1b2c3d",
    "health_score": 45,
    "security_violations": 1,
    "mass_insertions": 42,
    "mass_deletions": 7,
    "mass_files_changed": 3,
    "entropy_nodes": 8,
    "test_files_modified": 1,
    "debt_issues": 2,
    "check_level": "critical",
    "diff_mode": "head"
  }
]
```

### Failure modes

- `503 Service Unavailable` — DB file absent (no analyses recorded yet).
- `500 Internal Server Error` — `sqlite3` CLI missing, or query timeout.

### Example

```bash
curl -s "http://127.0.0.1:9999/trend?target=/abs/repo&limit=20" | jq '.[].check_level'
```

---

## `GET /healthz`

Cheap liveness probe. Never hits disk, never 503s unless the process is
down. Intended for container-level supervision.

```json
{"status": "ok", "uptime_seconds": 123.4}
```

---

## `GET /readyz`

Readiness: returns `200 {"status":"ready"}` iff the engine script is
locatable **and** at least one of the cache file or the TSDB exists.
Otherwise `503 {"status":"not_ready","gaps":[…]}` with the specific
missing resources enumerated.

---

## `GET /metrics`

Prometheus text format (version 0.0.4). All counters are reset on process
restart; the TSDB row count is a gauge queried per request.

```
# HELP occam_up 1 if the API process is up
# TYPE occam_up gauge
occam_up 1
# HELP occam_uptime_seconds Seconds since process start
# TYPE occam_uptime_seconds gauge
occam_uptime_seconds 42.1
# HELP occam_analyses_total Number of /analyze requests handled, by outcome
# TYPE occam_analyses_total counter
occam_analyses_total{result="ok"}    18
occam_analyses_total{result="error"}  2
# HELP occam_analyze_duration_seconds Summary of /analyze wall time
# TYPE occam_analyze_duration_seconds summary
occam_analyze_duration_seconds_count 20
occam_analyze_duration_seconds_sum   6.438912
# HELP occam_trend_requests_total Number of /trend requests handled, by outcome
# TYPE occam_trend_requests_total counter
occam_trend_requests_total{result="ok"}    7
occam_trend_requests_total{result="error"} 0
# HELP occam_cache_age_seconds Age of the write-through JSON cache (-1 if absent)
# TYPE occam_cache_age_seconds gauge
occam_cache_age_seconds 2.314
# HELP occam_snapshots_total Rows in the TSDB
# TYPE occam_snapshots_total gauge
occam_snapshots_total 20
```

---

## Headless engine mode (no HTTP)

The engine is useful without the gateway too. It prints the exact same JSON
payload as `GET /`:

```bash
./telemetry_observer.sh --json /abs/repo          # staged + unstaged
./telemetry_observer.sh --json --staged /abs/repo # index only
./telemetry_observer.sh --check --fail-on=high --staged /abs/repo
```

Exit codes:

| Code | Meaning                                                       |
|------|----------------------------------------------------------------|
| 0    | success or `--check` severity below threshold                 |
| 1    | `--check` severity meets/exceeds `--fail-on`                  |
| 2    | engine runtime error                                          |
| 3    | bad CLI arguments / invalid config                            |
