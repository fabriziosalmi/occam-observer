# Model Context Protocol (MCP) server

Occam Observer ships a first-class MCP server (`occam-mcp`) so AI agents can
drive the engine through a standard, LLM-oriented interface instead of HTTP.
It's a Go binary that speaks JSON-RPC 2.0 over stdio, compatible with every
MCP client as of 2026-04: Claude Desktop, Cursor, Windsurf, VS Code / GitHub
Copilot Chat, Zed, Continue, and anything else that implements MCP
`2024-11-05` or later.

The MCP server runs **locally** — no network hop, no daemon. The client
spawns it as a subprocess; there is nothing to install server-side.

## Exposed tools

| Tool                     | What it does                                                       |
|--------------------------|--------------------------------------------------------------------|
| `occam_analyze`          | Full telemetry on a path (metrics, violations, analyzers, check)  |
| `occam_check`            | Gate mode — returns `{passed, exit_code, result}` given a `fail_on`|
| `occam_trend`            | Query the SQLite TSDB of past analyses                            |
| `occam_validate_config`  | Check `config/main.yml` + `config/rules/*.yml` against the contract |
| `occam_health`           | Probe `git`, `bash`, `jq`, `sqlite3`, `python3`, `semgrep` availability |

Call `tools/list` after `initialize` to get the live JSON schemas — they
match the CLI flags 1:1.

## Build

```bash
cd mcp
go build -o occam-mcp .
# optional: install system-wide
sudo install -m 0755 occam-mcp /usr/local/bin/occam-mcp
```

Requires Go ≥ 1.21. The binary is CGO-free and statically linked; you can
ship it alongside your agent config.

## Environment

| Variable         | Purpose                                           | Default                                  |
|------------------|---------------------------------------------------|------------------------------------------|
| `ENGINE_SCRIPT`  | Absolute path to `telemetry_observer.sh`          | probed relative to the binary            |
| `OCCAM_DB`       | SQLite TSDB path (used by `occam_trend`)          | `$XDG_DATA_HOME/occam-observer/snapshots.db` |

At minimum, point `ENGINE_SCRIPT` at the bash engine:

```bash
export ENGINE_SCRIPT="$HOME/src/occam-observer/telemetry_observer.sh"
```

If you prefer a single self-contained install directory, put `occam-mcp`
next to `telemetry_observer.sh` — the binary auto-discovers the engine if
they share a parent directory.

## Protocol notes

- Transport: newline-delimited JSON on stdin/stdout. **Log lines go to
  stderr** — never mix them with RPC output.
- Protocol version advertised: `2024-11-05`. Clients that negotiate a
  newer version will still interop because the core methods
  (`initialize`, `tools/list`, `tools/call`, `ping`, `notifications/*`)
  are stable.
- Tool responses return MCP `content` blocks of `type:"text"` carrying the
  raw telemetry JSON. Agents can parse directly; no double-decoding.
- Tool-level failures set `isError: true` on a successful JSON-RPC envelope
  (per MCP spec). Transport failures use JSON-RPC `error` (codes -32700
  parse error, -32601 method not found, -32602 invalid params, -32000
  generic server error).
- Stdin frame cap: 512 KiB. Oversized frames are rejected to prevent a
  malicious local tool from OOMing the server.

## Client setup

### Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`
(macOS) or `%APPDATA%\Claude\claude_desktop_config.json` (Windows):

```json
{
  "mcpServers": {
    "occam": {
      "command": "/usr/local/bin/occam-mcp",
      "env": {
        "ENGINE_SCRIPT": "/Users/you/src/occam-observer/telemetry_observer.sh"
      }
    }
  }
}
```

Restart Claude Desktop. In a conversation, type `@occam` to reference the
tools or just ask "run occam on ~/src/my-repo and tell me what's wrong".

### Cursor

Edit `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "occam": {
      "command": "/usr/local/bin/occam-mcp",
      "env": {
        "ENGINE_SCRIPT": "/abs/path/to/telemetry_observer.sh"
      }
    }
  }
}
```

Open Cursor's MCP panel (Settings → Features → MCP) to confirm the
`occam-*` tools appear green.

### Windsurf

Edit `~/.codeium/windsurf/mcp_config.json`:

```json
{
  "mcpServers": {
    "occam": {
      "command": "/usr/local/bin/occam-mcp",
      "env": {
        "ENGINE_SCRIPT": "/abs/path/to/telemetry_observer.sh"
      }
    }
  }
}
```

Restart Windsurf; check **Cascade → Available MCP servers**.

### VS Code (GitHub Copilot Chat)

VS Code 1.99+ supports MCP natively via the workspace `.vscode/mcp.json`
or user settings. Workspace config:

```json
// .vscode/mcp.json
{
  "servers": {
    "occam": {
      "type": "stdio",
      "command": "/usr/local/bin/occam-mcp",
      "env": {
        "ENGINE_SCRIPT": "${workspaceFolder}/telemetry_observer.sh"
      }
    }
  }
}
```

Or via user settings `settings.json`:

```json
"mcp": {
  "servers": {
    "occam": {
      "type": "stdio",
      "command": "/usr/local/bin/occam-mcp",
      "env": { "ENGINE_SCRIPT": "/abs/path/to/telemetry_observer.sh" }
    }
  }
}
```

Open the Copilot Chat panel; the `occam-*` tools appear in the tool picker.

### Zed

Edit `~/.config/zed/settings.json`:

```json
{
  "context_servers": {
    "occam": {
      "command": {
        "path": "/usr/local/bin/occam-mcp",
        "args": [],
        "env": { "ENGINE_SCRIPT": "/abs/path/to/telemetry_observer.sh" }
      }
    }
  }
}
```

### Continue (JetBrains / VS Code)

Edit `~/.continue/config.json`:

```json
{
  "experimental": {
    "modelContextProtocolServers": [
      {
        "transport": {
          "type": "stdio",
          "command": "/usr/local/bin/occam-mcp",
          "env": { "ENGINE_SCRIPT": "/abs/path/to/telemetry_observer.sh" }
        }
      }
    ]
  }
}
```

## Smoke-testing by hand

You can drive the server directly from a shell to verify a setup:

```bash
# initialize + tools/list + occam_analyze on a repo
ENGINE_SCRIPT=/abs/path/to/telemetry_observer.sh \
  printf '%s\n%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","clientInfo":{"name":"shell","version":"1"}}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"occam_analyze","arguments":{"path":"/abs/repo"}}}' \
  | occam-mcp | jq -c .
```

Expect three responses: the initialize result, the tools list, and the
telemetry payload wrapped in a `content[0].text` block.

## Suggested agent prompts

- "Use `occam_check` with `fail_on=high` on this repo; if it fails, show
  me the specific reasons and the violation blames."
- "Call `occam_trend` for this repo, limit 20, and report if the health
  score is trending down."
- "Run `occam_health` first so I know which optional deps are missing
  before you start."
- "Run `occam_validate_config`; if invalid, summarize the errors."

## Troubleshooting

| Symptom                                         | Likely cause                                      | Fix                                          |
|--------------------------------------------------|---------------------------------------------------|----------------------------------------------|
| Client says "0 tools" after connect              | `occam-mcp` binary not executable or not in PATH  | `chmod +x /path/to/occam-mcp` or use absolute path |
| `occam_analyze` → "engine script not found"     | `ENGINE_SCRIPT` unset and binary moved            | Set `ENGINE_SCRIPT` explicitly               |
| `occam_trend` → "no snapshots yet"              | TSDB doesn't exist                                | Run the engine once (`./telemetry_observer.sh --json /repo`) |
| Every tool errors with `timeout`                 | Analyzers hanging (no `timeout` binary)           | macOS: `brew install coreutils`              |
| "parse error" (-32700) on every request          | Client is sending non-JSON-RPC or wrong encoding  | Check the client's MCP transport logs        |

## Security

- The server only reads paths the calling agent provides. It never writes
  to the repo itself (engine reads via `git -C`).
- Path arguments are validated: no leading `-`, must be an existing directory,
  canonicalized via `filepath.Abs`.
- The SQLite queries use quoted-literal escaping (`'`→`''`). Limit is
  capped at 1000 rows.
- All subprocess invocations carry a wall-clock timeout (60 s for analyze,
  5 s for trend / validate).
