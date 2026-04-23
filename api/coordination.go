package main

// Coordination API — endpoints designed for multi-agent coding systems that
// need a shared source of truth for repo context, code structure, and agent
// activity. Full design doc: docs/guide/coordination-api.md.
//
// Scope v1:
//   - Git-backed reads    (repo context, blame, churn, diff, fingerprint)
//   - Agent coordination  (observations, claims) — new SQLite tables
//   - Python AST          (imports, exports, symbol) via analyzers/python-symbol-index.py
//   - Stubs (HTTP 501)    for endpoints that need cross-cutting integration
//                         (test-runs, frozen-regions, cross-file symbol index)

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// ── Schema bootstrap ─────────────────────────────────────────────────────────

// initCoordinationDB creates the observations + claims tables if missing.
// Idempotent. Safe to call from multiple processes: sqlite3 CREATE IF NOT
// EXISTS is atomic.
func initCoordinationDB(dbPath string) error {
	if dbPath == "" {
		return errors.New("empty db path")
	}
	if err := os.MkdirAll(filepath.Dir(dbPath), 0o755); err != nil {
		return err
	}
	if _, err := exec.LookPath("sqlite3"); err != nil {
		return err // degrade silently upstream
	}
	ddl := `
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;

CREATE TABLE IF NOT EXISTS observations (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    ts            TEXT NOT NULL,
    run_id        TEXT NOT NULL,
    agent         TEXT NOT NULL,
    subtask_id    TEXT,
    model         TEXT,
    branch        TEXT,
    commit_sha    TEXT,
    outcome       TEXT NOT NULL,
    touched_files TEXT,  -- JSON array
    failure_modes TEXT,  -- JSON array
    confidence    REAL,
    extra         TEXT,  -- JSON object
    raw_json      TEXT
);
CREATE INDEX IF NOT EXISTS idx_obs_ts     ON observations(ts DESC);
CREATE INDEX IF NOT EXISTS idx_obs_run    ON observations(run_id);
CREATE INDEX IF NOT EXISTS idx_obs_commit ON observations(commit_sha);
CREATE INDEX IF NOT EXISTS idx_obs_agent  ON observations(agent);

CREATE TABLE IF NOT EXISTS claims (
    lock_id    TEXT PRIMARY KEY,
    path       TEXT NOT NULL UNIQUE,
    agent      TEXT NOT NULL,
    run_id     TEXT,
    acquired   TEXT NOT NULL,
    expires_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_claims_exp ON claims(expires_at);
`
	cmd := exec.Command("sqlite3", dbPath)
	cmd.Stdin = strings.NewReader(ddl)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("ddl: %w (%s)", err, stderr.String())
	}
	return nil
}

// ── Registration ─────────────────────────────────────────────────────────────

func registerCoordinationRoutes() {
	// Git-backed reads
	http.HandleFunc("/repo/context",     withTraceID(handleRepoContext))
	http.HandleFunc("/repo/fingerprint", withTraceID(handleRepoFingerprint))
	http.HandleFunc("/repo/blame/",      withTraceID(handleRepoBlame))   // prefix match: /repo/blame/<path>
	http.HandleFunc("/repo/churn/",      withTraceID(handleRepoChurn))   // prefix match
	http.HandleFunc("/diff",             withTraceID(handleDiff))
	http.HandleFunc("/file/fingerprint", withTraceID(handleFileFingerprint))
	http.HandleFunc("/agent/identity/",  withTraceID(handleAgentIdentity)) // prefix match

	// State-backed
	http.HandleFunc("/observation",    withTraceID(handleObservation))     // POST
	http.HandleFunc("/repo/agent-log", withTraceID(handleAgentLog))
	http.HandleFunc("/claim",          withTraceID(handleClaim))           // GET/POST/DELETE

	// Python AST
	http.HandleFunc("/file/imports",  withTraceID(handleFileImports))
	http.HandleFunc("/file/exports",  withTraceID(handleFileExports))
	http.HandleFunc("/symbol",        withTraceID(handleSymbol))

	// Documented stubs
	http.HandleFunc("/repo/test-map",        withTraceID(stubHandler("needs test-runner integration (pytest/jest/go test)")))
	http.HandleFunc("/repo/failing-tests",   withTraceID(stubHandler("needs test-runner integration")))
	http.HandleFunc("/file/frozen-regions",  withTraceID(stubHandler("needs frozen-region contract design (inline markers vs .occam-frozen.yml)")))
	http.HandleFunc("/file/last-safe",       withTraceID(stubHandler("needs test-runs history")))
	http.HandleFunc("/run/",                 withTraceID(stubHandler("needs test-runs history")))   // /run/:id/tests/delta
	http.HandleFunc("/scorecard/",           withTraceID(stubHandler("needs bench-ladder integration")))
	http.HandleFunc("/contract",             withTraceID(handleContract)) // partial, not stub
}

func stubHandler(reason string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNotImplemented)
		body, _ := json.Marshal(map[string]string{
			"status": "not_implemented",
			"reason": reason,
			"path":   r.URL.Path,
		})
		w.Write(body)
	}
}

// ── Shared helpers ───────────────────────────────────────────────────────────

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(body)
}

// requireTargetRepo validates a ?target= query param as an existing git repo.
// On error writes the response and returns "" so callers can just early-return.
func requireTargetRepo(w http.ResponseWriter, r *http.Request) string {
	t := r.URL.Query().Get("target")
	abs, err := validateTargetPath(t)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid target: "+err.Error(), "")
		return ""
	}
	if _, err := os.Stat(filepath.Join(abs, ".git")); err != nil {
		writeJSONError(w, http.StatusBadRequest, "target is not a git repository", abs)
		return ""
	}
	return abs
}

// requireAbsFile validates a ?path= query param (absolute file that exists).
func requireAbsFile(w http.ResponseWriter, r *http.Request) string {
	p := r.URL.Query().Get("path")
	if p == "" {
		writeJSONError(w, http.StatusBadRequest, "missing 'path' query parameter", "")
		return ""
	}
	if strings.HasPrefix(p, "-") {
		writeJSONError(w, http.StatusBadRequest, "path must not start with '-'", "")
		return ""
	}
	abs, err := filepath.Abs(p)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "cannot resolve path", err.Error())
		return ""
	}
	info, err := os.Stat(abs)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "path does not exist", "")
		return ""
	}
	if info.IsDir() {
		writeJSONError(w, http.StatusBadRequest, "path is a directory", "")
		return ""
	}
	return abs
}

