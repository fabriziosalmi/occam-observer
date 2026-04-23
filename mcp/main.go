// occam-mcp: Model Context Protocol (MCP) server for Occam Observer.
//
// Speaks JSON-RPC 2.0 over stdin/stdout (newline-delimited frames) per the
// MCP spec version 2024-11-05 — the lowest common denominator supported by
// Claude Desktop, Cursor, VS Code Copilot, and Windsurf as of 2026-04.
//
// Transport: one JSON object per line on stdin → one JSON object per line on
// stdout. Log lines go to stderr (stdio convention: never mix with the RPC
// channel). Buffered stdout is flushed after every write to avoid deadlocks
// in clients that read line-by-line.
//
// Tools exposed:
//
//   occam_analyze         — run the engine on a local path, return telemetry JSON
//   occam_check           — gate mode with fail-on threshold, returns verdict + exit status
//   occam_trend           — query the SQLite TSDB (bounded limit)
//   occam_validate_config — constraint check of config/main.yml + rules/*.yml
//   occam_health          — quick status of the underlying engine deps
//
// The binary intentionally has no HTTP dependency — it spawns the bash
// engine and reads the SQLite DB directly. ENGINE_SCRIPT pins the engine
// path; if missing, the server falls back to probing relative to its own
// executable.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	serverName       = "occam-observer-mcp"
	serverVersion    = "0.2.1"
	protocolVersion  = "2024-11-05"
	analyzerTimeout  = 60 * time.Second
	// Frame cap tightened from 8 MiB → 512 KiB. MCP clients realistically
	// only send small RPC frames; a bigger buffer just gives a malicious
	// local tool more room to OOM the server.
	maxStdinFrame    = 512 * 1024
	defaultTrendCap  = 1000
)

// ── JSON-RPC 2.0 envelopes ───────────────────────────────────────────────────

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

// JSON-RPC error codes: standard set plus MCP reserved range.
const (
	errParseError     = -32700
	errInvalidRequest = -32600
	errMethodNotFound = -32601
	errInvalidParams  = -32602
	errInternal       = -32603
	errServer         = -32000
)

// ── Tool catalog ─────────────────────────────────────────────────────────────

type toolSchema struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
}

