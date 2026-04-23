package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// ── Self-observability state ──────────────────────────────────────────────────
// In-memory counters. No external dep on github.com/prometheus/client_golang
// to keep the binary portable; exposition follows the Prometheus text format.
var (
	startedAt            = time.Now()
	analyzeCountOK       atomic.Int64
	analyzeCountErr      atomic.Int64
	analyzeDurMicrosSum  atomic.Int64
	analyzeDurCount      atomic.Int64
	trendCountOK         atomic.Int64
	trendCountErr        atomic.Int64

	// snapshotsTotal is refreshed by a background goroutine so /metrics
	// never forks sqlite3 on the hot path. -1 means "not yet probed" or
	// "probe failed"; exposed verbatim so scrapers can distinguish from 0.
	snapshotsTotal atomic.Int64

	// Signal channel: /analyze writes a non-blocking "refresh now" nudge so
	// freshly-persisted rows show up in /metrics without waiting for the tick.
	metricsNudge = make(chan struct{}, 1)
)

func init() {
	snapshotsTotal.Store(-1)
}

func nudgeMetrics() {
	select {
	case metricsNudge <- struct{}{}:
	default: // already pending — coalesce
	}
}

// startBackgroundMetrics refreshes self-gauges that would otherwise require
// subprocess forks per /metrics scrape. Runs until ctx is cancelled.
// A hybrid of a coarse ticker (catches DB writes from other processes, like
// the TUI watcher) and a nudge channel (freshens immediately after the Go
// gateway itself triggers a persist).
func startBackgroundMetrics(ctx context.Context) {
	tick := time.NewTicker(10 * time.Second)
	defer tick.Stop()
	refresh := func() {
		dbPath := resolveDBPath()
		if dbPath == "" {
			return
		}
		if _, err := os.Stat(dbPath); err != nil {
			return
		}
		if _, err := exec.LookPath("sqlite3"); err != nil {
			return
		}
		qctx, cancel := context.WithTimeout(ctx, 2*time.Second)
		defer cancel()
		out, err := exec.CommandContext(qctx, "sqlite3", "-readonly", dbPath,
			"SELECT COUNT(*) FROM snapshots;").Output()
		if err != nil {
			return
		}
		if n, err := strconv.ParseInt(strings.TrimSpace(string(out)), 10, 64); err == nil {
			snapshotsTotal.Store(n)
		}
	}
	refresh() // eager first probe
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			refresh()
		case <-metricsNudge:
			refresh()
		}
	}
}

func observeAnalyze(ok bool, d time.Duration) {
	if ok {
		analyzeCountOK.Add(1)
	} else {
		analyzeCountErr.Add(1)
	}
	analyzeDurCount.Add(1)
	analyzeDurMicrosSum.Add(d.Microseconds())
}

func observeTrend(ok bool) {
	if ok {
		trendCountOK.Add(1)
	} else {
		trendCountErr.Add(1)
	}
}

const analyzeTimeout = 30 * time.Second

func main() {
	port := os.Getenv("API_PORT")
	if port == "" {
		port = "9999"
	}

	http.HandleFunc("/",        withTraceID(handleRoot))
	http.HandleFunc("/analyze", withTraceID(handleAnalyze))
	http.HandleFunc("/trend",   withTraceID(handleTrend))
	// Self-observability — intentionally outside the traceID middleware so
	// probes are absolutely minimal in the hot path.
	http.HandleFunc("/healthz", handleHealthz)
	http.HandleFunc("/readyz",  handleReadyz)
	http.HandleFunc("/metrics", handleMetrics)

	// Coordination API (multi-agent: repo context, blame, churn, observations,
	// claims, AST-backed file/symbol, diff, stubs). Full contract in
	// docs/guide/coordination-api.md.
	registerCoordinationRoutes()
	if dbPath := resolveDBPath(); dbPath != "" {
		if err := initCoordinationDB(dbPath); err != nil {
			log.Printf("coordination db init: %v (endpoints may 503 until writable)", err)
		}
	}

	// Serve static files from the "public" directory
	fs := http.FileServer(http.Dir("./public"))
	http.Handle("/ui/", http.StripPrefix("/ui/", fs))

	addr := fmt.Sprintf("127.0.0.1:%s", port)
	log.Printf("Occam API Server running on http://%s", addr)

	// Background metrics refresh (snapshot count). Cancelled on shutdown
	// by the context; the process exits before cleanup matters in practice,
	// but we keep the plumbing correct.
	metricsCtx, metricsCancel := context.WithCancel(context.Background())
	defer metricsCancel()
	go startBackgroundMetrics(metricsCtx)

	srv := &http.Server{
		Addr:              addr,
		ReadHeaderTimeout: 5 * time.Second,
	}
	if err := srv.ListenAndServe(); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}