// gitRun executes `git -C target args...` with a timeout.
func gitRun(ctx context.Context, target string, args ...string) ([]byte, error) {
	full := append([]string{"-C", target}, args...)
	cmd := exec.CommandContext(ctx, "git", full...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("git %s: %w (%s)", strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return stdout.Bytes(), nil
}

// parseDuration accepts forms like "24h", "7d", "30m" and returns a
// time.Duration. "d" is custom (Go's native time.Duration tops out at "h").
func parseDuration(s string) (time.Duration, error) {
	if s == "" {
		return 0, nil
	}
	if strings.HasSuffix(s, "d") {
		days, err := strconv.Atoi(strings.TrimSuffix(s, "d"))
		if err != nil {
			return 0, err
		}
		return time.Duration(days) * 24 * time.Hour, nil
	}
	return time.ParseDuration(s)
}

// sqliteExecJSON runs a SQL query with sqlite3 -json and unmarshals the
// result into the provided interface. Returns an empty slice when sqlite3
// emits nothing (no rows).
func sqliteExecJSON(ctx context.Context, dbPath, query string, out any) error {
	if _, err := exec.LookPath("sqlite3"); err != nil {
		return errors.New("sqlite3 CLI not installed")
	}
	cmd := exec.CommandContext(ctx, "sqlite3", "-readonly", "-json", dbPath, query)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("sqlite3: %w (%s)", err, strings.TrimSpace(stderr.String()))
	}
	body := bytes.TrimSpace(stdout.Bytes())
	if len(body) == 0 {
		return nil
	}
	return json.Unmarshal(body, out)
}

// sqliteExec runs a write-path statement. Uses stdin-mode so strings with
// newlines / quotes don't fight the shell.
func sqliteExec(ctx context.Context, dbPath, sql string) error {
	cmd := exec.CommandContext(ctx, "sqlite3", dbPath)
	cmd.Stdin = strings.NewReader(sql)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("sqlite3 exec: %w (%s)", err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

// ── /repo/context ────────────────────────────────────────────────────────────

// extensionLanguage maps a lowercase extension to a human-readable language.
// Small on purpose — anything not here aggregates to the extension itself.
var extensionLanguage = map[string]string{
	".go":    "Go",
	".py":    "Python",
	".js":    "JavaScript",
	".jsx":   "JavaScript",
	".ts":    "TypeScript",
	".tsx":   "TypeScript",
	".rs":    "Rust",
	".java":  "Java",
	".kt":    "Kotlin",
	".rb":    "Ruby",
	".php":   "PHP",
	".c":     "C",
	".h":     "C",
	".cpp":   "C++",
	".cc":    "C++",
	".hpp":   "C++",
	".cs":    "C#",
	".sh":    "Shell",
	".bash":  "Shell",
	".html":  "HTML",
	".css":   "CSS",
	".scss":  "SCSS",
	".md":    "Markdown",
	".yml":   "YAML",
	".yaml":  "YAML",
	".json":  "JSON",
	".toml":  "TOML",
	".sql":   "SQL",
}

// detectStack returns identifiers for the build systems visible in the repo.
func detectStack(target string) []string {
	stack := []string{}
	exists := func(rel string) bool {
		_, err := os.Stat(filepath.Join(target, rel))
		return err == nil
	}
	// python
	switch {
	case exists("pyproject.toml"):
		if body, err := os.ReadFile(filepath.Join(target, "pyproject.toml")); err == nil {
			switch {
			case bytes.Contains(body, []byte("[tool.poetry]")):
				stack = append(stack, "python/poetry")
			case bytes.Contains(body, []byte("[tool.hatch")):
				stack = append(stack, "python/hatch")
			default:
				stack = append(stack, "python")
			}
		} else {
			stack = append(stack, "python")
		}
	case exists("requirements.txt") || exists("requirements-dev.txt"):
		stack = append(stack, "python/pip")
	}
	if exists("go.mod") {
		stack = append(stack, "go")
	}
	if exists("package.json") {
		stack = append(stack, "npm")
	}
	if exists("Cargo.toml") {
		stack = append(stack, "rust/cargo")
	}
	if exists("Dockerfile") || exists("dockerfile") {
		stack = append(stack, "docker")
	}
	if exists("docker-compose.yml") || exists("docker-compose.yaml") || exists("compose.yml") {
		stack = append(stack, "docker-compose")
	}
	if _, err := os.Stat(filepath.Join(target, ".github", "workflows")); err == nil {
		stack = append(stack, "github-actions")
	}
	if exists("Makefile") {
		stack = append(stack, "make")
	}
	sort.Strings(stack)
	return stack
}

func handleRepoContext(w http.ResponseWriter, r *http.Request) {
	target := requireTargetRepo(w, r)
	if target == "" {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	// Languages via `git ls-files` (only tracked content).
	out, err := gitRun(ctx, target, "ls-files", "-z")
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "git ls-files failed", err.Error())
		return
	}
	type langAgg struct{ files, bytes int64 }
	agg := map[string]*langAgg{}
	for _, name := range bytes.Split(out, []byte{0}) {
		if len(name) == 0 {
			continue
		}
		ext := strings.ToLower(filepath.Ext(string(name)))
		lang := extensionLanguage[ext]
		if lang == "" {
			if ext == "" {
				continue
			}
			lang = strings.TrimPrefix(ext, ".")
		}
		if _, ok := agg[lang]; !ok {
			agg[lang] = &langAgg{}
		}
		agg[lang].files++
		if info, err := os.Stat(filepath.Join(target, string(name))); err == nil && !info.IsDir() {
			agg[lang].bytes += info.Size()
		}
	}
	type langOut struct {
		Name  string `json:"name"`
		Files int64  `json:"files"`
		Bytes int64  `json:"bytes"`
	}
	langs := make([]langOut, 0, len(agg))
	for k, v := range agg {
		langs = append(langs, langOut{Name: k, Files: v.files, Bytes: v.bytes})
	}
	sort.Slice(langs, func(i, j int) bool {
		if langs[i].Files != langs[j].Files {
			return langs[i].Files > langs[j].Files
		}
		return langs[i].Name < langs[j].Name
	})

	// Churn over the last 7 days via `git log --since=... --numstat --format='%H'`.
	const churnDays = 7
	since := fmt.Sprintf("%d.days.ago", churnDays)
	out, err = gitRun(ctx, target, "log", "--since="+since, "--numstat", "--format=--COMMIT--%H")
	type churnFile struct {
		Path    string `json:"path"`
		Changes int64  `json:"changes"`
	}
	ins, del, filesTouched := int64(0), int64(0), map[string]int64{}
	if err == nil {
		for _, line := range strings.Split(string(out), "\n") {
			if strings.HasPrefix(line, "--COMMIT--") || line == "" {
				continue
			}
			parts := strings.Fields(line)
			if len(parts) < 3 {
				continue
			}
			a, _ := strconv.ParseInt(parts[0], 10, 64) // "-" on binary files
			d, _ := strconv.ParseInt(parts[1], 10, 64)
			ins += a
			del += d
			filesTouched[parts[2]] += a + d
		}
	}
	// Hot files: top 10 by total churn lines.
	hot := make([]churnFile, 0, len(filesTouched))
	for p, c := range filesTouched {
		hot = append(hot, churnFile{Path: p, Changes: c})
	}
	sort.Slice(hot, func(i, j int) bool { return hot[i].Changes > hot[j].Changes })
	if len(hot) > 10 {
		hot = hot[:10]
	}

	// Stable files: tracked files whose last commit is older than 90 days.
	type stable struct {
		Path        string `json:"path"`
		LastTouched string `json:"last_touched"`
	}
	stables := []stable{}
	cutoff := time.Now().AddDate(0, 0, -90)
	trackedLimit := 5000 // cap the walk on pathological repos
	trackedCount := 0
	out, _ = gitRun(ctx, target, "ls-files", "-z")
	for _, name := range bytes.Split(out, []byte{0}) {
		if len(name) == 0 {
			continue
		}
		trackedCount++
		if trackedCount > trackedLimit {
			break
		}
		lt, err := gitRun(ctx, target, "log", "-1", "--format=%cI", "--", string(name))
		if err != nil {
			continue
		}
		s := strings.TrimSpace(string(lt))
		if s == "" {
			continue
		}
		t, err := time.Parse(time.RFC3339, s)
		if err != nil {
			continue
		}
		if t.Before(cutoff) {
			stables = append(stables, stable{Path: string(name), LastTouched: s})
		}
	}
	if len(stables) > 20 {
		stables = stables[:20]
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"target":    target,
		"languages": langs,
		"stack":     detectStack(target),
		"recent_churn": map[string]any{
			"since_days":    churnDays,
			"insertions":    ins,
			"deletions":     del,
			"files_touched": len(filesTouched),
		},
		"hot_files":    hot,
		"stable_files": stables,
	})
}

// ── /repo/fingerprint ────────────────────────────────────────────────────────
//
// Stable, content-grounding "what is this repo" snapshot for coding agents
// that need to validate doc/config content against actual repo reality
// (anti-hallucination guard). Deliberately SEPARATE from /repo/context
// (which focuses on churn + recency): a fingerprint is time-invariant
// given a commit — same HEAD → same answer, regardless of when asked.
//
// Response shape:
//   {
//     "target":              "/abs/path",
//     "commit_sha":          "abc123…",
//     "computed_at":         "2026-04-23T22:15:00Z",
//     "languages":           [{"name":"Rust","files":47}, …],  // sorted by files desc
//     "stack":               ["rust/cargo","github-actions"],
//     "declared_deps":       {"rust":["clap","serde",…], "npm":[], …},
//     "declared_frameworks": ["clap"],    // canonical names, sorted
//     "entrypoints":         ["src/main.rs"],
//     "manifest_files":      ["Cargo.toml"]
//   }
//
// Silent-fail on per-manifest parse errors — the fingerprint is a best-
// effort read, not a validator. An unparseable Cargo.toml yields an empty
// "rust" deps list; other languages still compute.

// depToFramework maps a declared dep name to a canonical framework
// identifier. Small on purpose — extend only when a new framework
// genuinely helps ground content (e.g. doc cites "React" in a Rust
// repo). Keys are case-insensitive (lowercased before lookup).
var depToFramework = map[string]string{
	// Frontend (JS/TS)
	"react":             "react",
	"preact":            "preact",
	"vue":               "vue",
	"@vue/cli":          "vue",
	"svelte":            "svelte",
	"@angular/core":     "angular",
	"solid-js":          "solid",
	"lit":               "lit",
	// Meta-frameworks
	"next":              "next",
	"nuxt":              "nuxt",
	"@sveltejs/kit":     "sveltekit",
	"@remix-run/react":  "remix",
	"gatsby":            "gatsby",
	"astro":             "astro",
	// State
	"redux":             "redux",
	"@reduxjs/toolkit":  "redux",
	"zustand":           "zustand",
	"mobx":              "mobx",
	"jotai":             "jotai",
	"pinia":             "pinia",
	// Node backend
	"express":           "express",
	"fastify":           "fastify",
	"koa":               "koa",
	"@nestjs/core":      "nestjs",
	"hapi":              "hapi",
	// UI libs
	"tailwindcss":       "tailwindcss",
	"@mui/material":     "mui",
	"@chakra-ui/react":  "chakra",
	"antd":              "antd",
	"bootstrap":         "bootstrap",
	// Python web
	"django":            "django",
	"flask":             "flask",
	"fastapi":           "fastapi",
	"starlette":         "starlette",
	"tornado":           "tornado",
	"bottle":            "bottle",
	// Python CLI
	"click":             "click",
	"typer":             "typer",
	// Python data
	"sqlalchemy":        "sqlalchemy",
	"pydantic":          "pydantic",
	// Go
	"github.com/gin-gonic/gin": "gin",
	"github.com/labstack/echo": "echo",
	"github.com/gofiber/fiber": "fiber",
	"github.com/go-chi/chi":    "chi",
	"github.com/spf13/cobra":   "cobra",
	"github.com/urfave/cli":    "urfave-cli",
	// Rust
	"actix-web":         "actix",
	"rocket":            "rocket",
	"axum":              "axum",
	"warp":              "warp",
	"tide":              "tide",
	"poem":              "poem",
	"clap":              "clap",
	"structopt":         "structopt",
	"tokio":             "tokio",
	"serde":             "serde",
	// Test runners
	"jest":              "jest",
	"vitest":            "vitest",
	"mocha":             "mocha",
	"pytest":            "pytest",
}

// inferFrameworks maps each lang's dep-name list through
// depToFramework. Deduped + sorted so the output is stable for
// golden tests.
func inferFrameworks(deps map[string][]string) []string {
	seen := map[string]struct{}{}
	for _, names := range deps {
		for _, n := range names {
			if fw, ok := depToFramework[strings.ToLower(n)]; ok {
				seen[fw] = struct{}{}
			}
		}
	}
	out := make([]string, 0, len(seen))
	for k := range seen {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// cargoDepSection matches section headers we treat as cargo deps
// sources. Target-specific deps (``[target.'cfg(unix)'.dependencies]``)
// are included too — their presence is just as informative for G11.
var cargoDepSection = regexp.MustCompile(`^\s*\[(?:dependencies|dev-dependencies|build-dependencies|target\..+\.dependencies|workspace\.dependencies)\]\s*$`)
var cargoDepLine = regexp.MustCompile(`^\s*([A-Za-z0-9_][A-Za-z0-9_-]*)\s*=`)
var tomlSectionHeader = regexp.MustCompile(`^\s*\[[^]]+\]\s*$`)

// readCargoDeps collects dep NAMES from a Cargo.toml. Returns an
// empty slice when the file is missing or unparseable.
func readCargoDeps(target string) []string {
	body, err := os.ReadFile(filepath.Join(target, "Cargo.toml"))
	if err != nil {
		return []string{}
	}
	out := []string{}
	seen := map[string]struct{}{}
	inSection := false
	for _, line := range strings.Split(string(body), "\n") {
		if tomlSectionHeader.MatchString(line) {
			inSection = cargoDepSection.MatchString(line)
			continue
		}
		if !inSection {
			continue
		}
		if m := cargoDepLine.FindStringSubmatch(line); m != nil {
			name := m[1]
			if _, dup := seen[name]; !dup {
				seen[name] = struct{}{}
				out = append(out, name)
			}
		}
	}
	sort.Strings(out)
	return out
}

// readNpmDeps collects dep NAMES from package.json (dependencies,
// devDependencies, peerDependencies, optionalDependencies).
func readNpmDeps(target string) []string {
	body, err := os.ReadFile(filepath.Join(target, "package.json"))
	if err != nil {
		return []string{}
	}
	var pkg struct {
		Dependencies         map[string]any `json:"dependencies"`
		DevDependencies      map[string]any `json:"devDependencies"`
		PeerDependencies     map[string]any `json:"peerDependencies"`
		OptionalDependencies map[string]any `json:"optionalDependencies"`
	}
	if err := json.Unmarshal(body, &pkg); err != nil {
		return []string{}
	}
	seen := map[string]struct{}{}
	for _, m := range []map[string]any{pkg.Dependencies, pkg.DevDependencies, pkg.PeerDependencies, pkg.OptionalDependencies} {
		for k := range m {
			seen[k] = struct{}{}
		}
	}
	out := make([]string, 0, len(seen))
	for k := range seen {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// pyDepString extracts the leading package name from a PEP 508
// requirement string: ``django>=4.2; python_version>='3.9'`` → ``django``.
// Accepts ``name[extra]`` and strips the extras bracket.
var pyDepRe = regexp.MustCompile(`^\s*([A-Za-z_][A-Za-z0-9_.-]*)`)

func parsePyDep(s string) string {
	if m := pyDepRe.FindStringSubmatch(s); m != nil {
		return strings.ToLower(m[1])
	}
	return ""
}

// stripTomlComment removes a trailing ``# ...`` comment from a TOML
// line. The naive ``strings.Index("#")`` is wrong because ``#`` can
// appear inside a string value (``tag = "#anchor"``). We walk the
// line, toggle an in-string flag on matching quotes, and cut at the
// first unquoted ``#``.
//
// Why it matters for fingerprint: PEP 621 ``dependencies = [...]``
// arrays may include comment lines that contain ``[...]`` (e.g. the
// gitoma pyproject notes ``# ...the ``[all]`` extra was dropped``).
// Without stripping, the ``]`` inside the comment is treated as the
// end of the deps array and we lose half the deps.
func stripTomlComment(line string) string {
	inStr := false
	var q byte
	b := []byte(line)
	for i := 0; i < len(b); i++ {
		c := b[i]
		if inStr {
			if c == q {
				inStr = false
			}
			continue
		}
		if c == '"' || c == '\'' {
			inStr = true
			q = c
			continue
		}
		if c == '#' {
			return string(b[:i])
		}
	}
	return line
}

// readPyprojectDeps handles three shapes:
//
//   1. PEP 621 modern: ``[project]`` → ``dependencies = ["django>=4"]``
//      + ``[project.optional-dependencies]`` tables.
//   2. Poetry: ``[tool.poetry.dependencies]`` → ``django = "^4"``.
//   3. requirements.txt fallback when pyproject.toml absent.
//
// Returns deduped + sorted list.
func readPyprojectDeps(target string) []string {
	seen := map[string]struct{}{}
	add := func(name string) {
		if name != "" && name != "python" {
			seen[name] = struct{}{}
		}
	}
	// addItem normalises a single split fragment from a deps array:
	// trims whitespace + surrounding quotes, strips the PEP 508 ``[extra]``
	// suffix, then runs parsePyDep on what's left.
	addItem := func(raw string) {
		s := strings.Trim(strings.TrimSpace(raw), `"'`)
		if s == "" {
			return
		}
		if br := strings.Index(s, "["); br >= 0 {
			s = s[:br]
		}
		add(parsePyDep(s))
	}
	// findArrayCloseBalanced returns the index in ``s`` where the
	// running bracket balance (starting at ``startDepth``) reaches 0
	// from a ``]``. Returns -1 if the array does not close inside ``s``.
	// Used to slice exactly the ``[…]`` content of an inline deps array
	// without falling for nested ``[extra]`` markers in dep VALUES like
	// ``"mcp[cli]>=1.0"``.
	findArrayCloseBalanced := func(s string, startDepth int) int {
		depth := startDepth
		for i, c := range s {
			if c == '[' {
				depth++
			} else if c == ']' {
				depth--
				if depth == 0 {
					return i
				}
			}
		}
		return -1
	}
	if body, err := os.ReadFile(filepath.Join(target, "pyproject.toml")); err == nil {
		lines := strings.Split(string(body), "\n")
		// Modes: "" (none), "project.deps" (array in progress), "poetry.deps" (table)
		mode := ""
		inOptDeps := false
		// Bracket-depth tracker for the in-progress ``project.deps`` array.
		// Required because dep VALUES like ``"mcp[cli]>=1.0"`` contain ``]``
		// inside the string — a naive ``Contains(line, "]")`` would close
		// the array half-way through and lose every dep after it.
		depth := 0
		for _, raw := range lines {
			// Strip TOML comments BEFORE any parsing — ``]`` or ``[`` inside
			// a comment must never drive mode transitions. Section header
			// detection also runs on the stripped form so a trailing
			// ``[section] # with [brackets]`` still matches.
			line := stripTomlComment(raw)
			trim := strings.TrimSpace(line)
			// Section transitions.
			if tomlSectionHeader.MatchString(line) {
				hdr := strings.TrimSpace(trim)
				mode = ""
				inOptDeps = false
				depth = 0
				switch {
				case hdr == "[tool.poetry.dependencies]" || hdr == "[tool.poetry.dev-dependencies]" || strings.HasPrefix(hdr, "[tool.poetry.group.") && strings.HasSuffix(hdr, ".dependencies]"):
					mode = "poetry.deps"
				case hdr == "[project]":
					mode = "project"
				case hdr == "[project.optional-dependencies]":
					inOptDeps = true
				}
				continue
			}
			// Shape 1: PEP 621 [project] dependencies array.
			if mode == "project" && strings.HasPrefix(trim, "dependencies") {
				if idx := strings.Index(line, "["); idx >= 0 {
					mode = "project.deps"
					depth = 1
					rest := line[idx+1:]
					content := rest
					if end := findArrayCloseBalanced(rest, depth); end >= 0 {
						// inline array — slice exactly the array body.
						content = rest[:end]
						depth = 0
					} else {
						depth += strings.Count(rest, "[") - strings.Count(rest, "]")
					}
					for _, item := range strings.Split(content, ",") {
						addItem(item)
					}
					if depth <= 0 {
						mode = "project"
						depth = 0
					}
				}
				continue
			}
			if mode == "project.deps" {
				content := line
				if end := findArrayCloseBalanced(line, depth); end >= 0 {
					content = line[:end]
					depth = 0
				} else {
					depth += strings.Count(line, "[") - strings.Count(line, "]")
				}
				for _, item := range strings.Split(content, ",") {
					addItem(item)
				}
				if depth <= 0 {
					mode = "project"
					depth = 0
				}
				continue
			}
			// Shape: [project.optional-dependencies] → one array per extra.
			if inOptDeps {
				// inline arrays only (multi-line is rare in this section).
				if idx := strings.Index(line, "["); idx >= 0 {
					rest := line[idx+1:]
					if end := findArrayCloseBalanced(rest, 1); end >= 0 {
						for _, item := range strings.Split(rest[:end], ",") {
							addItem(item)
						}
					}
				}
				continue
			}
			// Shape 2: Poetry deps table — ``name = "^1.0"`` or ``name = {...}``.
			if mode == "poetry.deps" {
				if m := cargoDepLine.FindStringSubmatch(line); m != nil {
					add(strings.ToLower(m[1]))
				}
				continue
			}
		}
	} else {
		// Fallback: requirements.txt
		for _, fname := range []string{"requirements.txt", "requirements-dev.txt"} {
			if body, err := os.ReadFile(filepath.Join(target, fname)); err == nil {
				for _, line := range strings.Split(string(body), "\n") {
					trim := strings.TrimSpace(line)
					if trim == "" || strings.HasPrefix(trim, "#") || strings.HasPrefix(trim, "-") {
						continue
					}
					add(parsePyDep(trim))
				}
			}
		}
	}
	out := make([]string, 0, len(seen))
	for k := range seen {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// readGoModDeps collects module paths from go.mod require blocks.
// Handles both ``require x v1`` and multi-line ``require (\n x v1\n)``.
var goModLine = regexp.MustCompile(`^\s*([a-zA-Z0-9_./-]+(?:\.[a-zA-Z0-9_./-]+)+)\s+v`)

func readGoModDeps(target string) []string {
	body, err := os.ReadFile(filepath.Join(target, "go.mod"))
	if err != nil {
		return []string{}
	}
	seen := map[string]struct{}{}
	inBlock := false
	for _, raw := range strings.Split(string(body), "\n") {
		line := strings.TrimSpace(raw)
		if strings.HasPrefix(line, "//") || line == "" {
			continue
		}
		if strings.HasPrefix(line, "require (") {
			inBlock = true
			continue
		}
		if inBlock {
			if line == ")" {
				inBlock = false
				continue
			}
			if m := goModLine.FindStringSubmatch(raw); m != nil {
				seen[m[1]] = struct{}{}
			}
			continue
		}
		if strings.HasPrefix(line, "require ") {
			rest := strings.TrimPrefix(line, "require ")
			if m := goModLine.FindStringSubmatch(" " + rest); m != nil {
				seen[m[1]] = struct{}{}
			}
		}
	}
	out := make([]string, 0, len(seen))
	for k := range seen {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// detectEntrypoints returns well-known program entry files that
// actually exist. Keeps the set small + language-canonical so doc
// grounding can answer "is this a CLI or a server?".
func detectEntrypoints(target string) []string {
	candidates := []string{
		"src/main.rs",
		"main.go",
		"cmd/main.go",
		"src/main.ts",
		"src/index.ts",
		"src/index.js",
		"src/app.ts",
		"src/app.js",
		"main.py",
		"__main__.py",
		"manage.py",
		"wsgi.py",
		"asgi.py",
		"app.py",
	}
	out := []string{}
	for _, c := range candidates {
		if _, err := os.Stat(filepath.Join(target, c)); err == nil {
			out = append(out, c)
		}
	}
	return out
}

// detectManifests returns the subset of well-known manifests that
// exist in the repo root. Helps G11 skip ground-truth claims for
// manifests we didn't see (e.g. doc cites ``package.json`` but there
// isn't one).
func detectManifests(target string) []string {
	candidates := []string{
		"Cargo.toml",
		"package.json",
		"pyproject.toml",
		"requirements.txt",
		"go.mod",
		"Gemfile",
		"composer.json",
		"pom.xml",
		"build.gradle",
		"build.gradle.kts",
		"Dockerfile",
		"Makefile",
	}
	out := []string{}
	for _, c := range candidates {
		if _, err := os.Stat(filepath.Join(target, c)); err == nil {
			out = append(out, c)
		}
	}
	return out
}

// fingerprintLanguages aggregates tracked files by extension to
// their canonical language name. Lighter-weight than the churn+
// stable computation in /repo/context — fingerprint just needs
// "what languages does this repo contain".
func fingerprintLanguages(ctx context.Context, target string) []map[string]any {
	out, err := gitRun(ctx, target, "ls-files", "-z")
	if err != nil {
		return []map[string]any{}
	}
	agg := map[string]int64{}
	for _, name := range bytes.Split(out, []byte{0}) {
		if len(name) == 0 {
			continue
		}
		ext := strings.ToLower(filepath.Ext(string(name)))
		if ext == "" {
			continue
		}
		lang := extensionLanguage[ext]
		if lang == "" {
			lang = strings.TrimPrefix(ext, ".")
		}
		agg[lang]++
	}
	langs := make([]map[string]any, 0, len(agg))
	for k, v := range agg {
		langs = append(langs, map[string]any{"name": k, "files": v})
	}
	sort.Slice(langs, func(i, j int) bool {
		fi, _ := langs[i]["files"].(int64)
		fj, _ := langs[j]["files"].(int64)
		if fi != fj {
			return fi > fj
		}
		return langs[i]["name"].(string) < langs[j]["name"].(string)
	})
	return langs
}

func handleRepoFingerprint(w http.ResponseWriter, r *http.Request) {
	target := requireTargetRepo(w, r)
	if target == "" {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	commitSha := ""
	if out, err := gitRun(ctx, target, "rev-parse", "HEAD"); err == nil {
		commitSha = strings.TrimSpace(string(out))
	}

	deps := map[string][]string{
		"rust":   readCargoDeps(target),
		"npm":    readNpmDeps(target),
		"python": readPyprojectDeps(target),
		"go":     readGoModDeps(target),
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"target":              target,
		"commit_sha":          commitSha,
		"computed_at":         time.Now().UTC().Format(time.RFC3339),
		"languages":           fingerprintLanguages(ctx, target),
		"stack":               detectStack(target),
		"declared_deps":       deps,
		"declared_frameworks": inferFrameworks(deps),
		"entrypoints":         detectEntrypoints(target),
		"manifest_files":      detectManifests(target),
	})
}

// ── /repo/blame/:path ────────────────────────────────────────────────────────

// parsePorcelainBlame extracts {line, commit, author, when} for each blamed line.
func parsePorcelainBlame(raw []byte) []map[string]any {
	rows := []map[string]any{}
	lines := strings.Split(string(raw), "\n")

	type header struct {
		commit string
		author string
		email  string
		when   string
	}
	cache := map[string]header{}
	var cur header
	resLine := 0
	for i := 0; i < len(lines); i++ {
		line := lines[i]
		if line == "" {
			continue
		}
		// A new hunk header: "<sha> <origLine> <resultLine> <count>"
		if matched, _ := regexp.MatchString(`^[0-9a-f]{7,40} \d+ \d+`, line); matched {
			parts := strings.Fields(line)
			if len(parts) < 3 {
				continue
			}
			sha := parts[0]
			resLineStr := parts[2]
			rl, _ := strconv.Atoi(resLineStr)
			resLine = rl
			cur = cache[sha]
			cur.commit = sha
			continue
		}
		if strings.HasPrefix(line, "author ") {
			cur.author = strings.TrimPrefix(line, "author ")
			continue
		}
		if strings.HasPrefix(line, "author-mail ") {
			cur.email = strings.Trim(strings.TrimPrefix(line, "author-mail "), "<>")
			continue
		}
		if strings.HasPrefix(line, "author-time ") {
			sec, _ := strconv.ParseInt(strings.TrimPrefix(line, "author-time "), 10, 64)
			cur.when = time.Unix(sec, 0).UTC().Format(time.RFC3339)
			continue
		}
		if strings.HasPrefix(line, "\t") {
			// content line → emit a row
			cache[cur.commit] = cur // memoize per commit
			rows = append(rows, map[string]any{
				"line":   resLine,
				"commit": cur.commit[:12],
				"author": cur.author,
				"email":  cur.email,
				"when":   cur.when,
			})
		}
	}
	return rows
}

func handleRepoBlame(w http.ResponseWriter, r *http.Request) {
	target := requireTargetRepo(w, r)
	if target == "" {
		return
	}
	// Extract <path> from "/repo/blame/<path>"
	rel := strings.TrimPrefix(r.URL.Path, "/repo/blame/")
	if rel == "" {
		writeJSONError(w, http.StatusBadRequest, "missing file path in URL", "")
		return
	}
	// Defense in depth: prevent "/repo/blame/../etc/passwd" type walk-outs.
	if strings.Contains(rel, "..") {
		writeJSONError(w, http.StatusBadRequest, "'..' not allowed in path", "")
		return
	}
	if _, err := os.Stat(filepath.Join(target, rel)); err != nil {
		writeJSONError(w, http.StatusBadRequest, "file not found in target", rel)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	raw, err := gitRun(ctx, target, "blame", "--porcelain", "--", rel)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "git blame failed", err.Error())
		return
	}
	rows := parsePorcelainBlame(raw)

	// Enrichment: join agent info from observations by commit_sha.
	if dbPath := resolveDBPath(); dbPath != "" {
		if _, err := os.Stat(dbPath); err == nil {
			// Collect unique short shas referenced by rows.
			seen := map[string]bool{}
			for _, row := range rows {
				if s, ok := row["commit"].(string); ok {
					seen[s] = true
				}
			}
			// Query obs by commit prefix.
			for sha := range seen {
				var results []map[string]any
				q := fmt.Sprintf(
					"SELECT agent, run_id FROM observations WHERE commit_sha LIKE '%s%%' ORDER BY id DESC LIMIT 1",
					strings.ReplaceAll(sha, "'", "''"),
				)
				qctx, qcancel := context.WithTimeout(ctx, 2*time.Second)
				_ = sqliteExecJSON(qctx, dbPath, q, &results)
				qcancel()
				if len(results) > 0 {
					for _, row := range rows {
						if row["commit"] == sha {
							row["agent"] = results[0]["agent"]
							row["run_id"] = results[0]["run_id"]
						}
					}
				}
			}
		}
	}

	// Revert detection: cheap pass — look at commit messages in the repo for
	// "^Revert " that mentions any of the blamed shas. O(commits) but
	// capped to last 500 commits for latency.
	revLog, err := gitRun(ctx, target, "log", "-500", "--format=%H%x00%s")
	if err == nil {
		reverts := map[string]string{} // blamed_sha_prefix → reverter_sha
		rePrefix := regexp.MustCompile(`[0-9a-f]{7,40}`)
		for _, line := range strings.Split(string(revLog), "\n") {
			parts := strings.SplitN(line, "\x00", 2)
			if len(parts) != 2 {
				continue
			}
			if !strings.HasPrefix(parts[1], "Revert ") {
				continue
			}
			for _, hex := range rePrefix.FindAllString(parts[1], -1) {
				reverts[hex[:min(7, len(hex))]] = parts[0][:12]
			}
		}
		for _, row := range rows {
			if s, ok := row["commit"].(string); ok {
				if rv, ok := reverts[s[:min(7, len(s))]]; ok {
					row["reverted_by"] = rv
				}
			}
		}
	}

	writeJSON(w, http.StatusOK, rows)
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// ── /repo/churn/:path ────────────────────────────────────────────────────────

func handleRepoChurn(w http.ResponseWriter, r *http.Request) {
	target := requireTargetRepo(w, r)
	if target == "" {
		return
	}
	rel := strings.TrimPrefix(r.URL.Path, "/repo/churn/")
	if rel == "" {
		writeJSONError(w, http.StatusBadRequest, "missing path", "")
		return
	}
	since := r.URL.Query().Get("since")
	if since == "" {
		since = "30d"
	}
	dur, err := parseDuration(since)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid 'since'", err.Error())
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()
	var args []string
	if dur > 0 {
		// Convert our "30d"/"48h" form to an ISO cutoff — git's --since doesn't
		// parse shorthand like "30d". A resolved timestamp is unambiguous.
		cutoff := time.Now().UTC().Add(-dur).Format(time.RFC3339)
		args = []string{"log", "--since=" + cutoff, "--format=%H%x00%ae%x00%s", "--follow", "--", rel}
	} else {
		args = []string{"log", "--format=%H%x00%ae%x00%s", "--follow", "--", rel}
	}
	out, err := gitRun(ctx, target, args...)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "git log failed", err.Error())
		return
	}
	mods := 0
	reverts := 0
	contribs := map[string]bool{}
	for _, line := range strings.Split(string(out), "\n") {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "\x00", 3)
		if len(parts) < 3 {
			continue
		}
		mods++
		contribs[parts[1]] = true
		if strings.HasPrefix(parts[2], "Revert ") {
			reverts++
		}
	}
	users := make([]string, 0, len(contribs))
	for u := range contribs {
		users = append(users, u)
	}
	sort.Strings(users)
	writeJSON(w, http.StatusOK, map[string]any{
		"path":          rel,
		"since":         since,
		"modifications": mods,
		"reverts":       reverts,
		"contributors":  users,
	})
}

// ── /diff ────────────────────────────────────────────────────────────────────

func handleDiff(w http.ResponseWriter, r *http.Request) {
	target := requireTargetRepo(w, r)
	if target == "" {
		return
	}
	base := r.URL.Query().Get("base")
	branch := r.URL.Query().Get("branch")
	if base == "" || branch == "" {
		writeJSONError(w, http.StatusBadRequest, "both 'base' and 'branch' query params required", "")
		return
	}
	// Validate revs — refuse anything that looks like a flag.
	for _, v := range []string{base, branch} {
		if strings.HasPrefix(v, "-") {
			writeJSONError(w, http.StatusBadRequest, "rev must not start with '-'", v)
			return
		}
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	// Touched files
	out, err := gitRun(ctx, target, "diff", "--name-only", base+"..."+branch)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "git diff failed", err.Error())
		return
	}
	files := []string{}
	for _, f := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if f != "" {
			files = append(files, f)
		}
	}

	// AST top-level delta (Python only) — scan each .py file touched and
	// compare ast_hash + top-level decls between base and branch. Best-effort.
	type decl struct {
		File string `json:"file"`
		Name string `json:"name"`
		Kind string `json:"kind"`
	}
	added, removed, modified := []decl{}, []decl{}, []decl{}
	for _, f := range files {
		if !strings.HasSuffix(f, ".py") {
			continue
		}
		baseDecls, _ := pythonDeclsAt(ctx, target, base, f)
		brDecls, _ := pythonDeclsAt(ctx, target, branch, f)
		baseSet := map[string]string{}
		for _, d := range baseDecls {
			baseSet[d.Name] = d.Kind
		}
		brSet := map[string]string{}
		for _, d := range brDecls {
			brSet[d.Name] = d.Kind
		}
		for name, kind := range brSet {
			if _, ok := baseSet[name]; !ok {
				added = append(added, decl{File: f, Name: name, Kind: kind})
			}
		}
		for name, kind := range baseSet {
			if _, ok := brSet[name]; !ok {
				removed = append(removed, decl{File: f, Name: name, Kind: kind})
			}
		}
		// Modified detection would need body diff — skip v1; only touched.py files show up as modified.
		if len(baseDecls) > 0 && len(brDecls) > 0 && !sameDeclSet(baseDecls, brDecls) {
			for name, kind := range brSet {
				if _, ok := baseSet[name]; ok {
					modified = append(modified, decl{File: f, Name: name, Kind: kind})
				}
			}
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"target":        target,
		"base":          base,
		"branch":        branch,
		"touched_files": files,
		"ast_top_level_delta": map[string]any{
			"added":    added,
			"removed":  removed,
			"modified": modified,
		},
		"tests_delta": map[string]any{"status": "not_implemented"},
	})
}

func sameDeclSet(a, b []pyDecl) bool {
	if len(a) != len(b) {
		return false
	}
	sa, sb := map[string]string{}, map[string]string{}
	for _, d := range a {
		sa[d.Name] = d.Kind
	}
	for _, d := range b {
		sb[d.Name] = d.Kind
	}
	for k, v := range sa {
		if sb[k] != v {
			return false
		}
	}
	return true
}

// pythonDeclsAt extracts top-level decls from a file at a specific rev by
// materializing the blob in memory via `git show rev:path`.
func pythonDeclsAt(ctx context.Context, target, rev, relPath string) ([]pyDecl, error) {
	body, err := gitRun(ctx, target, "show", rev+":"+relPath)
	if err != nil {
		return nil, err
	}
	return runPythonIndexerBytes(ctx, body, "exports")
}

// ── /file/fingerprint ────────────────────────────────────────────────────────

func handleFileFingerprint(w http.ResponseWriter, r *http.Request) {
	p := requireAbsFile(w, r)
	if p == "" {
		return
	}
	body, err := os.ReadFile(p)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "read failed", err.Error())
		return
	}
	h := sha256.Sum256(body)
	contentHash := "sha256:" + hex.EncodeToString(h[:])

	// git sha: resolve via `git ls-files -s -- <path>` from whatever repo contains the file.
	gitSHA := ""
	if repo := findRepoRoot(p); repo != "" {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		rel, _ := filepath.Rel(repo, p)
		if out, err := gitRun(ctx, repo, "ls-files", "-s", "--", rel); err == nil {
			parts := strings.Fields(string(out))
			if len(parts) >= 2 {
				gitSHA = parts[1]
			}
		}
	}

	astHash := ""
	if strings.HasSuffix(strings.ToLower(p), ".py") {
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()
		if h, err := runPythonASTHash(ctx, p); err == nil {
			astHash = h
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"path":                p,
		"sha":                 gitSHA,
		"content_hash":        contentHash,
		"ast_hash":            astHash,
		"test_coverage_hash":  nil,
	})
}

func findRepoRoot(filePath string) string {
	dir := filepath.Dir(filePath)
	for {
		if _, err := os.Stat(filepath.Join(dir, ".git")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
	}
}

// ── /agent/identity/:commit ──────────────────────────────────────────────────

func handleAgentIdentity(w http.ResponseWriter, r *http.Request) {
	sha := strings.TrimPrefix(r.URL.Path, "/agent/identity/")
	if sha == "" {
		writeJSONError(w, http.StatusBadRequest, "missing commit sha in URL", "")
		return
	}
	if !regexp.MustCompile(`^[0-9a-fA-F]{4,40}$`).MatchString(sha) {
		writeJSONError(w, http.StatusBadRequest, "invalid commit sha", "")
		return
	}
	dbPath := resolveDBPath()
	if dbPath == "" {
		writeJSONError(w, http.StatusServiceUnavailable, "no database configured", "")
		return
	}
	if _, err := os.Stat(dbPath); err != nil {
		writeJSONError(w, http.StatusNotFound, "no observations recorded", "")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()

	var rows []map[string]any
	q := fmt.Sprintf(
		"SELECT ts, run_id, agent, subtask_id, model, confidence FROM observations WHERE commit_sha LIKE '%s%%' ORDER BY id DESC LIMIT 1",
		strings.ReplaceAll(sha, "'", "''"),
	)
	if err := sqliteExecJSON(ctx, dbPath, q, &rows); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "query failed", err.Error())
		return
	}
	if len(rows) == 0 {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	writeJSON(w, http.StatusOK, rows[0])
}

// ── POST /observation ────────────────────────────────────────────────────────

type observation struct {
	RunID         string   `json:"run_id"`
	Agent         string   `json:"agent"`
	SubtaskID     string   `json:"subtask_id,omitempty"`
	Model         string   `json:"model,omitempty"`
	Branch        string   `json:"branch,omitempty"`
	CommitSHA     string   `json:"commit_sha,omitempty"`
	Outcome       string   `json:"outcome"`
	TouchedFiles  []string `json:"touched_files,omitempty"`
	FailureModes  []string `json:"failure_modes,omitempty"`
	Confidence    *float64 `json:"confidence,omitempty"`
	Extra         any      `json:"extra,omitempty"`
}

func handleObservation(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONError(w, http.StatusMethodNotAllowed, "POST only", r.Method)
		return
	}
	body, err := readBounded(r, 64*1024)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "body too large or read error", err.Error())
		return
	}
	var obs observation
	if err := json.Unmarshal(body, &obs); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON", err.Error())
		return
	}
	if obs.RunID == "" || obs.Agent == "" || obs.Outcome == "" {
		writeJSONError(w, http.StatusBadRequest, "run_id, agent, outcome are required", "")
		return
	}
	// Constrain outcome to an enum so the column doesn't become a dumping ground.
	switch obs.Outcome {
	case "success", "fail", "partial", "aborted":
	default:
		writeJSONError(w, http.StatusBadRequest, "outcome must be success|fail|partial|aborted", obs.Outcome)
		return
	}

	dbPath := resolveDBPath()
	if dbPath == "" {
		writeJSONError(w, http.StatusServiceUnavailable, "no database configured", "")
		return
	}
	touched, _ := json.Marshal(obs.TouchedFiles)
	failures, _ := json.Marshal(obs.FailureModes)
	extra, _ := json.Marshal(obs.Extra)
	ts := time.Now().UTC().Format(time.RFC3339)
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()

	confidence := "NULL"
	if obs.Confidence != nil {
		confidence = strconv.FormatFloat(*obs.Confidence, 'f', 4, 64)
	}
	insertSQL := fmt.Sprintf(
		"INSERT INTO observations(ts, run_id, agent, subtask_id, model, branch, commit_sha, outcome, touched_files, failure_modes, confidence, extra, raw_json) "+
			"VALUES(%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s); "+
			"SELECT last_insert_rowid();",
		sqlLit(ts),
		sqlLit(obs.RunID),
		sqlLit(obs.Agent),
		sqlLitNullable(obs.SubtaskID),
		sqlLitNullable(obs.Model),
		sqlLitNullable(obs.Branch),
		sqlLitNullable(obs.CommitSHA),
		sqlLit(obs.Outcome),
		sqlLit(string(touched)),
		sqlLit(string(failures)),
		confidence,
		sqlLit(string(extra)),
		sqlLit(string(body)),
	)
	cmd := exec.CommandContext(ctx, "sqlite3", dbPath)
	cmd.Stdin = strings.NewReader(insertSQL)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "insert failed", strings.TrimSpace(stderr.String()))
		return
	}
	idStr := strings.TrimSpace(stdout.String())
	id, _ := strconv.ParseInt(idStr, 10, 64)
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "ts": ts})
}