var toolCatalog = []toolSchema{
	{
		Name: "occam_analyze",
		Description: "Run Occam Observer telemetry on a local Git repository. " +
			"Returns a structured JSON payload with: security/complexity/debt metrics, " +
			"intelligence block (infrastructure/schema/network changes, signatures, " +
			"dependencies, per-line violations with git blame provenance), pluggable " +
			"analyzer findings (Semgrep, Python AST), a severity verdict (check.level) " +
			"and reasons, plus engine performance metrics. Use diff_mode to select " +
			"HEAD vs staged vs working-tree changes.",
		InputSchema: map[string]any{
			"type":     "object",
			"required": []string{"path"},
			"properties": map[string]any{
				"path": map[string]any{
					"type":        "string",
					"description": "Absolute filesystem path to a Git repository.",
				},
				"diff_mode": map[string]any{
					"type":        "string",
					"enum":        []string{"head", "staged", "working"},
					"default":     "head",
					"description": "Which diff slice to analyze: head = staged+unstaged vs HEAD, staged = index vs HEAD, working = unstaged only.",
				},
			},
		},
	},
	{
		Name: "occam_check",
		Description: "Run Occam in gate mode. Computes the same telemetry as occam_analyze " +
			"but returns a pass/fail verdict based on the fail_on threshold. The response " +
			"includes the full JSON payload PLUS a top-level 'passed' boolean and " +
			"'exit_code' equivalent (0 = below threshold, 1 = at/above).",
		InputSchema: map[string]any{
			"type":     "object",
			"required": []string{"path"},
			"properties": map[string]any{
				"path": map[string]any{"type": "string"},
				"fail_on": map[string]any{
					"type":        "string",
					"enum":        []string{"low", "medium", "high", "critical"},
					"default":     "high",
					"description": "Severity threshold. Fails if actual level >= threshold.",
				},
				"diff_mode": map[string]any{
					"type":    "string",
					"enum":    []string{"head", "staged", "working"},
					"default": "head",
				},
			},
		},
	},
	{
		Name: "occam_trend",
		Description: "Query the SQLite time-series store (snapshots table). Returns an " +
			"array of historical snapshots newest-first, each with timestamps, health " +
			"score, metric counters, check_level, and diff_mode. Useful to answer " +
			"'how has this repo's health moved over the last N analyses?'.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"target": map[string]any{
					"type":        "string",
					"description": "Optional absolute path filter. Omit to return all.",
				},
				"limit": map[string]any{
					"type":        "integer",
					"minimum":     1,
					"maximum":     defaultTrendCap,
					"default":     100,
					"description": "Max rows (capped at 1000).",
				},
				"since": map[string]any{
					"type":        "string",
					"description": "ISO-8601 lower bound on the ts column.",
				},
			},
		},
	},
	{
		Name: "occam_validate_config",
		Description: "Validate config/main.yml and config/rules/*.yml against the Occam " +
			"constraint contract. Emits structured errors on stderr from the engine and " +
			"returns {valid: bool, exit_code: int}.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"config_path": map[string]any{
					"type":        "string",
					"description": "Optional override for config/main.yml.",
				},
			},
		},
	},
	{
		Name: "occam_health",
		Description: "Probe the underlying engine dependencies (git, bash, jq, sqlite3, " +
			"python3, semgrep) and return their availability. Helpful before running a " +
			"long analyze to confirm the agent has what it needs.",
		InputSchema: map[string]any{"type": "object", "properties": map[string]any{}},
	},

	// ── Coordination API (HTTP-proxied) ──────────────────────────────────────

	{
		Name: "occam_repo_context",
		Description: "Return a repo-wide structural snapshot: languages (by file/byte count), detected build stack (poetry/pip/go/npm/cargo/docker/github-actions), recent churn stats, hot files, stable files. Cheap; call every planning round.",
		InputSchema: map[string]any{
			"type": "object", "required": []string{"target"},
			"properties": map[string]any{"target": map[string]any{"type": "string"}},
		},
	},
	{
		Name: "occam_repo_blame",
		Description: "Per-line git blame for a file (relative to target). Enriched with agent/run_id when the commit is in the observations log, and with revert detection over the last 500 commits.",
		InputSchema: map[string]any{
			"type": "object", "required": []string{"target", "path"},
			"properties": map[string]any{
				"target": map[string]any{"type": "string"},
				"path":   map[string]any{"type": "string", "description": "relative to target"},
			},
		},
	},
	{
		Name: "occam_repo_churn",
		Description: "Modification count, revert count, and contributor list for a file over the given window.",
		InputSchema: map[string]any{
			"type": "object", "required": []string{"target", "path"},
			"properties": map[string]any{
				"target": map[string]any{"type": "string"},
				"path":   map[string]any{"type": "string"},
				"since":  map[string]any{"type": "string", "default": "30d", "description": "duration (e.g. 7d, 48h) or ISO-8601"},
			},
		},
	},
	{
		Name: "occam_repo_agent_log",
		Description: "Query the observations log — events recorded by agents via occam_observation. Supports filtering by since (duration or ISO), run_id, agent. Newest first, limit ≤ 1000.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"since":  map[string]any{"type": "string"},
				"run_id": map[string]any{"type": "string"},
				"agent":  map[string]any{"type": "string"},
				"limit":  map[string]any{"type": "integer", "minimum": 1, "maximum": 1000, "default": 100},
			},
		},
	},
	{
		Name: "occam_diff",
		Description: "Semantic diff between two revs (base...branch). Returns touched_files and an AST-top-level delta (Python only v1: added/removed/modified top-level defs and classes).",
		InputSchema: map[string]any{
			"type": "object", "required": []string{"target", "base", "branch"},
			"properties": map[string]any{
				"target": map[string]any{"type": "string"},
				"base":   map[string]any{"type": "string"},
				"branch": map[string]any{"type": "string"},
			},
		},
	},
	{
		Name: "occam_file_fingerprint",
		Description: "Identity hashes for a file: git-index sha, sha256 of content, and (Python only) an AST hash that is insensitive to whitespace and comments.",
		InputSchema: map[string]any{
			"type": "object", "required": []string{"path"},
			"properties": map[string]any{"path": map[string]any{"type": "string"}},
		},
	},
	{
		Name: "occam_file_imports",
		Description: "List every import in a Python file: {module, symbol_imported, alias, line}. Non-Python files return an empty list.",
		InputSchema: map[string]any{
			"type": "object", "required": []string{"path"},
			"properties": map[string]any{"path": map[string]any{"type": "string"}},
		},
	},
	{
		Name: "occam_file_exports",
		Description: "Top-level definitions of a Python file (functions, classes, module-level vars). Each entry has {name, kind, lineno, public}.",
		InputSchema: map[string]any{
			"type": "object", "required": []string{"path"},
			"properties": map[string]any{"path": map[string]any{"type": "string"}},
		},
	},
	{
		Name: "occam_symbol",
		Description: "Inspect a symbol in a Python file: signature (reconstructed), kind, in-file callers and callees. Cross-file call graph is NOT yet implemented. Critical for workers to avoid silently narrowing a function's contract.",
		InputSchema: map[string]any{
			"type": "object", "required": []string{"path", "name"},
			"properties": map[string]any{
				"path": map[string]any{"type": "string"},
				"name": map[string]any{"type": "string"},
			},
		},
	},
	{
		Name: "occam_agent_identity",
		Description: "Look up the agent/run that produced a given commit SHA (via the observations log). Returns null if the commit was not recorded by any agent.",
		InputSchema: map[string]any{
			"type": "object", "required": []string{"commit"},
			"properties": map[string]any{"commit": map[string]any{"type": "string"}},
		},
	},
	{
		Name: "occam_observation",
		Description: "Append an event to the agent log. Required: run_id, agent, outcome (success|fail|partial|aborted). Optional: subtask_id, model, branch, commit_sha, touched_files, failure_modes, confidence, extra. Workers should call this at subtask end.",
		InputSchema: map[string]any{
			"type":     "object",
			"required": []string{"run_id", "agent", "outcome"},
			"properties": map[string]any{
				"run_id":        map[string]any{"type": "string"},
				"agent":         map[string]any{"type": "string"},
				"subtask_id":    map[string]any{"type": "string"},
				"model":         map[string]any{"type": "string"},
				"branch":        map[string]any{"type": "string"},
				"commit_sha":    map[string]any{"type": "string"},
				"outcome":       map[string]any{"type": "string", "enum": []string{"success", "fail", "partial", "aborted"}},
				"touched_files": map[string]any{"type": "array", "items": map[string]any{"type": "string"}},
				"failure_modes": map[string]any{"type": "array", "items": map[string]any{"type": "string"}},
				"confidence":    map[string]any{"type": "number", "minimum": 0, "maximum": 1},
				"extra":         map[string]any{"type": "object"},
			},
		},
	},
	{
		Name: "occam_claim_acquire",
		Description: "Try to acquire an exclusive claim on a file path (agent-level file lock). Returns {lock_id, expires_at} on success; 409 conflict with held_by otherwise. ttl_seconds is clamped to [30, 3600] (default 600).",
		InputSchema: map[string]any{
			"type": "object", "required": []string{"path", "agent"},
			"properties": map[string]any{
				"path":        map[string]any{"type": "string"},
				"agent":       map[string]any{"type": "string"},
				"run_id":      map[string]any{"type": "string"},
				"ttl_seconds": map[string]any{"type": "integer", "minimum": 30, "maximum": 3600, "default": 600},
			},
		},
	},
	{
		Name: "occam_claim_release",
		Description: "Release a claim by lock_id (preferred) or by path. Idempotent.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"lock_id": map[string]any{"type": "string"},
				"path":    map[string]any{"type": "string"},
			},
		},
	},
	{
		Name: "occam_claims_list",
		Description: "List active claims. Filter by path when provided.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{"path": map[string]any{"type": "string"}},
		},
	},
	{
		Name: "occam_contract",
		Description: "Return the public API surface of a file (public_api, test_coverage=0 v1, coupling_score=0 v1). Currently Python-only; other languages return an empty public_api.",
		InputSchema: map[string]any{
			"type": "object", "required": []string{"path"},
			"properties": map[string]any{"path": map[string]any{"type": "string"}},
		},
	},
}

