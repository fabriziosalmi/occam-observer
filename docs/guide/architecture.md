# Architecture

Occam Observer is a small constellation of local processes that share one
JSON contract. Everything runs on the same host — no network hop, no cloud
dependency, no daemon you don't see.

## Component map

```
┌────────────────────────────────────────────────────────────────────────┐
│                                                                        │
│   ┌────────────────────────────┐                                       │
│   │  telemetry_observer.sh     │   bash + awk · set -euo pipefail       │
│   │                            │                                       │
│   │  --json        one-shot    │                                       │
│   │  --check       gate mode   │                                       │
│   │  --watch       headless    │───▶ fswatch / inotifywait             │
│   │  --validate    config      │                                       │
│   │   (default)    TUI         │                                       │
│   │                            │                                       │
│   │   render_dashboard ────────┼──▶ extract_violations + blame_line    │
│   │                            │──▶ run_analyzers → analyzers/*        │
│   │   write_cache ─────────────┼──▶ /tmp/occam_state.json (mv-atomic)  │
│   │   persist_snapshot ────────┼──▶ $XDG_DATA_HOME/…/snapshots.db      │
│   └────────────────────────────┘                                       │
│                  ▲                                                     │
│                  │  reads CACHE_FILE                                   │
│                  │  spawns engine for /analyze                         │
│   ┌──────────────┴─────────────┐       ┌──────────────────────────┐    │
│   │  api/  (Go HTTP gateway)   │       │  mcp/  (Go stdio server) │    │
│   │  127.0.0.1:9999            │       │  JSON-RPC 2.0            │    │
│   │                            │       │  MCP 2024-11-05          │    │
│   │  /  /analyze  /trend       │       │                          │    │
│   │  /healthz /readyz /metrics │       │  occam_analyze, check,   │    │
│   │  /repo/* /file/* /symbol   │       │  trend, repo/*, file/*,  │    │
│   │  /claim /observation       │ HTTP  │  symbol, claim, …        │    │
│   │  /agent/identity/:commit   │◀──────┤  (HTTP-proxied to gw     │    │
│   │  /diff  /contract          │       │   for coordination tools)│    │
│   │                            │       │                          │    │
│   │  initCoordinationDB() ─────┼──▶ observations + claims tables  │    │
│   │  startBackgroundMetrics()  │                                  │    │
│   │  /ui/*  → api/public/      │                                  │    │
│   └────────────────────────────┘       └──────────────────────────┘    │
│                  ▲                                 ▲                   │
│                  │ HTTP + X-Trace-Id               │ stdio + env       │
│                  │                                 │                   │
└──────────────────┼─────────────────────────────────┼───────────────────┘
                   │                                 │
           React dashboard · curl · CI    Claude Desktop · Cursor ·
                                          Windsurf · VS Code · Zed ·
                                          Continue

   ┌──────────────────────────────────────────────┐
   │  ./occam   (bash wrapper, single entry point)│  spawns gateway,
   │  start · stop · status · analyze · check ·   │  watcher, and
   │  logs · ui · mcp · doctor · clean · test     │  tracks their PIDs
   └──────────────────────────────────────────────┘
```

Three long-lived processes are possible, and independent:

1. **Go gateway** — always needed when anyone hits `/` or the coordination
   API. `./occam start` builds + spawns it; PID in
   `$XDG_RUNTIME_DIR/occam-gateway.pid`.
2. **Headless watcher** — `./occam start /path/to/repo` also spawns
   `telemetry_observer.sh --watch PATH` in the background, so the cache
   file stays live as you edit. PID in `occam-watcher.pid`. Optional.
3. **MCP server** — spawned as a subprocess by the MCP client (Claude
   Desktop, Cursor, …), not by `./occam`. Lives as long as the client
   session. Proxies coordination tools back to the gateway.

Short-lived workers fill in the rest: the engine running in `--json` or
`--check` mode, analyzer executables (Semgrep, Python AST, python symbol
indexer), `sqlite3` invocations for TSDB queries.

## Data flow

1. **Trigger** — either a file-save event on the watched repo, or an HTTP
   request (`/analyze`, `/symbol`, `/file/*`, etc.), or an MCP tool call.
2. **Engine invocation** — the bash engine is driven either by its own
   watcher loop (`--watch`) or forked from the Go gateway on demand. The
   choice of `git diff` mode (`HEAD` / `--cached` / working tree) is
   fixed by the CLI flag or query param.
