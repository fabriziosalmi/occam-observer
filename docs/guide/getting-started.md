# Getting Started

## Prerequisites

| Needed for            | Tool                  | Install                                    |
|-----------------------|-----------------------|--------------------------------------------|
| Engine core           | `bash` ≥ 3.2, `git`   | preinstalled                               |
| JSON handling         | `jq`                  | `brew install jq` · `apt install jq`       |
| HTTP gateway          | `go` ≥ 1.21           | `brew install go`                          |
| Persistence / trends  | `sqlite3`             | preinstalled · `apt install sqlite3`       |
| File watch (TUI mode) | `fswatch` / `inotify` | `brew install fswatch` · `apt install inotify-tools` |
| AST analyzer          | `python3` ≥ 3.8       | preinstalled                               |
| Rule-based analyzer   | `semgrep` (optional)  | `pip install semgrep`                      |

Optional dependencies degrade gracefully: missing `sqlite3` disables `/trend`
and persistence; missing `semgrep` turns that analyzer into a no-op; missing
`fswatch`/`inotifywait` only affects the interactive TUI watcher — headless
modes (`--json`, `--check`) still work.

## Install

```bash
git clone https://github.com/fabriziosalmi/occam-observer.git
cd occam-observer
chmod +x telemetry_observer.sh analyzers/*
```

No `go build` step is required — the engine invokes `go run api/main.go` the
first time the gateway is needed. If you prefer a prebuilt binary:

```bash
( cd api && go build -o ../occam-api . )
ENGINE_SCRIPT="$PWD/telemetry_observer.sh" ./occam-api
```

## Modes

### 1. Interactive TUI + API server

```bash
./telemetry_observer.sh /absolute/path/to/repo
```

Renders the dashboard in the alternate screen buffer, starts the Go gateway
on `127.0.0.1:9999`, re-analyzes on every file save. `CTRL+C` exits cleanly.

### 2. Headless JSON (agents / scripts)

```bash
./telemetry_observer.sh --json /absolute/path/to/repo
```

Prints a full telemetry payload (see
[API reference](/api/telemetry)) to stdout. Analyzes once and exits.

### 3. Pipeline gate

```bash
./telemetry_observer.sh --check --fail-on=high --staged /abs/repo
# 0 = below threshold · 1 = at/above · 2 = engine error · 3 = bad args
```

Same output as `--json` plus an exit code tied to `.check.level`.

### 4. Diff selection

| Flag         | Reads                                    |
|--------------|------------------------------------------|
| *(default)*  | `git diff HEAD` (staged + unstaged)      |
| `--staged`   | `git diff --cached`                      |
| `--working`  | `git diff` (unstaged only)               |

## Configuration

`config/main.yml` is loaded automatically from the script's directory. Pass
`--config /elsewhere.yml` to override. Validate:

```bash
./telemetry_observer.sh --validate
./telemetry_observer.sh --validate --config /elsewhere.yml
```

Schema contract: see [`config/schema.json`](https://github.com/fabriziosalmi/occam-observer/blob/main/config/schema.json).

## Dashboard

Open `http://127.0.0.1:9999/ui/` once the observer is running. It reads
`GET /` every second and renders: the check ribbon, integrity score,
per-line violations with blame, analyzer findings, and a playground that
hits `GET /analyze?path=…` against any local path.

## Pre-commit hook

```bash
# one-time install (advisory — never blocks)
ln -s "$PWD/hooks/pre-commit" /path/to/target-repo/.git/hooks/pre-commit

# blocking variant (per invocation)
OCCAM_HOOK_FAIL_ON=high git commit -m "..."
```

## Docker

```bash
docker build -t occam-observer .
docker run --rm -p 9999:9999 -v "$PWD:/repo" occam-observer
curl "http://127.0.0.1:9999/analyze?path=/repo"
```

API-only — agents drive it via HTTP; mount `/var/lib/occam` to keep the TSDB
across restarts.

## Next steps

- [Architecture](./architecture) — component layout, data flow, invariants.
- [State vectors](./state-vectors) — metrics, health score, severity model.
- [Semantic mappings](./semantic-mappings) — intelligence block & analyzers.
- [API reference](../api/telemetry) — full REST contract.