// httpSpec describes how to dispatch an MCP tool call to the HTTP gateway.
// method is "GET" / "POST" / "DELETE". queryArgs + pathArg move arguments into
// the URL; bodyArgs go in a JSON body (POST only).
type httpSpec struct {
	method    string
	path      string
	queryArgs []string
	pathArg   string // when non-empty, args[pathArg] is appended to the URL as "/<value>"
	bodyArgs  []string
	bodyAll   bool // post the whole arguments object as JSON
}

var httpToolRoutes = map[string]httpSpec{
	"occam_repo_context":    {method: "GET", path: "/repo/context", queryArgs: []string{"target"}},
	"occam_repo_blame":      {method: "GET", path: "/repo/blame", queryArgs: []string{"target"}, pathArg: "path"},
	"occam_repo_churn":      {method: "GET", path: "/repo/churn", queryArgs: []string{"target", "since"}, pathArg: "path"},
	"occam_repo_agent_log":  {method: "GET", path: "/repo/agent-log", queryArgs: []string{"since", "run_id", "agent", "limit"}},
	"occam_diff":            {method: "GET", path: "/diff", queryArgs: []string{"target", "base", "branch"}},
	"occam_file_fingerprint":{method: "GET", path: "/file/fingerprint", queryArgs: []string{"path"}},
	"occam_file_imports":    {method: "GET", path: "/file/imports", queryArgs: []string{"path"}},
	"occam_file_exports":    {method: "GET", path: "/file/exports", queryArgs: []string{"path"}},
	"occam_symbol":          {method: "GET", path: "/symbol", queryArgs: []string{"path", "name"}},
	"occam_agent_identity":  {method: "GET", path: "/agent/identity", pathArg: "commit"},
	"occam_observation":     {method: "POST", path: "/observation", bodyAll: true},
	"occam_claim_acquire":   {method: "POST", path: "/claim", bodyAll: true},
	"occam_claim_release":   {method: "DELETE", path: "/claim", queryArgs: []string{"lock_id", "path"}},
	"occam_claims_list":     {method: "GET", path: "/claim", queryArgs: []string{"path"}},
	"occam_contract":        {method: "GET", path: "/contract", queryArgs: []string{"path"}},
}

