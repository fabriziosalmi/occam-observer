---
layout: home

hero:
  name: "Occam Observer"
  text: "Out-of-band Git telemetry"
  tagline: Agent-friendly health signals, severity-graded checks, and pluggable analyzers for any local repository.
  actions:
    - theme: brand
      text: Get Started
      link: /guide/getting-started
    - theme: alt
      text: REST API
      link: /api/telemetry
    - theme: alt
      text: GitHub
      link: https://github.com/fabriziosalmi/occam-observer

features:
  - title: MCP-native
    details: Ships a stdio JSON-RPC server (occam-mcp) compatible with Claude Desktop, Cursor, Windsurf, VS Code / Copilot Chat, Zed, Continue. Agents get structured tools instead of parsing curl output.
  - title: Built for AI agents
    details: JSON-correct by construction, RFC 8259 escaping, X-Trace-Id correlation end-to-end, exit codes on --check --fail-on that plug straight into CI or agent pipelines.
  - title: Pluggable analyzers
    details: Drop any executable into analyzers/. Ships with a Semgrep adapter and a Python-AST POC. Critical/high findings auto-escalate the check verdict.
  - title: Three diff modes
    details: --diff=head, --staged, --working — inspect exactly the slice of work you care about. Per-line blame shows whether a violation is brand new or pre-existing.
  - title: Time-series + self-obs
    details: SQLite TSDB (WAL) with a /trend endpoint, plus /healthz, /readyz, and a Prometheus /metrics scrape target out of the box.
---

## What it does

Occam Observer runs the [bash engine](https://github.com/fabriziosalmi/occam-observer/blob/main/telemetry_observer.sh)
against any local Git repository and emits a single JSON payload per analysis
covering:

- **Five metric vectors** — security, mass, entropy, testing, debt
- **An intelligence block** — infrastructure/schema/network changes,
  signatures, dependencies, per-line violations with `git blame` provenance
- **Analyzer findings** — merged results from Semgrep, the built-in Python
  AST walker, and any custom plugin you drop in
- **A derived check verdict** — `none` / `low` / `medium` / `high` / `critical`
  with machine-parseable reasons
- **Self-metrics** — engine duration, diff size, analyzers run, prometheus
  scrape on the gateway side

The Go HTTP gateway (`api/main.go`) fronts the engine with `/`, `/analyze`,
`/trend`, `/healthz`, `/readyz`, `/metrics`. Every request is traced with
`X-Trace-Id`, so engine logs and gateway logs correlate without extra work.

## What it is not

- Not a CI replacement. It's a **local** telemetry daemon and pre-commit gate.
- Not a full tree-sitter engine yet — the Python AST analyzer is a POC
  showing the pluggable protocol; extend via `analyzers/`.
- Not multi-user. Single-node, single-writer against the cache file and DB.
