# API Reference

The Occam Observer runs a lightweight Go API Gateway on port `9999` by default. It exposes real-time telemetry via a high-performance JSON cache.

## Endpoint: `GET /`

Returns the current global state of the monitored repository. Latency is O(1) as it reads directly from a write-through memory-mapped cache.

### Response Payload

```json
{
  "version": "3.0.0",
  "timestamp": "2026-04-23T13:36:38+0200",
  "branch": "main",
  "commit": "b65a6ba",
  "target": "/Users/fab/Documents/git/gitoma",
  "is_idle": false,
  "metrics": {
    "security_violations": 0,
    "mass_insertions": 12,
    "mass_deletions": 2,
    "mass_files_changed": 1,
    "entropy_nodes": 4,
    "test_files_modified": 0,
    "debt_issues": 0
  },
  "git": {
    "author": "Fabrizio Salmi <fabrizio.salmi@gmail.com>",
    "message": "fix: update logic paths",
    "time": "2026-04-23T13:32:27+02:00",
    "remote": "https://github.com/fabriziosalmi/gitoma.git",
    "is_dirty": true
  },
  "intelligence": {
    "file_types": {
      "logic": ["server.js"],
      "config": [],
      "docs": [],
      "media": []
    },
    "infrastructure_changes": [],
    "schema_mutations": [],
    "network_outbound": [],
    "signatures_added": ["function startServer()"],
    "dependencies_added": ["require('express')"],
    "syntax_valid": ["server.js"],
    "syntax_invalid": []
  },
  "health_score": 95
}
```

## Endpoint: `GET /analyze?path=/abs/path`

Performs an on-demand, headless analysis of the specified local repository path.

**Parameters:**
- `path` (string, required): The absolute path to the repository.

Returns the exact same JSON payload structure as the root endpoint.