var httpClient = &http.Client{Timeout: 15 * time.Second}

func gatewayBaseURL() string {
	if v := os.Getenv("OCCAM_API_URL"); v != "" {
		return strings.TrimRight(v, "/")
	}
	return "http://127.0.0.1:9999"
}

// ── Server state ─────────────────────────────────────────────────────────────

type server struct {
	engineScript string
	dbPath       string
	out          *bufio.Writer
	outMu        sync.Mutex
}

func main() {
	log.SetFlags(0)
	log.SetPrefix("occam-mcp: ")
	log.SetOutput(os.Stderr)

	s := &server{
		engineScript: resolveEngineScript(),
		dbPath:       resolveDBPath(),
		out:          bufio.NewWriter(os.Stdout),
	}
	if s.engineScript == "" {
		log.Printf("warn: ENGINE_SCRIPT not set and telemetry_observer.sh not found near %s", mustExePath())
	}

	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 64*1024), maxStdinFrame)

	for scanner.Scan() {
		line := scanner.Bytes()
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		var req rpcRequest
		if err := json.Unmarshal(line, &req); err != nil {
			s.writeError(nil, errParseError, "parse error", err.Error())
			continue
		}
		if req.JSONRPC != "" && req.JSONRPC != "2.0" {
			s.writeError(req.ID, errInvalidRequest, "unsupported jsonrpc version", req.JSONRPC)
			continue
		}
		s.dispatch(&req)
	}
	if err := scanner.Err(); err != nil && !errors.Is(err, io.EOF) {
		log.Printf("stdin scan: %v", err)
	}
	s.out.Flush()
}