3. **Metric computation** — security (regex), mass (`git diff --shortstat`),
   entropy (lexical stripper + branch-keyword count), test coverage, debt;
   plus the intelligence block (infra / schema / network / signatures /
   dependencies / syntax).
4. **Violation extraction** — pure-bash state machine maps each matched
   added line to `(kind, file, new_line, text)` and blames it via
   `git blame --porcelain -L N,N`.
5. **Analyzer fan-out** — every executable in `analyzers/` is invoked with
   the unified diff on stdin, bounded by `OCCAM_ANALYZER_TIMEOUT`
   (default 30 s), results merged.
6. **Severity derivation** — `check.level` is computed per-request from
   the metric vector and escalated by analyzer findings. Never cached
   across runs.
7. **Write-through cache** — `mktemp` + `umask 0077` + atomic `mv`. No
   TOCTOU window between creation and chmod.
8. **Persistence** — row appended to SQLite (WAL). The gateway's metrics
   gauge is nudged so `/metrics` shows the new count without a sqlite3
   fork per scrape.
9. **Exposition** — `GET /` serves the cache file verbatim;
   `GET /analyze` returns the engine's fresh stdout; `GET /trend` reads
   the TSDB via `sqlite3 -json`; coordination endpoints shell out to the
   python symbol indexer for AST queries.

## Invariants

- **JSON correctness is non-negotiable.** Every engine-emitted string goes
  through `json_escape_str` (RFC 8259 — backslash, quote, `\b\f\n\r\t`,
  plus C0 control strip). Agent consumers must be able to parse every
  payload unconditionally.
- **No agents blocked by missing deps.** `jq`, `sqlite3`, `semgrep`,
  `python3`, `fswatch`/`inotifywait` are each probed at use-site; absence
  turns the corresponding feature off with a one-line warn log but never
  aborts the pipeline.
- **Trace correlation.** `X-Trace-Id` (or a freshly generated 16-hex id)
  is set by the Go middleware, forwarded as `OCCAM_TRACE_ID` to the
  engine, embedded in `.trace_id` in the JSON payload, and tagged on every
  `log_json` event on stderr.
- **Severity is derived, not stored.** `check.level` and `check.reasons`
  are computed fresh on each analysis. TSDB rows carry the level that was
  current at the time of the snapshot.
- **`is_idle` matches its name.** `true` means the chosen `diff_mode`
  yielded empty content (the clean-tree case). Clients branch on it for
  empty-state UI.
- **Same-origin by default.** The gateway binds `127.0.0.1`. No
  `Access-Control-Allow-Origin: *` on data endpoints — cross-origin
  browser reads are not supported by design.

## File layout

```
telemetry_observer.sh             # bash engine (TUI + --json + --check + --watch)
occam                             # convenience CLI
api/
  go.mod
  main.go                         # Go HTTP gateway (registers handlers,
                                  # middleware, startBackgroundMetrics)
  coordination.go                 # /repo/* /file/* /symbol /claim /observation
                                  # /agent/identity /diff /contract + stubs
  public/                         # built React bundle (mounted at /ui/)
mcp/
  go.mod
  main.go                         # stdio MCP server with 20 tools
web/
  src/App.tsx                     # dashboard source
  …vite config…
analyzers/
  semgrep.sh                      # wrapper for Semgrep rule packs
  python-ast.py                   # stdlib AST analyzer (taint sinks,
                                  # cyclomatic, pickle, subprocess shell=True)
  python-symbol-index.py          # imports/exports/symbol/ast_hash backend
config/
  main.yml                        # thresholds, target_path, api_port
  schema.json                     # constraint contract for --validate
  rules/*.yml                     # regex patterns (security, debt, entropy,
                                  # tests)
hooks/
  pre-commit                      # advisory → OCCAM_HOOK_FAIL_ON=LEVEL gates
tests/                            # bash regression suites run by run_tests.sh
                                  # (test_json, test_analyzers, test_check_cli,
                                  #  test_coordination, test_mcp, test_selfobs,
                                  #  test_trend_api, test_cli)
run_tests.sh                      # unified runner + go vet + bash -n
scripts/
  build-ui.sh                     # web/ → api/public/ production build
Dockerfile                        # API-only runtime (Alpine + coreutils)
.github/workflows/
  tests.yml                       # CI: syntax, vet, build, full suite
  deploy-docs.yml                 # VitePress → GitHub Pages
docs/                             # VitePress site — this very page
```
