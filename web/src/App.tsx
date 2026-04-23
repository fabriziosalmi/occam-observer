import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  Activity, ShieldAlert, FileText, Code, GitCommit, Terminal,
  CheckCircle2, AlertCircle, RefreshCw, Beaker, FlaskConical, Database, Hammer, Wifi,
} from "lucide-react";
import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

// ── Types (1:1 with docs/api/telemetry.md) ──────────────────────────────────

type CheckLevel = "none" | "low" | "medium" | "high" | "critical";

interface Metrics {
  security_violations: number;
  mass_insertions:     number;
  mass_deletions:      number;
  mass_files_changed:  number;
  entropy_nodes:       number;
  test_files_modified: number;
  debt_issues:         number;
}

interface Violation {
  kind:  "security" | "debt";
  file:  string;
  line:  number;
  text:  string;
  blame: { commit: string; author: string; author_time: string };
}

interface AnalyzerReport {
  name:     string;
  version?: string;
  findings: Array<{
    severity: "critical" | "high" | "medium" | "low" | "info";
    kind:     string;
    rule_id:  string;
    file:     string;
    line:     number;
    message:  string;
    text?:    string;
  }>;
  skipped?: string;
}

interface Intelligence {
  file_types?: { logic?: string[]; config?: string[]; docs?: string[]; media?: string[] };
  infrastructure_changes?: string[];
  schema_mutations?:       string[];
  network_outbound?:       string[];
  signatures_added?:       string[];
  dependencies_added?:     string[];
  syntax_valid?:           string[];
  syntax_invalid?:         string[];
  violations?:             Violation[];
  analyzers?:              AnalyzerReport[];
}

interface Telemetry {
  version:      string;
  trace_id?:    string;
  timestamp:    string;
  branch?:      string;
  commit?:      string;
  target?:      string;
  diff_mode?:   "head" | "staged" | "working";
  is_idle?:     boolean;
  metrics:      Metrics;
  git?:         { author?: string; message?: string; remote?: string; time?: string };
  intelligence?: Intelligence;
  health_score: number;
  check?:       { level: CheckLevel; reasons: string[] };
  performance?: { engine_duration_ms?: number; diff_bytes?: number; analyzers_run?: string[] };
  thresholds?:  { mass_warn: number; mass_critical: number; entropy_warn: number; entropy_critical: number };
}

// ── Utilities ───────────────────────────────────────────────────────────────

function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

function useNow(intervalMs = 1000) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const id = window.setInterval(() => setNow(Date.now()), intervalMs);
    return () => window.clearInterval(id);
  }, [intervalMs]);
  return now;
}

function formatAgo(fromIso: string | undefined, now: number): string {
  if (!fromIso) return "—";
  const t = Date.parse(fromIso);
  if (Number.isNaN(t)) return "—";
  const diff = Math.max(0, Math.floor((now - t) / 1000));
  if (diff < 2)   return "just now";
  if (diff < 60)  return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  return `${Math.floor(diff / 3600)}h ago`;
}

// ── Polling hook ────────────────────────────────────────────────────────────
// - Pauses while the tab is hidden (saves fetch round-trips in bg tabs)
// - Cancels in-flight requests with AbortController to avoid out-of-order sets
// - Parses via res.text() + JSON.parse so a non-JSON 503 doesn't throw "Unexpected token"

function useTelemetry(url: string, intervalMs = 2000) {
  const [data, setData]   = useState<Telemetry | null>(null);
  const [error, setError] = useState<string | null>(null);
  const inflight = useRef<AbortController | null>(null);

  const fetchOnce = useCallback(async () => {
    inflight.current?.abort();
    const ctrl = new AbortController();
    inflight.current = ctrl;
    try {
      const res = await fetch(url, { signal: ctrl.signal });
      const body = await res.text();
      if (!res.ok) throw new Error(`HTTP ${res.status}: ${body.slice(0, 120) || res.statusText}`);
      try {
        const parsed = JSON.parse(body) as Telemetry;
        setData(parsed);
        setError(null);
      } catch {
        throw new Error(`Non-JSON response: ${body.slice(0, 120)}`);
      }
    } catch (e: unknown) {
      if ((e as any)?.name === "AbortError") return;
      setError((e as Error)?.message ?? String(e));
    }
  }, [url]);

  useEffect(() => {
    let id: number | undefined;
    const loop = () => {
      fetchOnce();
      id = window.setTimeout(loop, intervalMs);
    };
    const onVis = () => {
      if (document.hidden) { if (id !== undefined) window.clearTimeout(id); }
      else                 { loop(); }
    };
    if (!document.hidden) loop();
    document.addEventListener("visibilitychange", onVis);
    return () => {
      if (id !== undefined) window.clearTimeout(id);
      document.removeEventListener("visibilitychange", onVis);
      inflight.current?.abort();
    };
  }, [fetchOnce, intervalMs]);

  return { data, error, refresh: fetchOnce };
}

