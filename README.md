# Occam Observer

**v0.2.0** · [Changelog](#changelog)

> *Out-of-band, agent-friendly Git telemetry.*

Occam Observer watches a Git repository from the outside and turns every save
into structured telemetry: a health score, a severity-graded `check` verdict,
line-level violations with `git blame` provenance, and findings from
pluggable analyzers (Semgrep, AST, …). It ships three ways to consume the
data:

- a **Go HTTP gateway** with `/`, `/analyze`, `/trend`, `/healthz`, `/readyz`,
  `/metrics` (Prometheus) — for browsers, dashboards, cURL, and anything
  web-native
- an **MCP server** (`occam-mcp`) speaking stdio JSON-RPC 2.0 — for
  Claude Desktop, Cursor, Windsurf, VS Code Copilot, Zed, Continue, and any
  other Model Context Protocol client
- a **React dashboard** served at `/ui/` — for humans

A SQLite WAL time-series store backs the trend view, and every HTTP request
carries an `X-Trace-Id` correlated across the gateway and the bash engine
logs.

```
         ┌─────────────────────────┐
         │ telemetry_observer.sh   │   bash engine: metrics, severity,
         │ (bash + awk + git)      │   blame, analyzer orchestration
         └──┬────────────────┬─────┘
            │                │
            │ write-through  │ append
            ▼                ▼
    /tmp/occam_state.json   ~/.local/share/occam-observer/snapshots.db
            ▲                ▲
            │                │
         ┌──┴────────────────┴─────┐       ┌────────────────────────┐
         │ api/main.go             │       │ mcp/main.go            │
         │ Go HTTP gateway         │       │ stdio JSON-RPC 2.0     │
         │ 127.0.0.1:9999          │       │ MCP 2024-11-05         │
         │ /,/analyze,/trend,      │       │ occam_analyze, check,  │
         │ /healthz,/readyz,       │       │ trend, validate_config │
         │ /metrics                │       │ health                 │
         └──────────┬──────────────┘       └───────────┬────────────┘
                    │                                  │
                    ▼                                  ▼
          curl · React UI                   Claude · Cursor · VS Code
                                            Windsurf · Zed · Continue
```

## Requirements

| Purpose          | Tool                       | Install                                  |
|------------------|----------------------------|------------------------------------------|
| Engine           | `bash` ≥ 3.2, `git` ≥ 2.x  | preinstalled                             |
| JSON handling    | `jq`                       | `brew install jq` / `apt install jq`     |
| File watch (TUI) | `fswatch` (macOS)          | `brew install fswatch`                   |
|                  | `inotifywait` (Linux)      | `apt install inotify-tools`              |
| HTTP gateway     | `go` ≥ 1.21                | `brew install go`                        |
| TSDB (optional)  | `sqlite3`                  | preinstalled on macOS / `apt install sqlite3` |
| Analyzer: AST    | `python3` ≥ 3.8            | preinstalled                             |
| Analyzer: rules  | `semgrep` (optional)       | `pip install semgrep`                    |

All optional dependencies degrade gracefully — missing `sqlite3` disables
persistence, missing `semgrep` makes that analyzer a no-op, missing `fswatch`
only affects the TUI watcher (`--json`/`--check` still work).

## Install

```bash
git clone https://github.com/fabriziosalmi/occam-observer.git
cd occam-observer
chmod +x telemetry_observer.sh analyzers/*
```

## Usage

### Interactive TUI

```bash
./telemetry_observer.sh /absolute/path/to/repo
```

The script reads `config/main.yml` if present (target_path can be set there),
spawns the Go API gateway on `127.0.0.1:9999`, renders the dashboard, and
re-analyzes on every file save (debounced — configurable via
`OCCAM_DEBOUNCE_MS`, default 400).

### Headless JSON (for agents/scripts)

```bash
# one-shot analysis, JSON to stdout
./telemetry_observer.sh --json /path/to/repo

# pipeline gate with exit code
./telemetry_observer.sh --check --fail-on=high --staged /path/to/repo
# exit 0 = below threshold · 1 = at/above threshold · 2 = engine error · 3 = bad args
```

### Diff modes

| Flag           | Revision pair                               |
|----------------|---------------------------------------------|
| *(default)*    | `git diff HEAD` — staged + unstaged         |
| `--staged`     | `git diff --cached` — what `git commit` records |
| `--working`    | `git diff` — unstaged only                  |
| `--diff=MODE`  | explicit: `head` \| `staged` \| `working`   |

### Severity matrix

| Level    | Triggers                                                        |
|----------|------------------------------------------------------------------|
| critical | security violation · syntax-invalid file · analyzer critical    |
| high     | mass > mass_critical · entropy > entropy_critical · infra / schema touched · analyzer high |
| medium   | mass > mass_warn · entropy > entropy_warn · ≥5 debt issues · analyzer medium |
| low      | any debt · network outbound call · analyzer low                 |
| none     | —                                                                |

Agents typically set `--fail-on=high` (block critical + high). Use
`--fail-on=critical` for "only hard-stop on leaked secrets and parse errors".

### Config & validation

```bash
./telemetry_observer.sh --validate                # checks config/main.yml + rules/*.yml
./telemetry_observer.sh --validate --config other.yml
```

See [`config/schema.json`](config/schema.json) for the full field contract.

## REST API

All endpoints live at `http://127.0.0.1:9999`. Override the port via
`API_PORT`. Every `/analyze`, `/trend`, `/` request accepts and echoes
`X-Trace-Id` (generated if absent) and forwards it to the engine so
stderr logs correlate cleanly.

**Telemetry + observability**

| Endpoint                                    | Purpose                                      |
|---------------------------------------------|----------------------------------------------|
| `GET /`                                     | Last cached snapshot (O(1) file read)        |
| `GET /analyze?path=ABS_PATH`                | Run engine on demand, return JSON            |
| `GET /trend?target=&limit=&since=`          | Query SQLite TSDB (newest first, ≤ 1000)     |
| `GET /healthz`                              | Liveness — always 200 if process is up       |
| `GET /readyz`                               | Readiness — 200 once engine + cache/db present |
| `GET /metrics`                              | Prometheus text exposition                   |
| `GET /ui/`                                  | React dashboard                              |

**Coordination API** — see [docs/guide/coordination-api.md](docs/guide/coordination-api.md)

| Endpoint                                          | Purpose                                              |
|---------------------------------------------------|------------------------------------------------------|
| `GET /repo/context?target=`                       | languages / stack / churn / hot + stable files       |
| `GET /repo/blame/:path?target=`                   | per-line blame with agent-id + revert detection      |
| `GET /repo/churn/:path?target=&since=`            | per-file modifications / reverts / contributors      |
| `GET /repo/agent-log?since=&run_id=&agent=&limit=`| query observations                                   |
| `GET /diff?target=&base=&branch=`                 | touched files + AST top-level delta                  |
| `GET /file/fingerprint?path=`                     | git sha + content hash + AST hash                    |
| `GET /file/imports?path=`                         | Python imports                                       |
| `GET /file/exports?path=`                         | Python top-level defs                                |
| `GET /symbol?path=&name=`                         | signature + in-file callers/callees                  |
| `GET /agent/identity/:commit`                     | agent/run that authored a commit                     |
| `GET /contract?path=`                             | public API surface                                   |
| `POST /observation`                               | append an agent event                                |
| `POST /claim` · `DELETE /claim` · `GET /claim`    | file-level agent locks                               |

See [docs/api/telemetry.md](docs/api/telemetry.md) for the full response
schema and query parameters.

## MCP (for AI agents)

```bash
cd mcp && go build -o ../occam-mcp .
```

Register the binary with your client. Example (Claude Desktop — macOS:
`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "occam": {
      "command": "/abs/path/to/occam-mcp",
      "env": {
        "ENGINE_SCRIPT": "/abs/path/to/telemetry_observer.sh"
      }
    }
  }
}
```

Tools exposed:

| Tool                       | Purpose                                                        |
|----------------------------|-----------------------------------------------------------------|
| `occam_analyze`            | full telemetry on a path                                       |
| `occam_check`              | gate mode — pass/fail vs `fail_on`                             |
| `occam_trend`              | query historical snapshots (SQLite TSDB)                       |
| `occam_validate_config`    | validate YAML config against the schema                        |
| `occam_health`             | probe engine dependencies                                      |
| `occam_repo_context`       | repo-wide languages / stack / churn / hot & stable files       |
| `occam_repo_blame`         | per-line blame with agent-id + revert detection                |
| `occam_repo_churn`         | per-file modification count / reverts / contributors           |
| `occam_repo_agent_log`     | query the observations log                                     |
| `occam_observation`        | append an event to the agent log                               |
| `occam_agent_identity`     | look up the agent that produced a given commit                 |
| `occam_diff`               | semantic diff between revs (touched files + AST-level delta)   |
| `occam_file_fingerprint`   | sha + content + ast hashes for a file                          |
| `occam_file_imports`       | list imports (Python v1)                                       |
| `occam_file_exports`       | top-level defs (Python v1)                                     |
| `occam_symbol`             | symbol inspection: signature, callers, callees (Python v1)     |
| `occam_claim_acquire`      | try-lock a file path (agent-level mutex)                       |
| `occam_claim_release`      | release a claim (idempotent)                                   |
| `occam_claims_list`        | list active claims                                             |
| `occam_contract`           | public API surface of a file                                   |

See [docs/guide/mcp.md](docs/guide/mcp.md) for Cursor, Windsurf, VS Code /
Copilot Chat, Zed, Continue setup snippets.

## Coordination API (multi-agent)

A set of HTTP endpoints designed for autonomous-coder systems (planners,
workers, refiners) that need a shared source of truth for repo context, code
structure, and agent activity. Every endpoint is also exposed as an MCP tool
above.

**Ready** (git-backed): `/repo/context`, `/repo/blame/:path`,
`/repo/churn/:path`, `/diff`, `/file/fingerprint`, `/agent/identity/:commit`

**Ready** (new SQLite state): `POST /observation`, `GET /repo/agent-log`,
`POST /claim`, `DELETE /claim`, `GET /claim`

**Ready** (Python AST): `/file/imports`, `/file/exports`, `/symbol`

**Partial**: `/contract` (public_api only; coupling/coverage require
cross-file index + test integration)

**Stubs** (HTTP 501 with `reason`): `/repo/test-map`, `/repo/failing-tests`,
`/file/frozen-regions`, `/file/last-safe`, `/run/:id/tests/delta`,
`/scorecard/:run_id`

Full contract + response shapes: [docs/guide/coordination-api.md](docs/guide/coordination-api.md).

```bash
# planner loop
curl -s "http://127.0.0.1:9999/repo/context?target=/abs/repo"       | jq .stack
curl -s "http://127.0.0.1:9999/repo/agent-log?since=24h&limit=20"   | jq 'map(.outcome)'

# worker
curl -s "http://127.0.0.1:9999/symbol?path=/abs/src.py&name=get_conn" | jq .signature
curl -XPOST -H 'content-type: application/json' \
     -d '{"path":"/abs/src.py","agent":"worker-1","ttl_seconds":300}' \
     http://127.0.0.1:9999/claim

# refiner
curl -s "http://127.0.0.1:9999/diff?target=/abs/repo&base=main&branch=feat" | jq .ast_top_level_delta
```

## Pluggable analyzers

Drop any executable into `analyzers/`. It is invoked as:

```
analyzers/NAME <TARGET_PATH> <DIFF_MODE>        # stdin = unified diff
```

and must emit one JSON object:

```json
{
  "name": "my-analyzer",
  "version": "1.0.0",
  "findings": [
    {"severity": "critical|high|medium|low|info",
     "kind": "security|debt|bug|perf|style|other",
     "rule_id": "pkg.rule.name",
     "file": "path/to/file.py",
     "line": 42,
     "message": "short human-readable",
     "text": "offending source (optional)"}
  ]
}
```

Exit non-zero = analyzer error (engine logs and skips). Analyzers must
complete within `OCCAM_ANALYZER_TIMEOUT` seconds (default 30) or they're
killed. Critical/high findings automatically escalate `.check.level`.

Included reference analyzers:

- [`analyzers/semgrep.sh`](analyzers/semgrep.sh) — wraps Semgrep, maps its
  severity/category taxonomy to Occam's.
- [`analyzers/python-ast.py`](analyzers/python-ast.py) — AST-based detector
  for `eval`/`exec`, `subprocess(shell=True)`, `pickle.load{,s}`, high
  cyclomatic complexity. Tree-sitter-class accuracy via stdlib `ast`.

Disable all analyzers with `OCCAM_NO_ANALYZERS=1`.

## Pre-commit hook

```bash
ln -s "$PWD/hooks/pre-commit" .git/hooks/pre-commit
# or in your target repo:
git config core.hooksPath /absolute/path/to/occam-observer/hooks
```

Advisory by default (prints a one-line summary, never blocks). Set
`OCCAM_HOOK_FAIL_ON=high` to turn it into a gate.

## Persistence & trends

Every analysis appends a row to
`${XDG_DATA_HOME:-~/.local/share}/occam-observer/snapshots.db`
(WAL mode). Override with `OCCAM_DB=/custom/path.db`, or disable entirely
via `OCCAM_NO_PERSIST=1`. Query via `/trend` or directly:

```bash
sqlite3 ~/.local/share/occam-observer/snapshots.db \
  "SELECT ts, target, health_score, check_level FROM snapshots ORDER BY id DESC LIMIT 20;"
```

## Docker

```bash
docker build -t occam-observer .
docker run --rm -p 9999:9999 -v "$PWD:/repo" occam-observer
curl "http://127.0.0.1:9999/analyze?path=/repo"
```

The image is API-only (no TUI, no watcher) — agents drive it via HTTP.
Mount a volume at `/var/lib/occam` to keep the TSDB across container restarts.

## Tests

```bash
./run_tests.sh
```

Runs every `tests/*.sh` suite plus `test_json.sh` (pathological JSON escape
coverage), `go vet`, `bash -n`, and `--validate` against the shipped config.

## Documentation

Full docs in [`docs/`](docs/) (VitePress):

```bash
cd docs && npm ci && npm run docs:dev
```

## Environment variables

| Variable                | Default                                   | Purpose                                       |
|-------------------------|-------------------------------------------|-----------------------------------------------|
| `API_PORT`              | `9999`                                    | Go gateway listen port                        |
| `CACHE_FILE`            | `/tmp/occam_state.json`                   | write-through JSON cache path                 |
| `ENGINE_SCRIPT`         | (resolved from api/)                      | absolute path to `telemetry_observer.sh`      |
| `OCCAM_DATA_DIR`        | `$XDG_DATA_HOME/occam-observer`           | TSDB directory                                |
| `OCCAM_DB`              | `$OCCAM_DATA_DIR/snapshots.db`            | TSDB file path                                |
| `OCCAM_NO_PERSIST`      | `0`                                        | `1` disables SQLite writes                    |
| `OCCAM_NO_ANALYZERS`    | `0`                                        | `1` disables analyzers/*                      |
| `OCCAM_ANALYZER_TIMEOUT`| `30`                                       | analyzer wall-clock limit (seconds)           |
| `OCCAM_SEMGREP_CONFIG`  | `auto`                                    | `-c` arg passed to Semgrep                    |
| `OCCAM_DEBOUNCE_MS`     | `400`                                     | watcher event coalescing window               |
| `OCCAM_LOG`             | `info`                                    | `quiet` silences structured stderr logs       |
| `OCCAM_HOOK_FAIL_ON`    | —                                          | turns the pre-commit hook into a blocking gate|
| `OCCAM_TRACE_ID`        | (propagated by Go gateway)                | correlation id for cross-process logs         |

## Exit codes

| Code | Meaning                                                        |
|------|-----------------------------------------------------------------|
| 0    | Success (or `--check` below threshold)                         |
| 1    | `--check` severity ≥ `--fail-on`                               |
| 2    | Engine runtime error                                           |
| 3    | Bad CLI arguments / invalid config                             |

## Changelog

### v0.2.0 — 2026-04-23

The "observer grew a nervous system" release. Occam went from a single-file
bash telemetry TUI to a full agent-facing platform.

**Engine**
- RFC 8259 JSON escape; `--check --fail-on=LEVEL` gate mode with exit codes
- `--diff=head|staged|working`; `--validate` against `config/schema.json`
- `violations[]` with per-line git-blame provenance; pluggable analyzer
  protocol (`analyzers/*` — stdin=diff, stdout=findings)
- Reference analyzers: Semgrep adapter, Python AST POC
  (eval/exec/pickle/shell=True/cyclomatic)
- Severity ladder (none → critical) escalated by analyzer findings
- Structured JSON logs with `trace_id` propagation
- Cache file atomically created at mode 0600 (no TOCTOU window)

**Gateway (api/main.go)**
- `/trend` over SQLite WAL TSDB
- `/healthz`, `/readyz`, `/metrics` (Prometheus text)
- `X-Trace-Id` middleware, request log, 30 s analyze timeout
- Background goroutine refreshes gauges (no sqlite3 fork per scrape)
- All data endpoints now same-origin only (removed `CORS *`)

**MCP server (mcp/)**
- Standalone Go binary `occam-mcp`, stdio JSON-RPC 2.0, protocol
  `2024-11-05`. Compatible with Claude Desktop, Cursor, Windsurf, VS Code /
  Copilot Chat, Zed, Continue. 20 tools total; per-client setup snippets in
  [docs/guide/mcp.md](docs/guide/mcp.md).

**Coordination API (for multi-agent systems)**
- 13 ready endpoints + 6 documented 501 stubs for repo context, blame,
  churn, diff, file imports/exports/fingerprint, symbol lookup,
  agent-identity, observations log, file-level claims, contract.
- New SQLite tables `observations` + `claims` (WAL, auto-GC on expire).
- Python symbol indexer (`analyzers/python-symbol-index.py`) backing
  `/symbol`, `/file/imports`, `/file/exports`, ast_hash.
- See [docs/guide/coordination-api.md](docs/guide/coordination-api.md) for
  the normative contract and [docs/guide/walkthrough.md](docs/guide/walkthrough.md)
  for a real end-to-end API trace.

**Dashboard (web/src/App.tsx)**
- Full Typescript type definitions (no `any`)
- Error UI, AbortController, `visibilitychange` pause, a11y (aria-live,
  role=meter, sr-only labels, motion-reduce)
- Shows new fields: `trace_id`, `diff_mode`, `check.level` ribbon,
  violations with blame, analyzer findings, perf footer

**DevEx**
- `run_tests.sh` unified runner; 6 regression suites, 97 assertions
- Dockerfile (API-only runtime)
- `hooks/pre-commit` (advisory / gating via `OCCAM_HOOK_FAIL_ON=LEVEL`)
- `.github/workflows/tests.yml` (bash -n, `go vet`, `--validate`, tests)
- `scripts/build-ui.sh` for web → api/public static deploy

**Docs**
- README/docs rewrite — honest stack (bash + Go + Python + React)
- `docs/guide/` pages: architecture, state-vectors, semantic-mappings,
  mcp, coordination-api, walkthrough
- Every hardcoded personal path scrubbed
- VitePress sidebar repaired (previously pointed at nonexistent pages)

### v0.1.0 — 2026-04-23

Initial commit — bash TUI telemetry engine + minimal Go gateway + React
dashboard skeleton.

## License

MIT. A `LICENSE` file has not been committed yet — consider adding one before
publishing the repository.
