# Semantic Mappings & Analyzers

The `intelligence` block goes beyond counters: it tells an agent *what kind*
of change a diff represents.

## Built-in extractors

All extractors run in pure bash/awk from the unified diff; output shapes are
arrays of strings unless noted.

| Field                               | Detects                                                     |
|-------------------------------------|-------------------------------------------------------------|
| `file_types.logic`                  | `.go .js .jsx .ts .tsx .py .sh .bash .rb .php .java .c .cpp .rs .html .css` |
| `file_types.config`                 | `.yml .yaml .json .toml .ini .env .conf`                    |
| `file_types.docs`                   | `.md .txt .csv .pdf`                                        |
| `file_types.media`                  | `.png .jpg .jpeg .svg .gif .webp .ico`                      |
| `infrastructure_changes`            | `Dockerfile`, `docker-compose.yml`, `package.json`, `go.mod`, `requirements.txt`, `Makefile`, `.github/workflows/*` |
| `schema_mutations`                  | added lines matching `CREATE/ALTER/DROP TABLE`, `CREATE INDEX` (case-insensitive) |
| `network_outbound`                  | added lines calling `fetch(`, `http.Get(`, `axios.`, `requests.get|post`, `curl …` |
| `signatures_added`                  | added lines introducing `def `, `func `, `class `, `function ` |
| `dependencies_added`                | added lines starting with `import`, `require`, `include`, `from` |
| `syntax_valid` / `syntax_invalid`   | bash, JSON, Python files quick-compiled (per diff)          |

Each list is capped at 10 entries; the counts in `metrics.*` are the
authoritative totals.

## Violations

Per-line provenance for `security` and `debt` findings, extracted by a
pure-bash state machine that parses the unified diff and maps each matched
added line back to `(file, new_line_number)`. Each entry is then blamed via
`git blame --porcelain -L N,N`:

```json
{
  "kind":    "security",
  "file":    "src/api/auth.py",
  "line":    42,
  "text":    "API_KEY = \"sk-...\"",
  "blame": {
    "commit":      "uncommitted",
    "author":      "",
    "author_time": ""
  }
}
```

Blame semantics:

- `commit: "uncommitted"` — the line has never been committed (new file,
  or a fresh addition in the current working tree). This is the normal
  outcome when `--diff=head`/`--diff=staged`/`--diff=working` surface
  user-in-progress edits.
- a 12-char commit hash — the matched line existed verbatim in HEAD and
  was preserved through the current edit; the blame identifies the
  original author.

## Pluggable analyzers

Everything inside `analyzers/` that is executable is a pluggable analyzer
invoked per analysis. Protocol:

```
analyzers/NAME <TARGET_ABS> <DIFF_MODE>      # stdin = unified diff
```

Output (stdout): one JSON object

```json
{
  "name":    "example",
  "version": "0.0.1",
  "findings": [
    {
      "severity": "critical|high|medium|low|info",
      "kind":     "security|debt|bug|perf|style|other",
      "rule_id":  "pkg.rule.name",
      "file":     "relative/path",
      "line":     42,
      "message":  "short human summary",
      "text":     "offending source (optional)"
    }
  ]
}
```

Exit non-zero → the engine logs `analyzer output invalid` and skips the
analyzer (no fatal error). Findings at `critical`/`high` escalate
`.check.level` the same way built-in signals do.

### Reference implementations

#### `analyzers/semgrep.sh`

Thin adapter around the `semgrep` CLI. Only scans the files touched by the
current diff (fast path), maps Semgrep's `ERROR`/`WARNING`/`INFO` and
`metadata.impact` to Occam's severity taxonomy, translates
`metadata.category` to Occam's `kind`.

Graceful degrade: emits
`{"skipped": "semgrep not installed"}` and exits 0 when the binary is
missing.

Config: `OCCAM_SEMGREP_CONFIG=p/security-audit` (default `auto`),
`OCCAM_SEMGREP_TIMEOUT=20`.

#### `analyzers/python-ast.py`

Uses the stdlib `ast` module — no external dependency, ship-and-forget.
Emits:

| Rule ID                             | Severity                | Triggers on                                         |
|-------------------------------------|-------------------------|-----------------------------------------------------|
| `python-ast/syntax-error`           | high                    | file fails `ast.parse`                              |
| `python-ast/high-cyclomatic`        | medium (≥10), high (≥20)| per-function McCabe score                           |
| `python-ast/eval-usage`             | critical                | `eval(...)` call                                    |
| `python-ast/exec-usage`             | critical                | `exec(...)` call                                    |
| `python-ast/subprocess-shell-true`  | high                    | `subprocess.*(..., shell=True)`                     |
| `python-ast/pickle-load`            | high                    | `pickle.load(...)` or `pickle.loads(...)`           |

A full multi-language tree-sitter analyzer is a natural next step — this
file is the template.

## Disabling analyzers

| Variable                  | Effect                              |
|---------------------------|-------------------------------------|
| `OCCAM_NO_ANALYZERS=1`    | skip all `analyzers/*`              |
| `OCCAM_ANALYZER_TIMEOUT=N`| kill any analyzer after N seconds   |

When analyzers are disabled, `intelligence.analyzers` is an empty array and
`check.level` is derived from the built-in signals only.