func (s *server) dispatch(req *rpcRequest) {
	switch req.Method {
	case "initialize":
		s.handleInitialize(req)
	case "notifications/initialized", "initialized":
		// no response expected
	case "ping":
		s.writeResult(req.ID, map[string]any{})
	case "tools/list":
		s.writeResult(req.ID, map[string]any{"tools": toolCatalog})
	case "tools/call":
		s.handleToolCall(req)
	case "shutdown":
		s.writeResult(req.ID, nil)
	default:
		s.writeError(req.ID, errMethodNotFound, "method not found", req.Method)
	}
}

// ── Handlers ─────────────────────────────────────────────────────────────────

func (s *server) handleInitialize(req *rpcRequest) {
	s.writeResult(req.ID, map[string]any{
		"protocolVersion": protocolVersion,
		"capabilities": map[string]any{
			"tools": map[string]any{"listChanged": false},
		},
		"serverInfo": map[string]any{
			"name":    serverName,
			"version": serverVersion,
		},
		"instructions": "Call occam_analyze with an absolute repo path to get structured " +
			"telemetry. Use occam_check for gate-style pass/fail. occam_trend returns " +
			"historical snapshots from SQLite.",
	})
}

func (s *server) handleToolCall(req *rpcRequest) {
	var p struct {
		Name      string         `json:"name"`
		Arguments map[string]any `json:"arguments"`
	}
	if err := json.Unmarshal(req.Params, &p); err != nil {
		s.writeError(req.ID, errInvalidParams, "invalid params", err.Error())
		return
	}
	if p.Arguments == nil {
		p.Arguments = map[string]any{}
	}

	switch p.Name {
	case "occam_analyze":
		s.callAnalyze(req, p.Arguments, false, "")
	case "occam_check":
		failOn, _ := p.Arguments["fail_on"].(string)
		s.callAnalyze(req, p.Arguments, true, failOn)
	case "occam_trend":
		s.callTrend(req, p.Arguments)
	case "occam_validate_config":
		s.callValidate(req, p.Arguments)
	case "occam_health":
		s.callHealth(req)
	default:
		if spec, ok := httpToolRoutes[p.Name]; ok {
			s.callHTTPTool(req, p.Name, spec, p.Arguments)
			return
		}
		s.writeError(req.ID, errInvalidParams, "unknown tool", p.Name)
	}
}

// callHTTPTool dispatches a tool to the Go HTTP gateway. It is deliberately
// the ONLY path for coordination endpoints so the MCP server doesn't
// re-implement git/sqlite/Python-indexer logic.
func (s *server) callHTTPTool(req *rpcRequest, name string, spec httpSpec, args map[string]any) {
	// Build URL.
	u, err := url.Parse(gatewayBaseURL() + spec.path)
	if err != nil {
		s.toolError(req.ID, "internal: bad gateway url")
		return
	}
	if spec.pathArg != "" {
		v, _ := args[spec.pathArg].(string)
		if v == "" {
			s.toolError(req.ID, fmt.Sprintf("missing required argument %q", spec.pathArg))
			return
		}
		// path param goes raw under the endpoint; encode path-safe characters only.
		u.Path = strings.TrimRight(u.Path, "/") + "/" + v
	}
	if len(spec.queryArgs) > 0 {
		q := u.Query()
		for _, k := range spec.queryArgs {
			if raw, ok := args[k]; ok {
				q.Set(k, argToString(raw))
			}
		}
		u.RawQuery = q.Encode()
	}

	// Build request.
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	var body io.Reader
	if spec.method == "POST" {
		payload := args
		if !spec.bodyAll {
			payload = map[string]any{}
			for _, k := range spec.bodyArgs {
				if v, ok := args[k]; ok {
					payload[k] = v
				}
			}
		}
		b, err := json.Marshal(payload)
		if err != nil {
			s.toolError(req.ID, "internal: cannot marshal body")
			return
		}
		body = bytes.NewReader(b)
	}
	httpReq, err := http.NewRequestWithContext(ctx, spec.method, u.String(), body)
	if err != nil {
		s.toolError(req.ID, "internal: "+err.Error())
		return
	}
	if body != nil {
		httpReq.Header.Set("Content-Type", "application/json")
	}
	// Forward trace id if caller set one via env.
	if tid := os.Getenv("OCCAM_TRACE_ID"); tid != "" {
		httpReq.Header.Set("X-Trace-Id", tid)
	}

	resp, err := httpClient.Do(httpReq)
	if err != nil {
		s.toolError(req.ID, fmt.Sprintf("gateway unreachable: %v (set OCCAM_API_URL or start the gateway)", err))
		return
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	text := strings.TrimSpace(string(respBody))
	isError := resp.StatusCode >= 400
	if text == "" {
		text = fmt.Sprintf(`{"error": "empty response", "status": %d}`, resp.StatusCode)
	}
	s.writeResult(req.ID, map[string]any{
		"content": []any{map[string]any{"type": "text", "text": text}},
		"isError": isError,
	})
}

// argToString coerces a JSON argument into a string suitable for a URL param.
func argToString(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case bool:
		return strconv.FormatBool(x)
	case float64:
		if x == float64(int64(x)) {
			return strconv.FormatInt(int64(x), 10)
		}
		return strconv.FormatFloat(x, 'f', -1, 64)
	case int:
		return strconv.Itoa(x)
	case int64:
		return strconv.FormatInt(x, 10)
	default:
		b, _ := json.Marshal(v)
		return string(b)
	}
}