// sqlLit wraps a string as a SQL literal; single quotes are doubled.
// (Duplicates api/main.go's sqlLiteral via a shorter name for readability.)
func sqlLit(s string) string { return sqlLiteral(s) }

func sqlLitNullable(s string) string {
	if s == "" {
		return "NULL"
	}
	return sqlLiteral(s)
}

func readBounded(r *http.Request, maxBytes int64) ([]byte, error) {
	r.Body = http.MaxBytesReader(nil, r.Body, maxBytes)
	buf := new(bytes.Buffer)
	_, err := buf.ReadFrom(r.Body)
	return buf.Bytes(), err
}

// ── GET /repo/agent-log ──────────────────────────────────────────────────────

func handleAgentLog(w http.ResponseWriter, r *http.Request) {
	dbPath := resolveDBPath()
	if dbPath == "" {
		writeJSON(w, http.StatusOK, []any{})
		return
	}
	if _, err := os.Stat(dbPath); err != nil {
		writeJSON(w, http.StatusOK, []any{})
		return
	}
	limit := 100
	if s := r.URL.Query().Get("limit"); s != "" {
		if n, err := strconv.Atoi(s); err == nil && n >= 1 && n <= 1000 {
			limit = n
		} else {
			writeJSONError(w, http.StatusBadRequest, "invalid 'limit' (1..1000)", s)
			return
		}
	}
	var where []string
	if since := r.URL.Query().Get("since"); since != "" {
		dur, err := parseDuration(since)
		if err != nil {
			// Try parsing as ISO timestamp.
			if _, e2 := time.Parse(time.RFC3339, since); e2 != nil {
				writeJSONError(w, http.StatusBadRequest, "invalid 'since' (want duration or ISO-8601)", since)
				return
			}
			where = append(where, "ts >= "+sqlLit(since))
		} else {
			cutoff := time.Now().UTC().Add(-dur).Format(time.RFC3339)
			where = append(where, "ts >= "+sqlLit(cutoff))
		}
	}
	if run := r.URL.Query().Get("run_id"); run != "" {
		where = append(where, "run_id = "+sqlLit(run))
	}
	if agent := r.URL.Query().Get("agent"); agent != "" {
		where = append(where, "agent = "+sqlLit(agent))
	}
	q := "SELECT id, ts, run_id, agent, subtask_id, model, branch, commit_sha, outcome, touched_files, failure_modes, confidence FROM observations"
	if len(where) > 0 {
		q += " WHERE " + strings.Join(where, " AND ")
	}
	q += " ORDER BY id DESC LIMIT " + strconv.Itoa(limit) + ";"

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	var rows []map[string]any
	if err := sqliteExecJSON(ctx, dbPath, q, &rows); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "query failed", err.Error())
		return
	}
	// touched_files/failure_modes are stored as JSON strings — unmarshal for the caller.
	for _, row := range rows {
		for _, k := range []string{"touched_files", "failure_modes"} {
			if s, ok := row[k].(string); ok && s != "" {
				var arr []string
				if json.Unmarshal([]byte(s), &arr) == nil {
					row[k] = arr
				}
			}
		}
	}
	writeJSON(w, http.StatusOK, rows)
}