// ── Playground (controlled component, no document.getElementById) ───────────

function Playground({ defaultTarget }: { defaultTarget: string }) {
  const [target, setTarget]   = useState(defaultTarget);
  const [busy, setBusy]       = useState(false);
  const [output, setOutput]   = useState<string>("// Output will appear here…");
  const [lastMs, setLastMs]   = useState<number | null>(null);

  const run = useCallback(async () => {
    if (busy) return;
    setBusy(true);
    setOutput("Running out-of-band bash analysis…");
    const t0 = window.performance.now();
    try {
      const res  = await fetch(`/analyze?path=${encodeURIComponent(target)}`);
      const body = await res.text();
      const ms   = window.performance.now() - t0;
      setLastMs(Math.round(ms));
      try {
        const parsed = JSON.parse(body);
        setOutput(JSON.stringify(parsed, null, 2));
      } catch {
        setOutput(body);
      }
    } catch (e: unknown) {
      setOutput(String(e));
    } finally {
      setBusy(false);
    }
  }, [busy, target]);

  const onKeyDown = useCallback((e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === "Enter") { e.preventDefault(); run(); }
  }, [run]);

  return (
    <section
      aria-labelledby="pg-heading"
      className="p-6 rounded-xl border border-border bg-card shadow-sm mt-6 space-y-4"
    >
      <h3 id="pg-heading" className="font-semibold text-lg flex items-center gap-2">
        <Terminal className="w-5 h-5 text-primary" aria-hidden="true" />
        API Playground — Headless Telemetry
      </h3>
      <p className="text-sm text-muted-foreground">
        Run <code className="bg-secondary px-1 py-0.5 rounded">GET /analyze?path=…</code> against any local Git repository.
      </p>
      <div className="flex flex-col sm:flex-row gap-3">
        <label htmlFor="pg-input" className="sr-only">Repository path</label>
        <input
          id="pg-input"
          type="text"
          value={target}
          onChange={(e) => setTarget(e.target.value)}
          onKeyDown={onKeyDown}
          className="flex-1 bg-background border border-border rounded-lg px-4 py-2 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-primary/50"
          placeholder="/absolute/path/to/a/git/repo"
          spellCheck={false}
          autoCapitalize="off"
          autoCorrect="off"
          autoComplete="off"
        />
        <button
          type="button"
          onClick={run}
          disabled={busy || !target.trim()}
          aria-busy={busy}
          className="px-6 py-2 bg-primary text-primary-foreground rounded-lg font-medium hover:bg-primary/90 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
        >
          {busy ? "Executing…" : "Execute Analysis"}
        </button>
      </div>
      {lastMs !== null && (
        <p className="text-xs text-muted-foreground font-mono" aria-live="polite">
          last run: {lastMs} ms
        </p>
      )}
      <pre
        aria-label="Analysis output"
        className="p-4 rounded-lg bg-background border border-border text-xs font-mono text-muted-foreground overflow-x-auto max-h-96 whitespace-pre-wrap break-words"
      >
        {output}
      </pre>
    </section>
  );
}

// ── Main ────────────────────────────────────────────────────────────────────