// callAnalyze covers both occam_analyze and occam_check.
func (s *server) callAnalyze(req *rpcRequest, args map[string]any, checkMode bool, failOn string) {
	if s.engineScript == "" {
		s.toolError(req.ID, "engine script not found. Set ENGINE_SCRIPT or run occam-mcp from the repo root.")
		return
	}
	path, _ := args["path"].(string)
	if err := validatePath(path); err != nil {
		s.toolError(req.ID, "invalid path: "+err.Error())
		return
	}
	diffMode, _ := args["diff_mode"].(string)
	if diffMode == "" {
		diffMode = "head"
	}
	if diffMode != "head" && diffMode != "staged" && diffMode != "working" {
		s.toolError(req.ID, "invalid diff_mode: "+diffMode)
		return
	}
	if checkMode {
		if failOn == "" {
			failOn = "high"
		}
		switch failOn {
		case "low", "medium", "high", "critical":
		default:
			s.toolError(req.ID, "invalid fail_on: "+failOn)
			return
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), analyzerTimeout)
	defer cancel()

	engineArgs := []string{}
	if checkMode {
		engineArgs = append(engineArgs, "--check", "--fail-on="+failOn)
	} else {
		engineArgs = append(engineArgs, "--json")
	}
	engineArgs = append(engineArgs, "--diff="+diffMode, path)

	cmd := exec.CommandContext(ctx, s.engineScript, engineArgs...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	// Inherit env so the engine sees ENGINE_SCRIPT, OCCAM_DB, trace id, etc.
	cmd.Env = os.Environ()
	runErr := cmd.Run()

	// Exit status extraction (Go-specific): ExitError carries ProcessState.
	exitCode := 0
	if runErr != nil {
		if ee, ok := runErr.(*exec.ExitError); ok {
			exitCode = ee.ExitCode()
		} else {
			s.toolError(req.ID, fmt.Sprintf("engine execution failed: %v (stderr: %s)", runErr, truncate(stderr.String(), 500)))
			return
		}
	}

	// For check mode, exit codes 0 and 1 are both "successful invocations"
	// (0 = passed, 1 = failed gate). 2 = engine error, 3 = bad args.
	if checkMode {
		if exitCode != 0 && exitCode != 1 {
			s.toolError(req.ID, fmt.Sprintf("engine error (exit=%d): %s", exitCode, truncate(stderr.String(), 500)))
			return
		}
	} else if exitCode != 0 {
		// For analyze mode only success (0) is OK. A valid-JSON-with-error
		// payload still surfaces in stdout — we forward it with isError=true.
		if !isValidJSON(stdout.Bytes()) {
			s.toolError(req.ID, fmt.Sprintf("engine failed (exit=%d): %s", exitCode, truncate(stderr.String(), 500)))
			return
		}
	}

	// Wrap the raw telemetry JSON in an MCP content block. Clients render
	// text/* blocks inline; the downstream LLM can parse the JSON directly.
	payload := stdout.String()
	if checkMode {
		payload = fmt.Sprintf(`{"passed":%t,"exit_code":%d,"fail_on":%q,"result":%s}`,
			exitCode == 0, exitCode, failOn, strings.TrimSpace(stdout.String()))
	}
	s.writeResult(req.ID, map[string]any{
		"content": []any{
			map[string]any{"type": "text", "text": payload},
		},
		"isError": false,
	})
}

func (s *server) callTrend(req *rpcRequest, args map[string]any) {
	if s.dbPath == "" {
		s.toolError(req.ID, "cannot resolve OCCAM_DB path")
		return
	}
	if _, err := os.Stat(s.dbPath); err != nil {
		s.toolError(req.ID, "no snapshots yet: "+s.dbPath)
		return
	}
	if _, err := exec.LookPath("sqlite3"); err != nil {
		s.toolError(req.ID, "sqlite3 CLI not installed")
		return
	}

	limit := 100
	if v, ok := args["limit"]; ok {
		switch n := v.(type) {
		case float64:
			limit = int(n)
		case int:
			limit = n
		case string:
			if p, err := strconv.Atoi(n); err == nil {
				limit = p
			}
		}
	}
	if limit < 1 || limit > defaultTrendCap {
		s.toolError(req.ID, fmt.Sprintf("limit must be 1..%d", defaultTrendCap))
		return
	}

	target, _ := args["target"].(string)
	since, _ := args["since"].(string)

	var where []string
	if target != "" {
		where = append(where, "target = "+sqlLit(target))
	}
	if since != "" {
		where = append(where, "ts >= "+sqlLit(since))
	}
	q := "SELECT id, ts, target, branch, commit_sha, health_score, " +
		"security_violations, mass_insertions, mass_deletions, mass_files_changed, " +
		"entropy_nodes, test_files_modified, debt_issues, check_level, diff_mode " +
		"FROM snapshots"
	if len(where) > 0 {
		q += " WHERE " + strings.Join(where, " AND ")
	}
	q += " ORDER BY id DESC LIMIT " + strconv.Itoa(limit) + ";"

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "sqlite3", "-readonly", "-json", s.dbPath, q)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		s.toolError(req.ID, fmt.Sprintf("query failed: %v (%s)", err, truncate(stderr.String(), 200)))
		return
	}
	out := strings.TrimSpace(stdout.String())
	if out == "" {
		out = "[]"
	}
	s.writeResult(req.ID, map[string]any{
		"content": []any{map[string]any{"type": "text", "text": out}},
		"isError": false,
	})
}