// ── /claim ───────────────────────────────────────────────────────────────────
// GET      list active / single by ?path=
// POST     acquire  (body: {path, agent, run_id?, ttl_seconds?})
// DELETE   release  (?lock_id= or ?path=)

func handleClaim(w http.ResponseWriter, r *http.Request) {
	dbPath := resolveDBPath()
	if dbPath == "" {
		writeJSONError(w, http.StatusServiceUnavailable, "no database configured", "")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()

	// Every request first prunes expired rows — lazy GC.
	_ = sqliteExec(ctx, dbPath,
		"DELETE FROM claims WHERE expires_at < "+sqlLit(time.Now().UTC().Format(time.RFC3339))+";")

	switch r.Method {
	case http.MethodGet:
		claimGet(ctx, w, r, dbPath)
	case http.MethodPost:
		claimAcquire(ctx, w, r, dbPath)
	case http.MethodDelete:
		claimRelease(ctx, w, r, dbPath)
	default:
		writeJSONError(w, http.StatusMethodNotAllowed, "GET|POST|DELETE only", r.Method)
	}
}

func claimGet(ctx context.Context, w http.ResponseWriter, r *http.Request, dbPath string) {
	path := r.URL.Query().Get("path")
	q := "SELECT lock_id, path, agent, run_id, acquired, expires_at FROM claims"
	if path != "" {
		q += " WHERE path = " + sqlLit(path)
	}
	q += " ORDER BY acquired DESC;"
	var rows []map[string]any
	if err := sqliteExecJSON(ctx, dbPath, q, &rows); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "query failed", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

type claimRequest struct {
	Path       string `json:"path"`
	Agent      string `json:"agent"`
	RunID      string `json:"run_id,omitempty"`
	TTLSeconds int    `json:"ttl_seconds,omitempty"`
}

func claimAcquire(ctx context.Context, w http.ResponseWriter, r *http.Request, dbPath string) {
	body, err := readBounded(r, 4*1024)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "body too large", err.Error())
		return
	}
	var req claimRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON", err.Error())
		return
	}
	if req.Path == "" || req.Agent == "" {
		writeJSONError(w, http.StatusBadRequest, "path and agent are required", "")
		return
	}
	if req.TTLSeconds <= 0 {
		req.TTLSeconds = 600
	}
	if req.TTLSeconds < 30 {
		req.TTLSeconds = 30
	}
	if req.TTLSeconds > 3600 {
		req.TTLSeconds = 3600
	}
	// Check existing
	var existing []map[string]any
	_ = sqliteExecJSON(ctx, dbPath,
		"SELECT lock_id, agent, run_id, expires_at FROM claims WHERE path = "+sqlLit(req.Path)+";",
		&existing)
	if len(existing) > 0 {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusConflict)
		body, _ := json.Marshal(map[string]any{
			"error":   "already_claimed",
			"held_by": existing[0],
		})
		w.Write(body)
		return
	}
	// Acquire
	lockID := newLockID()
	now := time.Now().UTC()
	expires := now.Add(time.Duration(req.TTLSeconds) * time.Second)
	insertSQL := fmt.Sprintf(
		"INSERT INTO claims(lock_id, path, agent, run_id, acquired, expires_at) VALUES(%s, %s, %s, %s, %s, %s);",
		sqlLit(lockID),
		sqlLit(req.Path),
		sqlLit(req.Agent),
		sqlLitNullable(req.RunID),
		sqlLit(now.Format(time.RFC3339)),
		sqlLit(expires.Format(time.RFC3339)),
	)
	if err := sqliteExec(ctx, dbPath, insertSQL); err != nil {
		// Race: someone inserted between the SELECT and the INSERT.
		writeJSONError(w, http.StatusConflict, "claim race — retry", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"lock_id":    lockID,
		"expires_at": expires.Format(time.RFC3339),
	})
}

