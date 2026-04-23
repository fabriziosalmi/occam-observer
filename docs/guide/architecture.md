# Architecture

Occam Observer is two cooperating processes plus optional analyzer
subprocesses. Everything runs locally on the same node — no network hop
between components.

## Components

```
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│   ┌────────────────────────┐                                     │
│   │ telemetry_observer.sh  │   bash + awk · set -euo pipefail    │
│   │                        │                                     │
│   │   load_config          │                                     │
│   │   validate_target      │                                     │
│   │   render_dashboard ────┼──▶ extract_violations + blame_line  │
│   │                        │                                     │
│   │                        │──▶ run_analyzers ──▶ analyzers/*    │
│   │                        │                       (timeout'd)   │
│   │                        │                                     │
│   │   write_cache ─────────┼──▶ /tmp/occam_state.json (mv-atomic)│
│   │   persist_snapshot ────┼──▶ sqlite3 ~/.../snapshots.db (WAL) │
│   └────────────┬───────────┘                                     │
│                │                                                  │
│                │ spawns                                           │
│                ▼                                                  │
│   ┌────────────────────────┐                                     │
│   │ api/main.go            │   Go net/http · bind 127.0.0.1      │
│   │                        │                                     │
│   │   withTraceID middleware                                     │
│   │   handleRoot    →  reads CACHE_FILE                          │
│   │   handleAnalyze →  forks telemetry_observer.sh --json        │
│   │   handleTrend   →  exec sqlite3 -json -readonly              │
│   │   handleHealthz │ handleReadyz │ handleMetrics               │
│   │   /ui/*         →  static React bundle (api/public/)         │
│   └────────────────────────┘                                     │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘

       ▲                                    ▲
       │ HTTP                               │ HTTP
       │                                    │
  React dashboard                    Agents · curl · CI
```

## Data flow

1. **Event**: a file save (fswatch / inotifywait) or an HTTP request to
   `/analyze`.
2. **Collect**: the bash engine runs the selected `git diff` mode
   (`HEAD` / `--cached` / working tree) and extracts text, file names, hunks.
3. **Compute metrics**: security (regex), mass (shortstat), entropy
   (sanitized lexical match), test coverage, debt, plus the intelligence
   block (infra, schema, network, signatures, dependencies, syntax).
4. **Parse violations**: per-hunk pure-bash state machine maps each matched
   added line to `(kind, file, new_line_number, text)` and blames it via
   `git blame --porcelain -L N,N`.
5. **Run analyzers**: every executable in `analyzers/` is invoked in
   parallel-with-timeout, fed the diff on stdin, emits a findings object.
   Findings at `critical`/`high`/`medium`/`low` severity escalate
   `.check.level`.
6. **Write-through cache**: `mktemp` + `mv` atomic swap, `chmod 0600` so
   `/tmp`'s world-readable directory doesn't leak snippets.
7. **Persist**: a row is appended to the SQLite TSDB with WAL mode enabled.
8. **Expose**: the Go gateway serves `GET /` as an `O(1)` file read and
   `GET /trend` as a read-only SQL query. `GET /analyze` re-triggers step 2.

## Invariants

- **JSON correctness** is mandatory. Every engine-emitted string goes through
  `json_escape_str` (RFC 8259 — quote, backslash, `\b\f\n\r\t`, plus C0
  control strip). Agent consumers must be able to parse every payload
  unconditionally.
- **No agents blocked by missing deps**. `jq`/`sqlite3`/`semgrep`/`python3`
  are each probed; absence turns the corresponding feature off with a log
  line but never crashes the pipeline.
- **Trace correlation**. `X-Trace-Id` (or a freshly generated 16-hex id) is
  set by the Go middleware, forwarded as `OCCAM_TRACE_ID` to the engine,
  embedded in `.trace_id` and in every `log_json` event.
- **Severity is derived, not stored**. The `.check.level` and `.check.reasons`
  are computed fresh on each analysis from the current metric vector plus
  analyzer findings — never cached across runs.

## File layout

```
telemetry_observer.sh           # bash engine
api/
  main.go                       # Go HTTP gateway
  go.mod
  public/                       # compiled React bundle (mounted at /ui/)
web/
  src/App.tsx                   # dashboard source
  …vite config…
analyzers/
  semgrep.sh                    # adapter for p/auto or OCCAM_SEMGREP_CONFIG
  python-ast.py                 # stdlib ast walker, POC replacement for regex entropy
config/
  main.yml                      # thresholds, target_path, api_port
  schema.json                   # documented constraint shape
  rules/*.yml                   # regex patterns for security / debt / entropy
hooks/
  pre-commit                    # advisory (or OCCAM_HOOK_FAIL_ON=high to block)
tests/                          # bash regression suites run by run_tests.sh
test_json.sh                    # pathological JSON escape coverage
run_tests.sh                    # unified runner
Dockerfile                      # API-only runtime image
```