func (s *server) callValidate(req *rpcRequest, args map[string]any) {
	if s.engineScript == "" {
		s.toolError(req.ID, "engine script not found")
		return
	}
	engineArgs := []string{"--validate"}
	if cfg, _ := args["config_path"].(string); cfg != "" {
		if strings.HasPrefix(cfg, "-") {
			s.toolError(req.ID, "config_path cannot start with '-'")
			return
		}
		engineArgs = append(engineArgs, "--config", cfg)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, s.engineScript, engineArgs...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	exitCode := 0
	if err := cmd.Run(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			exitCode = ee.ExitCode()
		} else {
			s.toolError(req.ID, "validate failed: "+err.Error())
			return
		}
	}
	resp := map[string]any{
		"valid":     exitCode == 0,
		"exit_code": exitCode,
		"stderr":    truncate(stderr.String(), 2000),
	}
	raw, _ := json.Marshal(resp)
	s.writeResult(req.ID, map[string]any{
		"content": []any{map[string]any{"type": "text", "text": string(raw)}},
		"isError": exitCode != 0,
	})
}

func (s *server) callHealth(req *rpcRequest) {
	status := map[string]any{
		"engine_script": s.engineScript,
		"db_path":       s.dbPath,
		"deps":          probeDeps(),
		"server": map[string]any{
			"name":    serverName,
			"version": serverVersion,
		},
	}
	raw, _ := json.Marshal(status)
	s.writeResult(req.ID, map[string]any{
		"content": []any{map[string]any{"type": "text", "text": string(raw)}},
		"isError": false,
	})
}