// ── Trace ID middleware ──────────────────────────────────────────────────────
// Every request gets a trace_id (caller-supplied via X-Trace-Id or freshly
// generated). It is: (a) echoed in the response X-Trace-Id header, (b) passed
// to the bash engine as OCCAM_TRACE_ID env var for log correlation, and
// (c) logged on the Go side alongside request metadata. Agents grep
// telemetry_observer.sh stderr and occam-api logs by the same id.

type ctxKey string

const traceIDKey ctxKey = "trace_id"

func newTraceID() string {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		return strconv.FormatInt(time.Now().UnixNano(), 16)
	}
	return hex.EncodeToString(b[:])
}

func withTraceID(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tid := r.Header.Get("X-Trace-Id")
		if tid == "" {
			tid = newTraceID()
		}
		// Set response header FIRST — writing headers after WriteHeader is a no-op.
		w.Header().Set("X-Trace-Id", tid)
		ctx := context.WithValue(r.Context(), traceIDKey, tid)
		start := time.Now()
		next.ServeHTTP(w, r.WithContext(ctx))
		log.Printf("trace=%s method=%s path=%s dur_ms=%d",
			tid, r.Method, r.URL.Path, time.Since(start).Milliseconds())
	}
}

func traceIDOf(r *http.Request) string {
	if v, ok := r.Context().Value(traceIDKey).(string); ok {
		return v
	}
	return ""
}

// writeJSONError emits a well-formed JSON error body. Agents consuming this
// API rely on the envelope being parseable even on failure.
func writeJSONError(w http.ResponseWriter, status int, msg string, detail string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	body := map[string]string{"error": msg}
	if detail != "" {
		body["details"] = detail
	}
	enc, _ := json.Marshal(body)
	w.Write(enc)
}

// handleRoot implements the CQRS read model, returning the JSON cache in O(1) latency
func handleRoot(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}

	cacheFile := os.Getenv("CACHE_FILE")
	if cacheFile == "" {
		cacheFile = "/tmp/occam_state.json"
	}

	data, err := os.ReadFile(cacheFile)
	if err != nil {
		writeJSONError(w, http.StatusServiceUnavailable, "cache not ready or observer not running", "")
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Write(data)
}

// validateTargetPath rejects flag-like paths and anything that is not an
// existing directory. Prevents passing `--config /etc/passwd` or similar as
// a positional arg to the bash engine.
func validateTargetPath(p string) (string, error) {
	if p == "" {
		return "", fmt.Errorf("missing 'path' query parameter")
	}
	if strings.HasPrefix(p, "-") {
		return "", fmt.Errorf("path must not start with '-'")
	}
	abs, err := filepath.Abs(p)
	if err != nil {
		return "", fmt.Errorf("cannot resolve path")
	}
	abs = filepath.Clean(abs)
	info, err := os.Stat(abs)
	if err != nil {
		return "", fmt.Errorf("path does not exist")
	}
	if !info.IsDir() {
		return "", fmt.Errorf("path is not a directory")
	}
	return abs, nil
}

// handleAnalyze allows on-demand telemetry of any path using the --json headless mode
func handleAnalyze(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	ok := false
	defer func() { observeAnalyze(ok, time.Since(start)) }()

	targetPath, err := validateTargetPath(r.URL.Query().Get("path"))
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error(), "")
		return
	}

	engineScript := os.Getenv("ENGINE_SCRIPT")
	if engineScript == "" {
		engineScript = "../telemetry_observer.sh"
	}
	if _, err := os.Stat(engineScript); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "telemetry_observer.sh not found", engineScript)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), analyzeTimeout)
	defer cancel()

	// Separate stdout (JSON payload) from stderr (engine logs/errors) — mixing
	// them via CombinedOutput() corrupts the JSON that agents expect.
	var stdout, stderr bytes.Buffer
	cmd := exec.CommandContext(ctx, engineScript, "--json", targetPath)
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if tid := traceIDOf(r); tid != "" {
		cmd.Env = append(os.Environ(), "OCCAM_TRACE_ID="+tid)
	}
	runErr := cmd.Run()

	out := stdout.Bytes()
	// If the engine emitted valid JSON (even on non-zero exit), forward it.
	var probe map[string]interface{}
	if json.Unmarshal(out, &probe) == nil {
		status := http.StatusOK
		if runErr != nil {
			status = http.StatusInternalServerError
		} else {
			ok = true
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		w.Write(out)
		// Engine persisted a row; freshen the gauge without waiting for the tick.
		if ok {
			nudgeMetrics()
		}
		return
	}

	detail := runErr.Error()
	if s := strings.TrimSpace(stderr.String()); s != "" {
		detail = detail + ": " + s
	}
	log.Printf("analyze failed for %s: %s", targetPath, detail)
	writeJSONError(w, http.StatusInternalServerError, "engine failed", detail)
}