func claimRelease(ctx context.Context, w http.ResponseWriter, r *http.Request, dbPath string) {
	lockID := r.URL.Query().Get("lock_id")
	path := r.URL.Query().Get("path")
	if lockID == "" && path == "" {
		writeJSONError(w, http.StatusBadRequest, "provide 'lock_id' or 'path'", "")
		return
	}
	var q string
	if lockID != "" {
		q = "DELETE FROM claims WHERE lock_id = " + sqlLit(lockID) + ";"
	} else {
		q = "DELETE FROM claims WHERE path = " + sqlLit(path) + ";"
	}
	_ = sqliteExec(ctx, dbPath, q)
	writeJSON(w, http.StatusOK, map[string]any{"released": true})
}

// newLockID returns a 16-hex lock identifier. Same shape as trace ids.
func newLockID() string {
	return newTraceID() // alias: already implemented in main.go
}

// ── Python AST endpoints ─────────────────────────────────────────────────────

type pyDecl struct {
	Name   string `json:"name"`
	Kind   string `json:"kind"`
	Lineno int    `json:"lineno"`
	Public bool   `json:"public"`
}

type pyImport struct {
	Module         string `json:"module"`
	SymbolImported string `json:"symbol_imported,omitempty"`
	Line           int    `json:"line"`
}