export default function App() {
  const { data, error } = useTelemetry("/", 2000);
  const now = useNow(1000);

  // All hooks must run unconditionally before any early returns.
  const derived = useMemo(() => {
    if (!data) return null;
    const metrics = data.metrics ?? ({} as Metrics);
    const hs = data.health_score ?? 0;
    return {
      metrics,
      score:      hs,
      scoreColor: hs >= 90 ? "text-emerald-400" : hs >= 70 ? "text-amber-400" : "text-rose-500",
      scoreBg:    hs >= 90 ? "bg-emerald-400"   : hs >= 70 ? "bg-amber-400"   : "bg-rose-500",
      level:     (data.check?.level ?? "none") as CheckLevel,
      reasons:    data.check?.reasons ?? [],
      authorName: (data.git?.author ?? "").split("<")[0].trim() || "—",
      violations: data.intelligence?.violations ?? [],
      analyzers:  data.intelligence?.analyzers  ?? [],
      infraTouched:   (data.intelligence?.infrastructure_changes?.length ?? 0) > 0,
      schemaTouched:  (data.intelligence?.schema_mutations?.length ?? 0) > 0,
      networkPresent: (data.intelligence?.network_outbound?.length ?? 0) > 0,
      syntaxInvalid:  data.intelligence?.syntax_invalid ?? [],
    };
  }, [data]);

  const levelColor: Record<CheckLevel, string> = {
    none:     "text-emerald-400 border-emerald-500/30 bg-emerald-500/5",
    low:      "text-sky-400     border-sky-500/30     bg-sky-500/5",
    medium:   "text-amber-400   border-amber-500/30   bg-amber-500/5",
    high:     "text-orange-400  border-orange-500/30  bg-orange-500/5",
    critical: "text-rose-400    border-rose-500/30    bg-rose-500/5",
  };

  if (error && !data) {
    return (
      <div role="alert" className="min-h-screen bg-background flex items-center justify-center text-foreground font-mono p-6">
        <div className="max-w-md text-center space-y-3">
          <AlertCircle className="w-8 h-8 text-rose-500 mx-auto" aria-hidden="true" />
          <p className="font-semibold">Can't reach the Occam API</p>
          <p className="text-sm text-muted-foreground">{error}</p>
          <p className="text-xs text-muted-foreground">
            Start the engine: <code className="bg-secondary px-1 py-0.5 rounded">./telemetry_observer.sh /path/to/repo</code>
          </p>
        </div>
      </div>
    );
  }

  if (!data || !derived) {
    return (
      <div className="min-h-screen bg-background flex items-center justify-center text-foreground font-mono">
        <div className="flex flex-col items-center gap-4">
          <RefreshCw className="animate-spin motion-reduce:animate-none w-8 h-8 text-primary" aria-hidden="true" />
          <p>Connecting to Occam Observer Engine…</p>
        </div>
      </div>
    );
  }

  const { metrics, score, scoreColor, scoreBg, level, reasons, authorName, violations, analyzers, infraTouched, schemaTouched, networkPresent, syntaxInvalid } = derived;
  const th = data.thresholds;
  const overEntropyCritical = th ? metrics.entropy_nodes > th.entropy_critical : false;
  const overEntropyWarn     = th ? metrics.entropy_nodes > th.entropy_warn     : false;
  const overMassCritical    = th ? metrics.mass_insertions > th.mass_critical  : false;
  const overMassWarn        = th ? metrics.mass_insertions > th.mass_warn      : false;

  return (
    <div className="min-h-screen bg-background text-foreground font-sans p-4 md:p-6 selection:bg-primary/30">
      <div className="max-w-6xl mx-auto space-y-6">

        {/* Header */}
        <header className="flex flex-col md:flex-row md:items-center justify-between gap-4 p-6 rounded-xl border border-border bg-card shadow-sm">
          <div className="flex items-center gap-4">
            <div className="p-3 rounded-lg bg-primary/10">
              <Activity className="w-6 h-6 text-primary" aria-hidden="true" />
            </div>
            <div>
              <h1 className="text-2xl font-bold tracking-tight">
                Occam Observer
                <span className="text-xs font-mono text-muted-foreground ml-2">v{data.version}</span>
              </h1>
              <p className="text-sm text-muted-foreground">Out-of-band Git telemetry</p>
            </div>
          </div>
          <div className="flex flex-wrap items-center gap-3 font-mono text-sm">
            <div
              className="flex items-center gap-2 px-3 py-1 rounded-full bg-primary/5 border border-primary/20"
              aria-live="polite"
            >
              <span className="relative flex h-2 w-2">
                {!data.is_idle && (
                  <span className="animate-ping motion-reduce:hidden absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-75" />
                )}
                <span className={cn("relative inline-flex rounded-full h-2 w-2",
                  data.is_idle ? "bg-muted-foreground" : "bg-emerald-500")} />
              </span>
              <span className={data.is_idle ? "text-muted-foreground" : "text-emerald-400 font-medium"}>
                {data.is_idle ? "IDLE" : "LIVE"}
              </span>
            </div>
            {data.diff_mode && (
              <span className="px-2 py-1 rounded border border-border text-xs text-muted-foreground uppercase tracking-wider">
                diff: {data.diff_mode}
              </span>
            )}
            <span className="text-xs text-muted-foreground" title={data.timestamp}>
              updated {formatAgo(data.timestamp, now)}
            </span>
            <div className="flex items-center gap-2 text-muted-foreground max-w-full">
              <Terminal className="w-4 h-4" aria-hidden="true" />
              <span className="truncate" title={data.target ?? ""}>
                {data.target ? data.target.split('/').pop() : "—"}
              </span>
            </div>
          </div>
        </header>

        {/* Check level ribbon */}
        <section
          aria-live="polite"
          aria-label={`Check level ${level}`}
          className={cn("rounded-xl border px-4 py-3 flex flex-wrap items-center gap-3 text-sm", levelColor[level])}
        >
          <span className="font-mono uppercase tracking-widest text-xs">check.level</span>
          <span className="font-semibold text-base">{level}</span>
          {reasons.length > 0 && (
            <span className="text-xs font-mono opacity-80 break-all">
              {reasons.join(" · ")}
            </span>
          )}
          {data.trace_id && (
            <span className="sm:ml-auto text-[10px] font-mono opacity-60 truncate max-w-full">
              trace_id={String(data.trace_id).slice(0, 16)}
            </span>
          )}
        </section>

        {/* Integrity score */}
        <section
          aria-label="Integrity score"
          className="p-6 rounded-xl border border-border bg-card shadow-sm flex flex-col gap-4 relative overflow-hidden"
        >
          <div className="absolute top-0 left-0 w-full h-1 bg-border" aria-hidden="true">
            <div
              className={cn("h-full transition-all duration-700 ease-out motion-reduce:transition-none", scoreBg)}
              style={{ width: `${score}%` }}
            />
          </div>
          <div className="flex justify-between items-center mt-2 gap-4">
            <div>
              <h2 className="text-lg font-semibold">Integrity Score</h2>
              <p className="text-sm text-muted-foreground">Derived from the active state vectors</p>
            </div>
            <div
              className={cn("text-5xl font-bold tracking-tighter tabular-nums", scoreColor)}
              role="meter"
              aria-valuenow={score}
              aria-valuemin={0}
              aria-valuemax={100}
              aria-label={`health score ${score} out of 100`}
            >
              {score}
            </div>
          </div>
        </section>

        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">

          {/* Git Meta + Core Metrics */}
          <div className="lg:col-span-1 space-y-6">

            {data.git && (
              <section aria-labelledby="git-heading" className="p-6 rounded-xl border border-border bg-card shadow-sm space-y-4">
                <h3 id="git-heading" className="font-semibold flex items-center gap-2">
                  <GitCommit className="w-4 h-4 text-primary" aria-hidden="true" />
                  Git State
                </h3>
                <dl className="space-y-3 text-sm">
                  <div className="flex justify-between items-center pb-2 border-b border-border/50">
                    <dt className="text-muted-foreground">Branch</dt>
                    <dd className="font-mono bg-secondary px-2 py-0.5 rounded text-secondary-foreground truncate max-w-[60%]" title={data.branch}>
                      {data.branch}
                    </dd>
                  </div>
                  <div className="flex justify-between items-center pb-2 border-b border-border/50">
                    <dt className="text-muted-foreground">Author</dt>
                    <dd className="truncate max-w-[60%]" title={data.git.author}>{authorName}</dd>
                  </div>
                  <div className="flex justify-between items-center pb-2 border-b border-border/50">
                    <dt className="text-muted-foreground">Commit</dt>
                    <dd className="font-mono text-primary">{data.commit}</dd>
                  </div>
                  <div className="pt-2">
                    <dt className="text-xs text-muted-foreground block mb-1">Message</dt>
                    <dd className="text-sm leading-snug break-words">{data.git.message || "Uncommitted working tree"}</dd>
                  </div>
                </dl>
              </section>
            )}

            <section aria-labelledby="vectors-heading" className="p-6 rounded-xl border border-border bg-card shadow-sm space-y-4">
              <h3 id="vectors-heading" className="font-semibold flex items-center gap-2">
                <Activity className="w-4 h-4 text-primary" aria-hidden="true" />
                State Vectors
              </h3>
              <ul className="space-y-3">
                <MetricRow
                  icon={<ShieldAlert className={cn("w-4 h-4", metrics.security_violations > 0 ? "text-rose-500" : "text-emerald-500")} />}
                  label="Security"
                  value={<span className={metrics.security_violations > 0 ? "text-rose-400" : "text-emerald-400"}>{metrics.security_violations}</span>}
                />
                <MetricRow
                  icon={<FileText className="w-4 h-4 text-primary" />}
                  label="Mass"
                  value={
                    <span className={cn(
                      "flex gap-2 text-xs font-mono",
                      overMassCritical && "text-rose-400",
                      !overMassCritical && overMassWarn && "text-amber-400"
                    )}>
                      <span className="text-emerald-400">+{metrics.mass_insertions}</span>
                      <span className="text-rose-400">-{metrics.mass_deletions}</span>
                      <span className="text-muted-foreground">in {metrics.mass_files_changed}f</span>
                    </span>
                  }
                />
                <MetricRow
                  icon={<Code className="w-4 h-4 text-primary" />}
                  label="Complexity"
                  value={
                    <span className={cn("font-mono text-sm",
                      overEntropyCritical ? "text-rose-400" :
                      overEntropyWarn     ? "text-amber-400" : "text-muted-foreground")}>
                      {metrics.entropy_nodes} nodes
                    </span>
                  }
                />
                <MetricRow
                  icon={<Beaker className="w-4 h-4 text-primary" />}
                  label="Testing"
                  value={<span className={metrics.test_files_modified > 0 ? "text-emerald-400" : "text-muted-foreground"}>{metrics.test_files_modified}</span>}
                />
                <MetricRow
                  icon={<Hammer className="w-4 h-4 text-primary" />}
                  label="Debt"
                  value={<span className={metrics.debt_issues > 0 ? "text-amber-400" : "text-muted-foreground"}>{metrics.debt_issues}</span>}
                />
              </ul>
            </section>
          </div>

          {/* Intelligence */}
          <div className="lg:col-span-2 space-y-6">
            <section
              aria-labelledby="intel-heading"
              className="p-6 rounded-xl border border-border bg-card shadow-sm h-full flex flex-col"
            >
              <h3 id="intel-heading" className="font-semibold text-lg flex items-center gap-2 mb-6">
                <Terminal className="w-5 h-5 text-primary" aria-hidden="true" />
                Deep Intelligence
              </h3>

              {!data.intelligence || data.is_idle ? (
                <div className="flex-1 flex flex-col items-center justify-center text-muted-foreground border-2 border-dashed border-border/50 rounded-xl p-8 bg-background/50">
                  <CheckCircle2 className="w-8 h-8 mb-3 opacity-50" aria-hidden="true" />
                  <p className="font-medium text-foreground">Working tree is clean</p>
                  <p className="text-sm mt-1">Edit the target repository to see live semantic extraction.</p>
                </div>
              ) : (
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <div className="space-y-4">
                    <h4 className="text-xs uppercase tracking-wider text-muted-foreground font-semibold">File Categories</h4>
                    <FileList
                      label="Logic"
                      tone="text-primary"
                      files={data.intelligence.file_types?.logic ?? []}
                    />
                    <FileList
                      label="Config"
                      tone="text-amber-400"
                      files={data.intelligence.file_types?.config ?? []}
                    />
                    {infraTouched && (
                      <Badge
                        icon={<AlertCircle className="w-3 h-3" />}
                        label="Infrastructure changed"
                        items={data.intelligence.infrastructure_changes ?? []}
                        tone="rose"
                      />
                    )}
                    {schemaTouched && (
                      <Badge
                        icon={<Database className="w-3 h-3" />}
                        label="Schema mutations"
                        items={data.intelligence.schema_mutations ?? []}
                        tone="rose"
                      />
                    )}
                    {syntaxInvalid.length > 0 && (
                      <Badge
                        icon={<AlertCircle className="w-3 h-3" />}
                        label={`Syntax invalid (${syntaxInvalid.length})`}
                        items={syntaxInvalid}
                        tone="rose"
                      />
                    )}
                  </div>

                  <div className="space-y-4">
                    <h4 className="text-xs uppercase tracking-wider text-muted-foreground font-semibold">Semantic Mappings</h4>
                    <Mono
                      label="Signatures added"
                      items={data.intelligence.signatures_added ?? []}
                      tone="text-emerald-400"
                    />
                    <Mono
                      label="Dependencies added"
                      items={data.intelligence.dependencies_added ?? []}
                      tone="text-amber-400"
                    />
                    {networkPresent && (
                      <Badge
                        icon={<Wifi className="w-3 h-3" />}
                        label="Network outbound"
                        items={data.intelligence.network_outbound ?? []}
                        tone="rose"
                      />
                    )}
                  </div>
                </div>
              )}
            </section>
          </div>
        </div>

        {/* Violations */}
        {violations.length > 0 && (
          <section aria-labelledby="vio-heading" className="p-6 rounded-xl border border-border bg-card shadow-sm space-y-3">
            <h3 id="vio-heading" className="font-semibold flex items-center gap-2">
              <AlertCircle className="w-4 h-4 text-rose-400" aria-hidden="true" />
              Violations ({violations.length})
              <span className="text-xs text-muted-foreground font-normal">per-line blame</span>
            </h3>
            <ul className="divide-y divide-border/50">
              {violations.slice(0, 10).map((v, i) => (
                <li key={i} className="py-2 flex flex-col md:flex-row md:items-center md:gap-4 text-xs font-mono">
                  <span className={cn(
                    "px-2 py-0.5 rounded uppercase tracking-wide text-[10px] w-fit",
                    v.kind === "security" ? "bg-rose-500/15 text-rose-300" : "bg-amber-500/15 text-amber-300"
                  )}>{v.kind}</span>
                  <span className="text-primary truncate">{v.file}:{v.line}</span>
                  <span className="text-muted-foreground truncate flex-1">{v.text}</span>
                  <span className="text-[10px] text-muted-foreground">
                    {v.blame?.commit === "uncommitted"
                      ? <span className="text-rose-300">new</span>
                      : `${(v.blame?.commit ?? "").slice(0, 7)} · ${(v.blame?.author ?? "").split("<")[0]}`}
                  </span>
                </li>
              ))}
            </ul>
          </section>
        )}

        {/* Analyzers */}
        {analyzers.length > 0 && (
          <section aria-labelledby="an-heading" className="p-6 rounded-xl border border-border bg-card shadow-sm space-y-3">
            <h3 id="an-heading" className="font-semibold flex items-center gap-2">
              <FlaskConical className="w-4 h-4 text-primary" aria-hidden="true" />
              Analyzer findings
            </h3>
            {analyzers.map((a, i) => {
              const findings = a.findings ?? [];
              if (findings.length === 0) {
                return (
                  <p key={i} className="text-xs font-mono text-muted-foreground">
                    <span className="text-foreground">{a.name}</span>
                    {a.version && <span className="opacity-60"> v{a.version}</span>}
                    {a.skipped
                      ? <span className="ml-2 opacity-60">skipped: {a.skipped}</span>
                      : <span className="ml-2 text-emerald-400">clean</span>}
                  </p>
                );
              }
              return (
                <div key={i} className="space-y-1">
                  <p className="text-xs font-mono">
                    <span className="text-foreground font-semibold">{a.name}</span>
                    {a.version && <span className="opacity-60"> v{a.version}</span>}
                    <span className="ml-2 text-muted-foreground">{findings.length} finding(s)</span>
                  </p>
                  <ul className="divide-y divide-border/50 pl-2">
                    {findings.slice(0, 8).map((f, j) => (
                      <li key={j} className="py-1 flex flex-col md:flex-row md:items-center md:gap-3 text-[11px] font-mono">
                        <span className={cn(
                          "px-1.5 py-0.5 rounded text-[9px] uppercase w-fit",
                          f.severity === "critical" ? "bg-rose-500/20 text-rose-300" :
                          f.severity === "high"     ? "bg-orange-500/20 text-orange-300" :
                          f.severity === "medium"   ? "bg-amber-500/20 text-amber-300" :
                                                      "bg-sky-500/20 text-sky-300"
                        )}>{f.severity}</span>
                        <span className="text-primary truncate">{f.file}:{f.line}</span>
                        <span className="text-muted-foreground truncate flex-1">{f.message}</span>
                        <span className="opacity-60 truncate max-w-[200px]" title={f.rule_id}>{f.rule_id}</span>
                      </li>
                    ))}
                  </ul>
                </div>
              );
            })}
          </section>
        )}

        {/* Performance footer */}
        {data.performance && (
          <p
            className="text-xs font-mono text-muted-foreground flex flex-wrap gap-4 px-2"
            aria-live="polite"
          >
            <span>engine {data.performance.engine_duration_ms ?? 0}ms</span>
            <span>diff {data.performance.diff_bytes ?? 0}B</span>
            {(data.performance.analyzers_run?.length ?? 0) > 0 && (
              <span>analyzers [{data.performance.analyzers_run?.join(", ")}]</span>
            )}
          </p>
        )}

        <Playground defaultTarget={data.target ?? ""} />

        {/* stale-data banner */}
        {error && (
          <div
            role="status"
            aria-live="polite"
            className="rounded-xl border border-amber-500/30 bg-amber-500/5 text-amber-300 px-4 py-2 text-sm font-mono"
          >
            showing last cached snapshot · live fetch error: {error}
          </div>
        )}
      </div>
    </div>
  );
}

