import { useEffect, useState } from "react";
import { Activity, ShieldAlert, FileText, Code, GitCommit, Terminal, CheckCircle2, AlertCircle, RefreshCw } from "lucide-react";
import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

export default function App() {
  const [data, setData] = useState<any>(null);
  const [, setLoading] = useState(true);

  useEffect(() => {
    const fetchData = async () => {
      try {
        const res = await fetch("/");
        const json = await res.json();
        setData(json);
      } catch (e) {
        console.error("Failed to fetch API:", e);
      } finally {
        setLoading(false);
      }
    };
    fetchData();
    const int = setInterval(fetchData, 1000);
    return () => clearInterval(int);
  }, []);

  if (!data) return (
    <div className="min-h-screen bg-background flex items-center justify-center text-foreground font-mono">
      <div className="flex flex-col items-center gap-4">
        <RefreshCw className="animate-spin w-8 h-8 text-primary" />
        <p>Connecting to Occam Observer Engine...</p>
      </div>
    </div>
  );

  const { metrics, health_score, intelligence, git, is_idle, branch, commit, target, version } = data;

  const scoreColor = health_score >= 90 ? "text-emerald-400" : health_score >= 70 ? "text-amber-400" : "text-rose-500";
  const scoreBg = health_score >= 90 ? "bg-emerald-400" : health_score >= 70 ? "bg-amber-400" : "bg-rose-500";

  return (
    <div className="min-h-screen bg-background text-foreground font-sans p-6 selection:bg-primary/30">
      <div className="max-w-6xl mx-auto space-y-6">
        
        {/* Header */}
        <header className="flex flex-col md:flex-row md:items-center justify-between p-6 rounded-xl border border-border bg-card shadow-sm backdrop-blur-sm">
          <div className="flex items-center gap-4">
            <div className="p-3 rounded-lg bg-primary/10">
              <Activity className="w-6 h-6 text-primary" />
            </div>
            <div>
              <h1 className="text-2xl font-bold tracking-tight">Occam Observer <span className="text-xs font-mono text-muted-foreground ml-2">v{version}</span></h1>
              <p className="text-sm text-muted-foreground">Out-of-Band Git Telemetry Dashboard</p>
            </div>
          </div>
          <div className="mt-4 md:mt-0 flex flex-wrap items-center gap-4 font-mono text-sm">
            <div className="flex items-center gap-2 px-3 py-1 rounded-full bg-primary/5 border border-primary/20">
              <span className="relative flex h-2 w-2">
                {!is_idle && <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-75"></span>}
                <span className={cn("relative inline-flex rounded-full h-2 w-2", is_idle ? "bg-muted-foreground" : "bg-emerald-500")}></span>
              </span>
              <span className={is_idle ? "text-muted-foreground" : "text-emerald-400 font-medium"}>
                {is_idle ? "IDLE" : "LIVE"}
              </span>
            </div>
            <div className="flex items-center gap-2 text-muted-foreground">
              <Terminal className="w-4 h-4" />
              <span>{target?.split('/').pop()}</span>
            </div>
          </div>
        </header>

        {/* Global Health */}
        <div className="p-6 rounded-xl border border-border bg-card shadow-sm flex flex-col gap-4 relative overflow-hidden">
          <div className="absolute top-0 left-0 w-full h-1 bg-border">
            <div className={cn("h-full transition-all duration-1000 ease-out", scoreBg)} style={{ width: `${health_score}%` }} />
          </div>
          <div className="flex justify-between items-center mt-2">
            <div>
              <h2 className="text-lg font-semibold">Integrity Score</h2>
              <p className="text-sm text-muted-foreground">Real-time repository health evaluation</p>
            </div>
            <div className={cn("text-5xl font-bold tracking-tighter", scoreColor)}>
              {health_score}
            </div>
          </div>
        </div>

        {/* Split Grid */}
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          
          {/* Left Column: Git Meta & Core Metrics */}
          <div className="lg:col-span-1 space-y-6">
            
            {/* Git Metadata Card */}
            {git && (
              <div className="p-6 rounded-xl border border-border bg-card shadow-sm space-y-4">
                <h3 className="font-semibold flex items-center gap-2">
                  <GitCommit className="w-4 h-4 text-primary" /> 
                  Git State
                </h3>
                <div className="space-y-3 text-sm">
                  <div className="flex justify-between items-center pb-2 border-b border-border/50">
                    <span className="text-muted-foreground">Branch</span>
                    <span className="font-mono bg-secondary px-2 py-0.5 rounded text-secondary-foreground">{branch}</span>
                  </div>
                  <div className="flex justify-between items-center pb-2 border-b border-border/50">
                    <span className="text-muted-foreground">Author</span>
                    <span className="truncate max-w-[150px]">{git.author.split('<')[0]}</span>
                  </div>
                  <div className="flex justify-between items-center pb-2 border-b border-border/50">
                    <span className="text-muted-foreground">Commit</span>
                    <span className="font-mono text-primary">{commit}</span>
                  </div>
                  <div className="pt-2">
                    <span className="text-xs text-muted-foreground block mb-1">Message</span>
                    <p className="text-sm leading-snug">{git.message || "Uncommitted Working Tree"}</p>
                  </div>
                </div>
              </div>
            )}

            {/* Core Metrics */}
            <div className="p-6 rounded-xl border border-border bg-card shadow-sm space-y-4">
               <h3 className="font-semibold flex items-center gap-2">
                <Activity className="w-4 h-4 text-primary" />
                State Vectors
              </h3>
              <div className="space-y-3">
                <div className="p-3 rounded-lg border border-border bg-background flex justify-between items-center">
                  <div className="flex items-center gap-3">
                    <ShieldAlert className={cn("w-4 h-4", metrics.security_violations > 0 ? "text-rose-500" : "text-emerald-500")} />
                    <span className="text-sm font-medium">Security</span>
                  </div>
                  <span className="font-mono text-sm">{metrics.security_violations}</span>
                </div>
                
                <div className="p-3 rounded-lg border border-border bg-background flex justify-between items-center">
                  <div className="flex items-center gap-3">
                    <FileText className="w-4 h-4 text-primary" />
                    <span className="text-sm font-medium">Mass</span>
                  </div>
                  <div className="flex gap-2 text-xs font-mono">
                    <span className="text-emerald-400">+{metrics.mass_insertions}</span>
                    <span className="text-rose-400">-{metrics.mass_deletions}</span>
                  </div>
                </div>

                <div className="p-3 rounded-lg border border-border bg-background flex justify-between items-center">
                  <div className="flex items-center gap-3">
                    <Code className="w-4 h-4 text-primary" />
                    <span className="text-sm font-medium">Complexity</span>
                  </div>
                  <span className="font-mono text-sm text-amber-400">{metrics.entropy_nodes} nodes</span>
                </div>
              </div>
            </div>
          </div>

          {/* Right Column: Advanced Intelligence */}
          <div className="lg:col-span-2 space-y-6">
            <div className="p-6 rounded-xl border border-border bg-card shadow-sm h-full flex flex-col">
              <h3 className="font-semibold text-lg flex items-center gap-2 mb-6">
                <Terminal className="w-5 h-5 text-primary" />
                Deep Intelligence Analysis
              </h3>
              
              {!intelligence || is_idle ? (
                <div className="flex-1 flex flex-col items-center justify-center text-muted-foreground border-2 border-dashed border-border/50 rounded-xl p-8 bg-background/50">
                  <CheckCircle2 className="w-8 h-8 mb-3 opacity-50" />
                  <p className="font-medium text-foreground">Working tree is clean</p>
                  <p className="text-sm mt-1">Make changes in the target repository to see live semantic extraction.</p>
                </div>
              ) : (
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                  {/* File Categories */}
                  <div className="space-y-4">
                    <h4 className="text-xs uppercase tracking-wider text-muted-foreground font-semibold">File Categories</h4>
                    
                    {intelligence.file_types?.logic?.length > 0 && (
                      <div className="p-3 rounded-lg border border-border bg-background">
                        <span className="text-xs text-primary font-mono mb-2 block">Logic ({intelligence.file_types.logic.length})</span>
                        <div className="flex flex-wrap gap-2">
                          {intelligence.file_types.logic.map((f: string) => <span key={f} className="text-xs bg-secondary px-2 py-1 rounded truncate max-w-full">{f}</span>)}
                        </div>
                      </div>
                    )}
                    
                    {intelligence.file_types?.config?.length > 0 && (
                      <div className="p-3 rounded-lg border border-border bg-background">
                        <span className="text-xs text-amber-400 font-mono mb-2 block">Config ({intelligence.file_types.config.length})</span>
                        <div className="flex flex-wrap gap-2">
                          {intelligence.file_types.config.map((f: string) => <span key={f} className="text-xs bg-secondary px-2 py-1 rounded truncate max-w-full">{f}</span>)}
                        </div>
                      </div>
                    )}

                    {intelligence.infrastructure_changes?.length > 0 && (
                      <div className="p-3 rounded-lg border border-rose-500/30 bg-rose-500/5">
                        <span className="text-xs text-rose-400 font-mono flex items-center gap-2 mb-2"><AlertCircle className="w-3 h-3"/> Infrastructure Changed</span>
                        <div className="flex flex-wrap gap-2">
                          {intelligence.infrastructure_changes.map((f: string) => <span key={f} className="text-xs bg-rose-500/20 text-rose-300 px-2 py-1 rounded">{f}</span>)}
                        </div>
                      </div>
                    )}
                  </div>

                  {/* Semantic Meta */}
                  <div className="space-y-4">
                    <h4 className="text-xs uppercase tracking-wider text-muted-foreground font-semibold">Semantic Mappings</h4>

                    {intelligence.signatures_added?.length > 0 && (
                      <div className="p-3 rounded-lg border border-border bg-background">
                        <span className="text-xs text-emerald-400 font-mono mb-2 block">Signatures Added</span>
                        <ul className="space-y-1">
                          {intelligence.signatures_added.map((f: string, i: number) => <li key={i} className="text-xs font-mono text-muted-foreground truncate">{f}</li>)}
                        </ul>
                      </div>
                    )}

                    {intelligence.dependencies_added?.length > 0 && (
                      <div className="p-3 rounded-lg border border-border bg-background">
                        <span className="text-xs text-amber-400 font-mono mb-2 block">Dependencies Requested</span>
                        <ul className="space-y-1">
                          {intelligence.dependencies_added.map((f: string, i: number) => <li key={i} className="text-xs font-mono text-muted-foreground truncate">{f}</li>)}
                        </ul>
                      </div>
                    )}
                    
                    {intelligence.network_outbound?.length > 0 && (
                      <div className="p-3 rounded-lg border border-rose-500/30 bg-rose-500/5">
                        <span className="text-xs text-rose-400 font-mono mb-2 block">Network Outbound Detected</span>
                        <ul className="space-y-1">
                          {intelligence.network_outbound.map((f: string, i: number) => <li key={i} className="text-xs font-mono text-rose-300 truncate">{f}</li>)}
                        </ul>
                      </div>
                    )}
                  </div>
                </div>
              )}
            </div>
          </div>
        </div>

        {/* API Playground */}
        <div className="p-6 rounded-xl border border-border bg-card shadow-sm mt-6">
          <h3 className="font-semibold text-lg flex items-center gap-2 mb-4">
            <Terminal className="w-5 h-5 text-primary" />
            API Playground — Headless Telemetry
          </h3>
          <p className="text-sm text-muted-foreground mb-4">Test the raw JSON output of the bash engine instantly. Paste an absolute path to any local git repository.</p>
          <div className="flex gap-4">
            <input 
              type="text" 
              id="pg-input"
              className="flex-1 bg-background border border-border rounded-lg px-4 py-2 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-primary/50"
              placeholder="/Users/fab/Documents/git/some-repo" 
              defaultValue="/Users/fab/Documents/git/gitoma"
            />
            <button 
              onClick={async () => {
                const btn = document.getElementById('pg-btn') as HTMLButtonElement;
                const input = document.getElementById('pg-input') as HTMLInputElement;
                const out = document.getElementById('pg-out');
                if(!btn || !input || !out) return;
                
                btn.disabled = true;
                btn.innerHTML = "Executing...";
                out.innerHTML = "Running out-of-band bash analysis...";
                
                try {
                  const t0 = performance.now();
                  const res = await fetch(`/analyze?path=${encodeURIComponent(input.value)}`);
                  const data = await res.json();
                  const t1 = performance.now();
                  out.innerHTML = `// Executed in ${(t1-t0).toFixed(2)}ms\n` + JSON.stringify(data, null, 2);
                } catch(e) {
                  out.innerHTML = String(e);
                }
                
                btn.disabled = false;
                btn.innerHTML = "Execute Analysis";
              }}
              id="pg-btn"
              className="px-6 py-2 bg-primary text-primary-foreground rounded-lg font-medium hover:bg-primary/90 transition-colors"
            >
              Execute Analysis
            </button>
          </div>
          <pre id="pg-out" className="mt-4 p-4 rounded-lg bg-background border border-border text-xs font-mono text-muted-foreground overflow-x-auto max-h-96">
            // Output will appear here...
          </pre>
        </div>

      </div>
    </div>
  );
}