type pySymbol struct {
	Name      string               `json:"name"`
	Kind      string               `json:"kind"`
	Signature string               `json:"signature"`
	Lineno    int                  `json:"lineno"`
	Callers   []map[string]any     `json:"callers"`
	Callees   []map[string]any     `json:"callees"`
}

// indexerPath returns the absolute path to analyzers/python-symbol-index.py.
// We locate it relative to the engine script (already resolved elsewhere).
func indexerPath() string {
	script := os.Getenv("ENGINE_SCRIPT")
	if script == "" {
		script = "../telemetry_observer.sh"
	}
	return filepath.Join(filepath.Dir(script), "analyzers", "python-symbol-index.py")
}

func runPythonIndexer(ctx context.Context, file, op, arg string) ([]byte, error) {
	indexer := indexerPath()
	if _, err := os.Stat(indexer); err != nil {
		return nil, fmt.Errorf("indexer not found: %s", indexer)
	}
	if _, err := exec.LookPath("python3"); err != nil {
		return nil, errors.New("python3 not installed")
	}
	args := []string{indexer, op, file}
	if arg != "" {
		args = append(args, arg)
	}
	cmd := exec.CommandContext(ctx, "python3", args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	// Always return stdout so callers can inspect structured error payloads
	// (e.g. the `symbol` op exits 1 with {"error":"not_found"} in stdout when
	// the symbol doesn't exist — the handler wants that body to map to 404).
	if err != nil {
		return stdout.Bytes(), fmt.Errorf("%w (%s)", err, strings.TrimSpace(stderr.String()))
	}
	return stdout.Bytes(), nil
}

// runPythonIndexerBytes feeds bytes to the indexer via a temp file.
// Used for /diff to analyze blobs at arbitrary revs without materializing them
// in the working tree.
func runPythonIndexerBytes(ctx context.Context, body []byte, op string) ([]pyDecl, error) {
	tmp, err := os.CreateTemp("", "occam_blob_*.py")
	if err != nil {
		return nil, err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(body); err != nil {
		tmp.Close()
		return nil, err
	}
	tmp.Close()
	raw, err := runPythonIndexer(ctx, tmp.Name(), op, "")
	if err != nil {
		return nil, err
	}
	var decls []pyDecl
	if err := json.Unmarshal(raw, &decls); err != nil {
		return nil, err
	}
	return decls, nil
}

func runPythonASTHash(ctx context.Context, file string) (string, error) {
	raw, err := runPythonIndexer(ctx, file, "ast_hash", "")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(raw)), nil
}

func handleFileImports(w http.ResponseWriter, r *http.Request) {
	p := requireAbsFile(w, r)
	if p == "" {
		return
	}
	if !strings.HasSuffix(strings.ToLower(p), ".py") {
		writeJSON(w, http.StatusOK, map[string]any{"language": "other", "imports": []any{}})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	raw, err := runPythonIndexer(ctx, p, "imports", "")
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "indexer failed", err.Error())
		return
	}
	var imports []pyImport
	if err := json.Unmarshal(raw, &imports); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "bad indexer output", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, imports)
}