// ── Small presentational helpers ────────────────────────────────────────────

function MetricRow({ icon, label, value }: { icon: React.ReactNode; label: string; value: React.ReactNode }) {
  return (
    <li className="p-3 rounded-lg border border-border bg-background flex justify-between items-center gap-3">
      <div className="flex items-center gap-3 min-w-0">
        {icon}
        <span className="text-sm font-medium truncate">{label}</span>
      </div>
      <span className="font-mono text-sm shrink-0">{value}</span>
    </li>
  );
}

function FileList({ label, tone, files }: { label: string; tone: string; files: string[] }) {
  if (files.length === 0) return null;
  return (
    <div className="p-3 rounded-lg border border-border bg-background">
      <span className={cn("text-xs font-mono mb-2 block", tone)}>{label} ({files.length})</span>
      <div className="flex flex-wrap gap-2">
        {files.map((f) => (
          <span key={f} className="text-xs bg-secondary px-2 py-1 rounded truncate max-w-full" title={f}>{f}</span>
        ))}
      </div>
    </div>
  );
}

function Mono({ label, tone, items }: { label: string; tone: string; items: string[] }) {
  if (items.length === 0) return null;
  return (
    <div className="p-3 rounded-lg border border-border bg-background">
      <span className={cn("text-xs font-mono mb-2 block", tone)}>{label}</span>
      <ul className="space-y-1">
        {items.map((f, i) => <li key={i} className="text-xs font-mono text-muted-foreground truncate" title={f}>{f}</li>)}
      </ul>
    </div>
  );
}

function Badge({ icon, label, items, tone }: { icon: React.ReactNode; label: string; items: string[]; tone: "rose" | "amber" }) {
  const cls = tone === "rose"
    ? "border-rose-500/30 bg-rose-500/5 text-rose-400"
    : "border-amber-500/30 bg-amber-500/5 text-amber-400";
  const chipCls = tone === "rose"
    ? "bg-rose-500/20 text-rose-300"
    : "bg-amber-500/20 text-amber-300";
  return (
    <div className={cn("p-3 rounded-lg border", cls)}>
      <span className="text-xs font-mono flex items-center gap-2 mb-2">{icon} {label}</span>
      <div className="flex flex-wrap gap-2">
        {items.map((f) => (
          <span key={f} className={cn("text-xs px-2 py-1 rounded truncate max-w-full", chipCls)} title={f}>{f}</span>
        ))}
      </div>
    </div>
  );
}