// resolveDBPath mirrors the bash engine's default ($XDG_DATA_HOME/occam-observer/snapshots.db).
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

// sqlLiteral wraps a string as a SQL literal with single-quote doubling.
// Used for values that cannot be bound via sqlite3 CLI parameters easily.
func sqlLiteral(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

// handleHealthz — liveness. Stays cheap: no I/O, never 503. Meant for
// container/process-level supervision ("is the Go binary alive?").
func handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"status":"ok","uptime_seconds":%.1f}`, time.Since(startedAt).Seconds())
}

// handleReadyz — readiness. Checks that the dependencies needed to serve a
// real request are in place. 503 if any is missing, with a JSON body pointing
// to the specific gap so agents can diagnose.
func handleReadyz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	gaps := []string{}
	// Engine script resolvable?
	engineScript := os.Getenv("ENGINE_SCRIPT")
	if engineScript == "" {
		engineScript = "../telemetry_observer.sh"
	}
	if _, err := os.Stat(engineScript); err != nil {
		gaps = append(gaps, "engine_script_missing:"+engineScript)
	}
	// Cache file OR DB usable → one of the two is enough for agents to get
	// telemetry. Empty state with neither is "not ready yet".
	cacheFile := os.Getenv("CACHE_FILE")
	if cacheFile == "" {
		cacheFile = "/tmp/occam_state.json"
	}
	cacheOK := false
	if _, err := os.Stat(cacheFile); err == nil {
		cacheOK = true
	}
	dbPath := resolveDBPath()
	dbOK := false
	if dbPath != "" {
		if _, err := os.Stat(dbPath); err == nil {
			dbOK = true
		}
	}
	if !cacheOK && !dbOK {
		gaps = append(gaps, "no_cache_and_no_db")
	}
	if len(gaps) > 0 {
		w.WriteHeader(http.StatusServiceUnavailable)
		body, _ := json.Marshal(map[string]interface{}{"status": "not_ready", "gaps": gaps})
		w.Write(body)
		return
	}
	fmt.Fprintln(w, `{"status":"ready"}`)
}

// handleMetrics — Prometheus text exposition. Counters are atomic, gauges
// are read on-request (snapshots row count, cache file age). Kept hand-rolled
// so the binary has no client_golang dependency.
func handleMetrics(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	var b strings.Builder

	fmt.Fprintln(&b, "# HELP occam_up 1 if the API process is up")
	fmt.Fprintln(&b, "# TYPE occam_up gauge")
	fmt.Fprintln(&b, "occam_up 1")

	fmt.Fprintln(&b, "# HELP occam_uptime_seconds Seconds since process start")
	fmt.Fprintln(&b, "# TYPE occam_uptime_seconds gauge")
	fmt.Fprintf(&b,  "occam_uptime_seconds %.3f\n", time.Since(startedAt).Seconds())

	fmt.Fprintln(&b, "# HELP occam_analyses_total Number of /analyze requests handled, by outcome")
	fmt.Fprintln(&b, "# TYPE occam_analyses_total counter")
	fmt.Fprintf(&b,  "occam_analyses_total{result=\"ok\"} %d\n",    analyzeCountOK.Load())
	fmt.Fprintf(&b,  "occam_analyses_total{result=\"error\"} %d\n", analyzeCountErr.Load())

	fmt.Fprintln(&b, "# HELP occam_analyze_duration_seconds Summary of /analyze wall time")
	fmt.Fprintln(&b, "# TYPE occam_analyze_duration_seconds summary")
	fmt.Fprintf(&b,  "occam_analyze_duration_seconds_count %d\n", analyzeDurCount.Load())
	fmt.Fprintf(&b,  "occam_analyze_duration_seconds_sum %.6f\n", float64(analyzeDurMicrosSum.Load())/1e6)

	fmt.Fprintln(&b, "# HELP occam_trend_requests_total Number of /trend requests handled, by outcome")
	fmt.Fprintln(&b, "# TYPE occam_trend_requests_total counter")
	fmt.Fprintf(&b,  "occam_trend_requests_total{result=\"ok\"} %d\n",    trendCountOK.Load())
	fmt.Fprintf(&b,  "occam_trend_requests_total{result=\"error\"} %d\n", trendCountErr.Load())

	// Cache file age — 0 if missing.
	cacheFile := os.Getenv("CACHE_FILE")
	if cacheFile == "" {
		cacheFile = "/tmp/occam_state.json"
	}
	age := -1.0
	if st, err := os.Stat(cacheFile); err == nil {
		age = time.Since(st.ModTime()).Seconds()
	}
	fmt.Fprintln(&b, "# HELP occam_cache_age_seconds Age of the write-through JSON cache (-1 if absent)")
	fmt.Fprintln(&b, "# TYPE occam_cache_age_seconds gauge")
	fmt.Fprintf(&b,  "occam_cache_age_seconds %.3f\n", age)

	// Snapshot count — served from an in-memory atomic updated by a
	// background goroutine every 30s. Never forks sqlite3 on the scrape path,
	// so /metrics stays cheap under frequent Prometheus scraping.
	snap := snapshotsTotal.Load()
	if snap >= 0 {
		fmt.Fprintln(&b, "# HELP occam_snapshots_total Rows in the TSDB (refreshed every 30s)")
		fmt.Fprintln(&b, "# TYPE occam_snapshots_total gauge")
		fmt.Fprintf(&b,  "occam_snapshots_total %d\n", snap)
	}

	w.Write([]byte(b.String()))
}

// handleTrend exposes the SQLite TSDB. Query params:
//
//	?target=<abs path>   optional — filter by target repo
//	?limit=<1..1000>     optional — default 100, newest first
//	?since=<ISO8601>     optional — lower bound on ts column
//
// Returns a JSON array of snapshot rows (oldest→newest order).
func handleTrend(w http.ResponseWriter, r *http.Request) {
	ok := false
	defer func() { observeTrend(ok) }()

	dbPath := resolveDBPath()
	if dbPath == "" {
		writeJSONError(w, http.StatusInternalServerError, "cannot resolve DB path", "")
		return
	}
	if _, err := os.Stat(dbPath); err != nil {
		writeJSONError(w, http.StatusServiceUnavailable, "no snapshots yet", dbPath)
		return
	}
	if _, err := exec.LookPath("sqlite3"); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "sqlite3 CLI not installed", "")
		return
	}
	_ = ok // success path sets it just before Write

	limitN := 100
	if s := r.URL.Query().Get("limit"); s != "" {
		n, err := strconv.Atoi(s)
		if err != nil || n < 1 || n > 1000 {
			writeJSONError(w, http.StatusBadRequest, "invalid 'limit' (want 1..1000)", "")
			return
		}
		limitN = n
	}

	// Build SQL with inline-escaped literals. Inputs are (a) validated as
	// strings that go through sqlLiteral (SQL string-literal escape) and
	// (b) the numeric limit which was parsed via strconv. No raw
	// concatenation of user input.
	var where []string
	if t := r.URL.Query().Get("target"); t != "" {
		where = append(where, "target = "+sqlLiteral(t))
	}
	if s := r.URL.Query().Get("since"); s != "" {
		where = append(where, "ts >= "+sqlLiteral(s))
	}
	query := "SELECT id, ts, target, branch, commit_sha, health_score, " +
		"security_violations, mass_insertions, mass_deletions, mass_files_changed, " +
		"entropy_nodes, test_files_modified, debt_issues, check_level, diff_mode " +
		"FROM snapshots"
	if len(where) > 0 {
		query += " WHERE " + strings.Join(where, " AND ")
	}
	query += " ORDER BY id DESC LIMIT " + strconv.Itoa(limitN) + ";"

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	// -readonly prevents any accidental write; -json emits a JSON array.
	cmd := exec.CommandContext(ctx, "sqlite3", "-readonly", "-json", dbPath, query)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "query failed", strings.TrimSpace(stderr.String()))
		return
	}
	out := bytes.TrimSpace(stdout.Bytes())
	if len(out) == 0 {
		out = []byte("[]")
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write(out)
	ok = true
}