func handleFileExports(w http.ResponseWriter, r *http.Request) {
	p := requireAbsFile(w, r)
	if p == "" {
		return
	}
	if !strings.HasSuffix(strings.ToLower(p), ".py") {
		writeJSON(w, http.StatusOK, []any{})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	raw, err := runPythonIndexer(ctx, p, "exports", "")
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "indexer failed", err.Error())
		return
	}
	var decls []pyDecl
	if err := json.Unmarshal(raw, &decls); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "bad indexer output", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, decls)
}

func handleSymbol(w http.ResponseWriter, r *http.Request) {
	p := requireAbsFile(w, r)
	if p == "" {
		return
	}
	name := r.URL.Query().Get("name")
	if name == "" {
		writeJSONError(w, http.StatusBadRequest, "missing 'name'", "")
		return
	}
	if !strings.HasSuffix(strings.ToLower(p), ".py") {
		writeJSONError(w, http.StatusNotImplemented, "symbol lookup is Python-only v1", p)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	raw, runErr := runPythonIndexer(ctx, p, "symbol", name)

	// The indexer returns exit 1 with {"error":"not_found",...} in stdout when
	// the symbol doesn't exist. Read the stdout shape first so an exit-1 that
	// carries a well-formed error payload becomes an HTTP 404 rather than a 500.
	probe := map[string]any{}
	if len(raw) > 0 {
		_ = json.Unmarshal(raw, &probe)
	}
	if errKind, _ := probe["error"].(string); errKind == "not_found" {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNotFound)
		w.Write(raw)
		return
	}
	if runErr != nil {
		writeJSONError(w, http.StatusInternalServerError, "indexer failed", runErr.Error())
		return
	}
	var sym pySymbol
	if err := json.Unmarshal(raw, &sym); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "bad indexer output", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, sym)
}

// ── /contract/:path ──────────────────────────────────────────────────────────

func handleContract(w http.ResponseWriter, r *http.Request) {
	// /contract?path=<abs>   — same convention as /file/*. Keeping the absolute
	// path in the query avoids the net/http path-cleaning redirect that
	// `/contract/<abs>` triggers (double slash after the /contract/ prefix).
	abs := requireAbsFile(w, r)
	if abs == "" {
		return
	}
	publicAPI := []pyDecl{}
	if strings.HasSuffix(strings.ToLower(abs), ".py") {
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()
		if raw, err := runPythonIndexer(ctx, abs, "exports", ""); err == nil {
			_ = json.Unmarshal(raw, &publicAPI)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"path":           abs,
		"public_api":     publicAPI,
		"test_coverage":  0.0,
		"coupling_score": 0,
		"v1_note":        "test_coverage and coupling_score require test-runs integration and a cross-file symbol index (deferred)",
	})
}