// ── Helpers ──────────────────────────────────────────────────────────────────

func probeDeps() map[string]any {
	deps := map[string]string{
		"git":     "git",
		"bash":    "bash",
		"jq":      "jq",
		"sqlite3": "sqlite3",
		"python3": "python3",
		"semgrep": "semgrep",
	}
	out := map[string]any{}
	for name, bin := range deps {
		if p, err := exec.LookPath(bin); err == nil {
			out[name] = map[string]any{"available": true, "path": p}
		} else {
			out[name] = map[string]any{"available": false}
		}
	}
	return out
}

func validatePath(p string) error {
	if p == "" {
		return errors.New("path is required")
	}
	if strings.HasPrefix(p, "-") {
		return errors.New("path must not start with '-'")
	}
	abs, err := filepath.Abs(p)
	if err != nil {
		return err
	}
	info, err := os.Stat(abs)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return errors.New("path is not a directory")
	}
	return nil
}

func resolveEngineScript() string {
	if p := os.Getenv("ENGINE_SCRIPT"); p != "" {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	// Probe relative to the binary and to CWD.
	candidates := []string{}
	if exe := mustExePath(); exe != "" {
		candidates = append(candidates,
			filepath.Join(filepath.Dir(exe), "..", "telemetry_observer.sh"),
			filepath.Join(filepath.Dir(exe), "telemetry_observer.sh"),
		)
	}
	if cwd, err := os.Getwd(); err == nil {
		candidates = append(candidates,
			filepath.Join(cwd, "telemetry_observer.sh"),
			filepath.Join(cwd, "..", "telemetry_observer.sh"),
		)
	}
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	return ""
}

func resolveDBPath() string {
	if p := os.Getenv("OCCAM_DB"); p != "" {
		return p
	}
	base := os.Getenv("XDG_DATA_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return ""
		}
		base = filepath.Join(home, ".local", "share")
	}
	return filepath.Join(base, "occam-observer", "snapshots.db")
}

func mustExePath() string {
	p, err := os.Executable()
	if err != nil {
		return ""
	}
	return p
}

func sqlLit(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

func isValidJSON(b []byte) bool {
	var v any
	return json.Unmarshal(bytes.TrimSpace(b), &v) == nil
}

func truncate(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

// ── Transport ────────────────────────────────────────────────────────────────

func (s *server) writeResult(id json.RawMessage, result any) {
	if id == nil {
		return // notification — no response per JSON-RPC 2.0
	}
	s.write(rpcResponse{JSONRPC: "2.0", ID: id, Result: result})
}

func (s *server) writeError(id json.RawMessage, code int, msg string, data any) {
	s.write(rpcResponse{JSONRPC: "2.0", ID: id, Error: &rpcError{Code: code, Message: msg, Data: data}})
}

// toolError is a tool-level error: JSON-RPC succeeds (Result set), but the
// MCP content envelope carries isError=true. This is the protocol-correct
// way to report an expected tool failure (e.g. bad path) vs a transport error.
func (s *server) toolError(id json.RawMessage, msg string) {
	s.writeResult(id, map[string]any{
		"content": []any{map[string]any{"type": "text", "text": msg}},
		"isError": true,
	})
}

func (s *server) write(resp rpcResponse) {
	s.outMu.Lock()
	defer s.outMu.Unlock()
	b, err := json.Marshal(resp)
	if err != nil {
		log.Printf("marshal response: %v", err)
		return
	}
	s.out.Write(b)
	s.out.WriteByte('\n')
	if err := s.out.Flush(); err != nil {
		log.Printf("stdout flush: %v", err)
	}
}
