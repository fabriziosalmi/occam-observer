#!/usr/bin/env bash
# =============================================================================
# telemetry_observer.sh — Occam Observer engine
# =============================================================================
# TUI     : Alternate Screen Buffer · Zero-Flicker · Braille Spinner
#           Unicode Box Drawing · 256-color · Progress Bar
# Engine  : YAML config · OS watcher · 5+check vector metrics · Health Score
# API     : Go HTTP gateway (api/main.go) · SQLite TSDB · O(1) cache GETs
# CLI     : --json | --check --fail-on=LEVEL | --diff=MODE | --validate
# Plugins : analyzers/*  (Semgrep, Python AST, custom) — stdin diff → JSON
# Deps    : git, bash ≥ 3.2, jq, sqlite3, fswatch|inotifywait, go (for API)
# =============================================================================
set -euo pipefail

readonly OCCAM_VERSION="0.2.1"

# ── ANSI / COLOR PALETTE ─────────────────────────────────────────────────────
readonly RST="\033[0m"   BLD="\033[1m"   DIM="\033[2m"   REV="\033[7m"
readonly R="\033[0;31m"  RB="\033[1;31m" G="\033[1;32m"  Y="\033[1;33m"
readonly B="\033[1;34m"  C="\033[1;36m"  W="\033[1;37m"
readonly BGR="\033[1;41m" BGG="\033[1;42m" BGY="\033[1;43m"
# 256-color helpers
c256()  { printf "\033[38;5;%sm" "$1"; }
bg256() { printf "\033[48;5;%sm" "$1"; }
# Accent colors (256)
CYAN2="$(c256 51)" GRAY="$(c256 240)" TEAL="$(c256 37)"
GOLD="$(c256 220)" ROSE="$(c256 196)" LIME="$(c256 82)"
PURPLE="$(c256 135)"

# ── PANEL GEOMETRY ────────────────────────────────────────────────────────────
PANEL_W=72          # visual width including borders
INNER_W=$((PANEL_W - 4))   # usable inner width (2 border + 2 padding)
SPINNER_ROW=22      # terminal row where the spinner lives
SPINNER_COL=6       # terminal col

# ── CONFIG DEFAULTS ───────────────────────────────────────────────────────────
TARGET_PATH="" THRESHOLD_MASS_WARN=150 THRESHOLD_MASS_CRITICAL=300
THRESHOLD_ENTROPY_WARN=5 THRESHOLD_ENTROPY_CRITICAL=10
REGEX_SECURITY="password|secret|token|api_key|aws_access|private_key|passwd|auth_token"
REGEX_COMPLEXITY="if|for|while|switch|catch|elif|unless|rescue"
REGEX_HYGIENE='todo|fixme|console\.log|print\(|debugger|binding\.pry|dd\(|var_dump'
REGEX_TEST_FILES='test|spec|_test\.|\.test\.|\.spec\.'
BELL_ON_CRITICAL="true" STARTUP_DELAY=1
OS_WATCHER="" SPINNER_PID="" CONFIG_FILE_USED=""

# ── API SERVER DEFAULTS ───────────────────────────────────────────────────────
API_PORT=9999
CACHE_FILE="/tmp/occam_state.json"
API_PID=""
NC_FLAVOR=""   # detected at runtime: 'bsd' or 'gnu'

# ── STRUCTURED LOGGING (JSON → stderr) ───────────────────────────────────────
# log_json LEVEL MSG [key=value ...] — emit one RFC 8259 event to stderr.
# Suppressed when $OCCAM_LOG=quiet (default in TUI mode to keep the screen clean).
log_json() {
    [ "${OCCAM_LOG:-info}" = "quiet" ] && return 0
    local level="$1" msg="$2"; shift 2 || true
    local ts; ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    local fields=""
    # Propagate trace_id from env so every engine event can be correlated with
    # the Go gateway's request log (same X-Trace-Id value).
    if [ -n "${OCCAM_TRACE_ID:-}" ]; then
        fields=",\"trace_id\":\"$(json_escape_str "$OCCAM_TRACE_ID")\""
    fi
    while [ $# -gt 0 ]; do
        local kv="$1"; shift
        local k="${kv%%=*}" v="${kv#*=}"
        v="$(json_escape_str "$v")"
        fields="${fields},\"${k}\":\"${v}\""
    done
    printf '{"ts":"%s","level":"%s","msg":"%s"%s}\n' \
        "$ts" "$(json_escape_str "$level")" "$(json_escape_str "$msg")" "$fields" >&2
}

# ── SEVERITY MODEL ───────────────────────────────────────────────────────────
# Numeric ordering so levels can be compared with -ge / -le.
sev_rank() {
    case "$1" in
        none)     echo 0 ;;
        low)      echo 1 ;;
        medium)   echo 2 ;;
        high)     echo 3 ;;
        critical) echo 4 ;;
        *)        echo -1 ;;
    esac
}

# compute_severity — derive (level, reasons[]) from the current metric set.
# Stdout: two lines. Line 1: the level. Line 2: JSON array of reason strings.
# Arguments (positional, to keep bash 3.2 compatible):
#   $1 sec_count  $2 insertions  $3 complexity  $4 hygiene_count
#   $5 infra_nonempty (1/0)  $6 schema_nonempty (1/0)  $7 network_nonempty (1/0)
#   $8 syntax_invalid_nonempty (1/0)
compute_severity() {
    local sec="$1" ins="$2" comp="$3" hygi="$4"
    local infra="$5" schema="$6" net="$7" synbad="$8"
    local level="none" reasons=""
    _add_reason() {
        local r; r="$(json_escape_str "$1")"
        if [ -z "$reasons" ]; then reasons="\"$r\""
        else reasons="$reasons,\"$r\""; fi
    }
    _promote() {
        if [ "$(sev_rank "$1")" -gt "$(sev_rank "$level")" ]; then level="$1"; fi
    }

    # CRITICAL — these never overlap with lower bands for the same metric.
    if [ "$sec"    -gt 0 ]; then _promote critical; _add_reason "security_violations=$sec"; fi
    if [ "$synbad" -gt 0 ]; then _promote critical; _add_reason "syntax_invalid_files_present"; fi

    # HIGH / MEDIUM bands for mass and entropy are mutually exclusive so
    # a single metric contributes exactly one reason; the overall level is
    # still the max via _promote. Without the `-le CRITICAL` guard, a mass
    # of 500 would emit both "mass=500>300" and "mass=500>150".
    if [ "$ins" -gt "$THRESHOLD_MASS_CRITICAL" ]; then
        _promote high; _add_reason "mass=$ins>${THRESHOLD_MASS_CRITICAL}"
    elif [ "$ins" -gt "$THRESHOLD_MASS_WARN" ]; then
        _promote medium; _add_reason "mass=$ins>${THRESHOLD_MASS_WARN}"
    fi
    if [ "$comp" -gt "$THRESHOLD_ENTROPY_CRITICAL" ]; then
        _promote high; _add_reason "entropy=$comp>${THRESHOLD_ENTROPY_CRITICAL}"
    elif [ "$comp" -gt "$THRESHOLD_ENTROPY_WARN" ]; then
        _promote medium; _add_reason "entropy=$comp>${THRESHOLD_ENTROPY_WARN}"
    fi
    # Categorical HIGH signals (presence flags, no band)
    if [ "$infra"  -gt 0 ]; then _promote high; _add_reason "infrastructure_changes_present"; fi
    if [ "$schema" -gt 0 ]; then _promote high; _add_reason "schema_mutations_present"; fi

    # Debt ladder: same exclusivity between medium (>=5) and low (<5 but >0).
    if [ "$hygi" -ge 5 ]; then
        _promote medium; _add_reason "debt_issues=$hygi>=5"
    elif [ "$hygi" -gt 0 ]; then
        _promote low;    _add_reason "debt_issues=$hygi"
    fi
    # LOW categorical
    if [ "$net"  -gt 0 ]; then _promote low; _add_reason "network_outbound_present"; fi

    printf '%s\n[%s]\n' "$level" "$reasons"
}

# ── JSON ESCAPE (RFC 8259) ───────────────────────────────────────────────────
# json_escape_str STRING — print the RFC 8259-safe body of a JSON string
# (without surrounding quotes). Escapes backslash, double quote, and the
# C0 control characters (\b \f \n \r \t plus \u00XX for the rest).
# Order matters: backslash MUST be handled first or it double-escapes later subs.
json_escape_str() {
    local s="${1-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\b'/\\b}"
    s="${s//$'\f'/\\f}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\n'/\\n}"
    # Strip any remaining C0 controls (rare in diff output, but would break parsers).
    # Using LC_ALL=C + tr is faster than a per-char loop in pure bash.
    s="$(LC_ALL=C printf '%s' "$s" | tr -d '\000-\010\013\016-\037\177')"
    printf '%s' "$s"
}

# ── YAML PARSER (awk FSM — supporta valori inline e array YAML) ──────────────
# yaml_get FILE KEY
# ─ Scalar  : "key: value"       → restituisce "value" pulito
# ─ Array   : "key:\n  - a\n  - b" → restituisce "a|b" (ERE-ready)
# Compatibile con bash 3.2 + awk POSIX (macOS e Linux).
yaml_get() {
    local file="$1" key="$2"
    awk -v key="$key" '
    BEGIN { found=0; result=""; arr="" }
    /^[[:space:]]*#/ { next }
    $0 ~ "^[[:space:]]*" key "[[:space:]]*:" {
        found = 1
        # Estrai valore dopo i due punti
        sub("^[[:space:]]*" key "[[:space:]]*:[[:space:]]*", "")
        val = $0
        gsub(/#.*$/, "", val)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
        gsub(/^["'"'"']|["'"'"']$/, "", val)
        result = val
        next
    }
    found == 1 && /^[[:space:]]+-[[:space:]]/ {
        item = $0
        gsub(/^[[:space:]]+-[[:space:]]+/, "", item)
        gsub(/#.*$/, "", item)
        gsub(/^["'"'"']|["'"'"']$/, "", item)
        gsub(/[[:space:]]+$/, "", item)
        if (item != "") arr = (arr == "") ? item : arr "|" item
        next
    }
    found == 1 && /^[^[:space:]-]/ { found = 0 }
    END { print (arr != "") ? arr : result }
    ' "$file" 2>/dev/null
}

load_config() {
    local cfg="${1:-}" cli_tgt="${2:-}" script_dir val
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local main_file=""
    if   [ -n "$cfg" ]; then main_file="$cfg"
    elif [ -f "${script_dir}/config/main.yml" ]; then main_file="${script_dir}/config/main.yml"
    fi

    # Set internal defaults
    THRESHOLD_MASS_WARN=150
    THRESHOLD_MASS_CRITICAL=300
    THRESHOLD_ENTROPY_WARN=5
    THRESHOLD_ENTROPY_CRITICAL=10
    BELL_ON_CRITICAL=true
    STARTUP_DELAY=2
    API_PORT=9999

    if [ -n "$main_file" ]; then
        CONFIG_FILE_USED="$main_file"
        val="$(yaml_get "$main_file" "target_path")";                [ -n "$val" ] && TARGET_PATH="$val"
        val="$(yaml_get "$main_file" "threshold_mass_warn")";        [ -n "$val" ] && THRESHOLD_MASS_WARN="$val"
        val="$(yaml_get "$main_file" "threshold_mass_critical")";    [ -n "$val" ] && THRESHOLD_MASS_CRITICAL="$val"
        val="$(yaml_get "$main_file" "threshold_entropy_warn")";     [ -n "$val" ] && THRESHOLD_ENTROPY_WARN="$val"
        val="$(yaml_get "$main_file" "threshold_entropy_critical")"; [ -n "$val" ] && THRESHOLD_ENTROPY_CRITICAL="$val"
        val="$(yaml_get "$main_file" "bell_on_critical")";           [ -n "$val" ] && BELL_ON_CRITICAL="$val"
        val="$(yaml_get "$main_file" "startup_delay")";              [ -n "$val" ] && STARTUP_DELAY="$val"
        val="$(yaml_get "$main_file" "api_port")";                   [ -n "$val" ] && API_PORT="$val"
    else
        CONFIG_FILE_USED="(defaults)"
    fi

    # Load regex patterns dynamically from config/rules/*.yml
    local rules_dir="${script_dir}/config/rules"
    if [ -d "$rules_dir" ]; then
        val="$(yaml_get "${rules_dir}/security.yml" "patterns")"; [ -n "$val" ] && REGEX_SECURITY="$val"
        val="$(yaml_get "${rules_dir}/entropy.yml" "patterns")";  [ -n "$val" ] && REGEX_COMPLEXITY="\b(${val})\b"
        val="$(yaml_get "${rules_dir}/debt.yml" "patterns")";     [ -n "$val" ] && REGEX_HYGIENE="$val"
        
        val="$(yaml_get "${rules_dir}/tests.yml" "patterns_validation")"
        [ -z "$val" ] && val="$(yaml_get "${rules_dir}/tests.yml" "patterns")"
        [ -n "$val" ] && REGEX_TEST_FILES="$val"
    fi

    [ -n "$cli_tgt" ] && TARGET_PATH="$cli_tgt"
    return 0
}

# ── CONFIG VALIDATION ────────────────────────────────────────────────────────
# Lightweight constraint checker for config/main.yml and config/rules/*.yml.
# Contract documented in config/schema.json. Returns 0 if valid, >0 on errors.
# Each violation is emitted as a structured log event on stderr.
validate_config() {
    local cfg="$1" errors=0

    _vc_int() {
        local key="$1" val="$2" min="$3" max="$4"
        if [[ ! "$val" =~ ^[0-9]+$ ]]; then
            log_json error "config: not an integer" "key=$key" "value=$val" "file=$cfg"
            errors=$((errors+1)); return
        fi
        if [ "$val" -lt "$min" ] || [ "$val" -gt "$max" ]; then
            log_json error "config: value out of range" "key=$key" "value=$val" "min=$min" "max=$max" "file=$cfg"
            errors=$((errors+1))
        fi
    }
    _vc_bool() {
        local key="$1" val="$2"
        case "$val" in true|false) ;; *)
            log_json error "config: not boolean" "key=$key" "value=$val" "file=$cfg"
            errors=$((errors+1)) ;;
        esac
    }
    _vc_regex() {
        local key="$1" val="$2" file="$3"
        # grep -E: exit 0 on match, 1 on no match, 2 on invalid pattern.
        printf 'probe' | grep -iE "$val" >/dev/null 2>&1
        [ $? -ge 2 ] && { log_json error "config: invalid ERE pattern" "key=$key" "file=$file"; errors=$((errors+1)); }
    }

    local v
    if [ -f "$cfg" ]; then
        v="$(yaml_get "$cfg" threshold_mass_warn)";        [ -n "$v" ] && _vc_int threshold_mass_warn        "$v" 1 1000000
        v="$(yaml_get "$cfg" threshold_mass_critical)";    [ -n "$v" ] && _vc_int threshold_mass_critical    "$v" 1 1000000
        v="$(yaml_get "$cfg" threshold_entropy_warn)";     [ -n "$v" ] && _vc_int threshold_entropy_warn     "$v" 1 10000
        v="$(yaml_get "$cfg" threshold_entropy_critical)"; [ -n "$v" ] && _vc_int threshold_entropy_critical "$v" 1 10000
        v="$(yaml_get "$cfg" bell_on_critical)";           [ -n "$v" ] && _vc_bool bell_on_critical "$v"
        v="$(yaml_get "$cfg" startup_delay)";              [ -n "$v" ] && _vc_int startup_delay "$v" 0 60
        v="$(yaml_get "$cfg" api_port)";                   [ -n "$v" ] && _vc_int api_port "$v" 1 65535

        # Cross-checks: warn before critical
        local mw mc ew ec
        mw="$(yaml_get "$cfg" threshold_mass_warn)"
        mc="$(yaml_get "$cfg" threshold_mass_critical)"
        if [[ "$mw" =~ ^[0-9]+$ ]] && [[ "$mc" =~ ^[0-9]+$ ]] && [ "$mw" -ge "$mc" ]; then
            log_json error "config: threshold_mass_warn must be < threshold_mass_critical" "warn=$mw" "critical=$mc" "file=$cfg"
            errors=$((errors+1))
        fi
        ew="$(yaml_get "$cfg" threshold_entropy_warn)"
        ec="$(yaml_get "$cfg" threshold_entropy_critical)"
        if [[ "$ew" =~ ^[0-9]+$ ]] && [[ "$ec" =~ ^[0-9]+$ ]] && [ "$ew" -ge "$ec" ]; then
            log_json error "config: threshold_entropy_warn must be < threshold_entropy_critical" "warn=$ew" "critical=$ec" "file=$cfg"
            errors=$((errors+1))
        fi
    fi

    # Rules files — each "patterns" key must be a valid ERE.
    local script_dir; script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local rules_dir="${script_dir}/config/rules"
    if [ -d "$rules_dir" ]; then
        for f in security.yml entropy.yml debt.yml tests.yml; do
            local path="${rules_dir}/${f}"
            [ -f "$path" ] || continue
            v="$(yaml_get "$path" patterns)"
            [ -n "$v" ] && _vc_regex patterns "$v" "$path"
            if [ "$f" = "tests.yml" ]; then
                v="$(yaml_get "$path" patterns_validation)"
                [ -n "$v" ] && _vc_regex patterns_validation "$v" "$path"
            fi
        done
    fi
    return $errors
}

# ── OS DETECTION ──────────────────────────────────────────────────────────────
die() { tui_exit; printf "\n${RB}[FATAL]${RST} %b\n" "$1" >&2; exit 1; }

detect_os_watcher() {
    for p in /opt/homebrew/bin /usr/local/bin; do
        [[ -d "$p" && ":$PATH:" != *":$p:"* ]] && export PATH="${p}:${PATH}"
    done
    case "$(uname -s)" in
        Darwin)
            command -v fswatch &>/dev/null || die "'fswatch' non trovato.\n  brew install fswatch"
            OS_WATCHER="fswatch" ;;
        Linux)
            command -v inotifywait &>/dev/null || die "'inotifywait' non trovato.\n  sudo apt-get install inotify-tools"
            OS_WATCHER="inotifywait" ;;
        *) die "OS non supportato: $(uname -s)" ;;
    esac
}

validate_target() {
    [ -n "$TARGET_PATH" ]          || die "No target path. Set target_path in config/main.yml or via CLI."
    [ -d "$TARGET_PATH" ]          || die "Path does not exist: '${TARGET_PATH}'"
    [ -d "${TARGET_PATH}/.git" ]   || die "Not a Git repository: '${TARGET_PATH}'"
    git -C "$TARGET_PATH" rev-parse HEAD &>/dev/null || die "Repo has no commits. Create at least an initial commit."
}

# ── TUI: ALTERNATE SCREEN BUFFER ─────────────────────────────────────────────
tui_init() {
    tput smcup  2>/dev/null || true   # enter alternate screen
    tput civis  2>/dev/null || true   # hide cursor
    printf "\033[H\033[2J"            # clear alternate screen
}
tui_exit() {
    stop_spinner
    tput cvvis  2>/dev/null || true   # restore cursor
    tput rmcup  2>/dev/null || true   # exit alternate screen
}

# ── TUI: SPINNER ──────────────────────────────────────────────────────────────
SPINNER_FRAMES='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

start_spinner() {
    local row="${1:-$SPINNER_ROW}" col="${2:-$SPINNER_COL}" status="${3:-Listening for filesystem events…}"
    (   local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0 n=10
        trap 'exit 0' SIGTERM SIGINT
        while true; do
            printf "\033[%d;%dH${CYAN2}${BLD}%s${RST} ${DIM}%s${RST}" \
                "$row" "$col" "${frames:$i:1}" "$status"
            i=$(( (i+1) % n ))
            sleep 0.1
        done
    ) &
    SPINNER_PID=$!
}

stop_spinner() {
    if [[ -n "${SPINNER_PID:-}" ]]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
    fi
}

# ── PERSISTENCE (SQLite TSDB — optional) ──────────────────────────────────────
# Append-only time-series of every analysis. Used by the `/trend` endpoint so
# agents can ask "how has this repo's health moved over the last N minutes?".
# Silently no-ops when sqlite3 or jq is unavailable — persistence is never
# allowed to break the TUI or the --json consumer.
OCCAM_DATA_DIR="${OCCAM_DATA_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/occam-observer}"
OCCAM_DB="${OCCAM_DB:-${OCCAM_DATA_DIR}/snapshots.db}"
OCCAM_DB_READY=0

ensure_db() {
    [ "$OCCAM_DB_READY" = "1" ] && return 0
    command -v sqlite3 >/dev/null 2>&1 || return 1
    mkdir -p "$(dirname "$OCCAM_DB")" 2>/dev/null || return 1
    sqlite3 "$OCCAM_DB" <<'SQL' >/dev/null 2>&1 || return 1
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
CREATE TABLE IF NOT EXISTS snapshots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    target TEXT NOT NULL,
    branch TEXT,
    commit_sha TEXT,
    health_score INTEGER,
    security_violations INTEGER,
    mass_insertions INTEGER,
    mass_deletions INTEGER,
    mass_files_changed INTEGER,
    entropy_nodes INTEGER,
    test_files_modified INTEGER,
    debt_issues INTEGER,
    check_level TEXT,
    diff_mode TEXT,
    raw_json TEXT
);
CREATE INDEX IF NOT EXISTS idx_snapshots_target_ts ON snapshots(target, ts DESC);
CREATE INDEX IF NOT EXISTS idx_snapshots_ts        ON snapshots(ts DESC);
SQL
    OCCAM_DB_READY=1
}

persist_snapshot() {
    [ "${OCCAM_NO_PERSIST:-0}" = "1" ] && return 0
    local cache_file="$1"
    [ -s "$cache_file" ] || return 0
    command -v sqlite3 >/dev/null 2>&1 || return 0
    command -v jq      >/dev/null 2>&1 || return 0
    ensure_db || return 0
    # Build the INSERT with jq so every string literal is SQL-escaped
    # (single quotes doubled). The raw_json column stores the full payload for
    # forensic drill-down without another roundtrip.
    local sql
    sql="$(jq -r '
      def sqlstr: tostring | gsub("\u0027"; "\u0027\u0027") | "\u0027" + . + "\u0027";
      "INSERT INTO snapshots(ts,target,branch,commit_sha,health_score,security_violations,mass_insertions,mass_deletions,mass_files_changed,entropy_nodes,test_files_modified,debt_issues,check_level,diff_mode,raw_json) VALUES("
      + ((.timestamp                  // "") | sqlstr) + ","
      + ((.target                     // "") | sqlstr) + ","
      + ((.branch                     // "") | sqlstr) + ","
      + ((.commit                     // "") | sqlstr) + ","
      + ((.health_score               // 0 ) | tostring) + ","
      + ((.metrics.security_violations// 0 ) | tostring) + ","
      + ((.metrics.mass_insertions    // 0 ) | tostring) + ","
      + ((.metrics.mass_deletions     // 0 ) | tostring) + ","
      + ((.metrics.mass_files_changed // 0 ) | tostring) + ","
      + ((.metrics.entropy_nodes      // 0 ) | tostring) + ","
      + ((.metrics.test_files_modified// 0 ) | tostring) + ","
      + ((.metrics.debt_issues        // 0 ) | tostring) + ","
      + ((.check.level                // "none") | sqlstr) + ","
      + ((.diff_mode                  // "head") | sqlstr) + ","
      + ((. | tostring)                          | sqlstr)
      + ");"
    ' "$cache_file" 2>/dev/null)" || return 0
    [ -z "$sql" ] && return 0
    printf '%s\n' "$sql" | sqlite3 "$OCCAM_DB" >/dev/null 2>&1 || true
}

# ── API: JSON CACHE WRITER (Write-Through, chiamato dopo ogni analisi) ────────
# write_cache — serialize the state to $CACHE_FILE (RAM disk on /tmp)
write_cache() {
    local is_idle="${1}" branch="${2}" commit="${3}" ts="${4}"
    local sec="${5}" ins="${6}" del="${7}" files="${8}"
    local comp="${9}" test_f="${10}" hygi="${11}" health="${12}"
    local sec_snip="${13:-}" hygi_snip="${14:-}"
    local intel_json="{}" git_json="{}"
    local check_level="none" check_reasons="[]" diff_mode="${DIFF_MODE:-head}"
    local perf_json="${PERF_JSON:-{}}"
    [ $# -ge 15 ] && intel_json="${15}"
    [ $# -ge 16 ] && git_json="${16}"
    [ $# -ge 17 ] && check_level="${17}"
    [ $# -ge 18 ] && check_reasons="${18}"
    [ $# -ge 19 ] && perf_json="${19}"
    # Atomic write: write to tmp, then atomic mv to prevent partial reads.
    # 0600 set at CREATE time (umask in a subshell) — there's no window between
    # mktemp and chmod for another process to slurp secret snippets. BSD mktemp
    # has no -m flag, so umask is the portable route.
    local tmp_file; tmp_file="$(umask 0077; mktemp /tmp/occam_state_XXXXXX.json)"

    # RFC 8259 escape all string fields. User-controlled data (branch names,
    # commit hashes, paths) can contain quotes/backslashes and would otherwise
    # corrupt the JSON payload that downstream agents consume.
    local e_ts e_branch e_commit e_target e_sec e_hygi
    e_ts="$(json_escape_str "$ts")"
    e_branch="$(json_escape_str "$branch")"
    e_commit="$(json_escape_str "$commit")"
    e_target="$(json_escape_str "$TARGET_PATH")"
    e_sec="$(json_escape_str "$sec_snip")"
    e_hygi="$(json_escape_str "$hygi_snip")"

    local e_diff_mode; e_diff_mode="$(json_escape_str "$diff_mode")"
    local e_level; e_level="$(json_escape_str "$check_level")"
    local e_trace; e_trace="$(json_escape_str "${OCCAM_TRACE_ID:-}")"

    cat > "$tmp_file" << ENDJSON
{
  "version": "${OCCAM_VERSION}",
  "trace_id": "${e_trace}",
  "timestamp": "${e_ts}",
  "branch": "${e_branch}",
  "commit": "${e_commit}",
  "target": "${e_target}",
  "diff_mode": "${e_diff_mode}",
  "is_idle": ${is_idle},
  "metrics": {
    "security_violations": ${sec},
    "mass_insertions": ${ins},
    "mass_deletions": ${del},
    "mass_files_changed": ${files},
    "entropy_nodes": ${comp},
    "test_files_modified": ${test_f},
    "debt_issues": ${hygi}
  },
  "snippets": {
    "security": "${e_sec}",
    "debt": "${e_hygi}"
  },
  "git": ${git_json},
  "intelligence": ${intel_json},
  "health_score": ${health},
  "check": {
    "level": "${e_level}",
    "reasons": ${check_reasons}
  },
  "performance": ${perf_json},
  "thresholds": {
    "mass_warn": ${THRESHOLD_MASS_WARN},
    "mass_critical": ${THRESHOLD_MASS_CRITICAL},
    "entropy_warn": ${THRESHOLD_ENTROPY_WARN},
    "entropy_critical": ${THRESHOLD_ENTROPY_CRITICAL}
  }
}
ENDJSON
    mv "$tmp_file" "$CACHE_FILE"
}

# ── API: GO SERVER START/STOP ─────────────────────────────────────────────────
# The Go API Gateway replaces the legacy netcat server.
start_api_server() {
    local script_dir; script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if command -v go &>/dev/null && [ -f "${script_dir}/api/main.go" ]; then
        (
            cd "${script_dir}/api" || exit 0
            export API_PORT="$API_PORT"
            export CACHE_FILE="$CACHE_FILE"
            export ENGINE_SCRIPT="${script_dir}/telemetry_observer.sh"
            export OCCAM_DB="$OCCAM_DB"
            go run main.go > /dev/null 2>&1
        ) &
        API_PID=$!
    else
        API_PID=""
    fi
}

stop_api_server() {
    if [[ -n "${API_PID:-}" ]]; then
        kill "$API_PID" 2>/dev/null || true
        wait "$API_PID" 2>/dev/null || true
        API_PID=""
    fi
}

# ── TUI: BOX DRAWING PRIMITIVES ───────────────────────────────────────────────
# hline N char — print N repetitions of char
hline() { printf '%0.s'"$2" $(seq 1 "$1"); }

# box_top LABEL COLOR  — top border with embedded label
box_top() {
    local label=" ${2:-}${BLD}${1}${RST}${GRAY} " lpad=2
    local llen=$(( ${#1} + ${#2} + 1 ))   # approx visual len of label
    local rlen=$(( PANEL_W - lpad - llen - 3 ))
    printf "${GRAY}╭$(hline $lpad ─)${RST}${label}${GRAY}$(hline $rlen ─)╮${RST}\n"
}
box_bot() { printf "${GRAY}╰$(hline $((PANEL_W-2)) ─)╯${RST}\n"; }
box_div() { printf "${GRAY}├$(hline $((PANEL_W-2)) ─)┤${RST}\n"; }

# box_row TEXT_WITH_ANSI
# Usa \033[NG per saltare esattamente alla colonna del bordo destro (zero misalign con emoji)
box_row() {
    local text="$1"
    printf "${GRAY}│${RST}  %b\033[%dG${GRAY}│${RST}\n" "$text" "$PANEL_W"
}
box_empty() { printf "${GRAY}│\033[%dG│${RST}\n" "$PANEL_W"; }

# ── TUI: PROGRESS BAR ─────────────────────────────────────────────────────────
progress_bar() {
    local score="$1" width=30
    local filled=$(( score * width / 100 ))
    local empty=$(( width - filled ))
    local bar="" i
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty;  i++)); do bar+="░"; done
    local color
    if   [[ $score -ge 80 ]]; then color="${LIME}"
    elif [[ $score -ge 50 ]]; then color="${GOLD}"
    else                           color="${ROSE}"
    fi
    printf "%b%s%b" "$color" "$bar" "$RST"
}

score_label() {
    local s="$1"
    if   [[ $s -ge 80 ]]; then printf "${LIME}${BLD}GOOD${RST}"
    elif [[ $s -ge 50 ]]; then printf "${GOLD}${BLD}WARN${RST}"
    else                        printf "${ROSE}${BLD}POOR${RST}"
    fi
}

# metric_row ICON LABEL VALUE_TEXT VALUE_COLOR STATUS_ICON
metric_row() {
    local icon="$1" label="$2" val="$3" vcol="${4:-$RST}" sicon="${5:- }"
    local label_f; printf -v label_f "%-13s" "$label"
    local text="${icon}  ${DIM}${label_f}${RST}  ${sicon}  ${vcol}${BLD}${val}${RST}"
    box_row "$text"
}

# ── PLUGGABLE ANALYZERS ──────────────────────────────────────────────────────
# Contract for any executable dropped into analyzers/:
#
#   Invocation:  analyzers/NAME <TARGET_PATH> <DIFF_MODE>
#   Stdin:       the unified diff (so the analyzer can skip re-running `git diff`)
#   Stdout:      one JSON object matching:
#                  {"name": "...", "version": "...", "findings": [
#                     {"severity": "critical|high|medium|low|info",
#                      "kind":     "security|debt|bug|perf|style|other",
#                      "rule_id":  "...",
#                      "file":     "path/to/file",
#                      "line":     123,
#                      "message":  "human-readable summary",
#                      "text":     "offending source (optional)"}
#                  ]}
#   Exit code:   0 on success; non-zero means "analyzer failed" — the engine
#                logs + moves on without failing the whole analysis.
#
# Analyzers MUST complete within OCCAM_ANALYZER_TIMEOUT seconds (default 30)
# or they are killed; partial output is discarded so a hung analyzer never
# blocks agents.
OCCAM_ANALYZER_TIMEOUT="${OCCAM_ANALYZER_TIMEOUT:-30}"

run_analyzers() {
    local target="$1" diff_content="$2"
    local script_dir; script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local adir="${script_dir}/analyzers"
    if [ ! -d "$adir" ] || ! command -v jq >/dev/null 2>&1; then
        printf '[]'
        return 0
    fi

    # One-shot warn about missing timeout tooling so operators notice — a
    # hung analyzer here would stall the entire analysis.
    if [ "${_OCCAM_TIMEOUT_WARNED:-0}" = "0" ] \
       && ! command -v timeout  >/dev/null 2>&1 \
       && ! command -v gtimeout >/dev/null 2>&1; then
        log_json warn "no 'timeout' binary found — analyzers will run without a wall-clock limit" \
            "hint=brew install coreutils (macOS)"
        _OCCAM_TIMEOUT_WARNED=1
    fi

    local acc=""
    local a out name
    for a in "$adir"/*; do
        [ -x "$a" ] || continue
        name="$(basename "$a")"
        # Timeout: prefer GNU/macOS (homebrew coreutils) `timeout`; otherwise run
        # raw and trust the analyzer (a warn was emitted once above).
        if command -v timeout >/dev/null 2>&1; then
            out="$(printf '%s' "$diff_content" | timeout --kill-after=2 "$OCCAM_ANALYZER_TIMEOUT" "$a" "$target" "${DIFF_MODE:-head}" 2>/dev/null)"
        elif command -v gtimeout >/dev/null 2>&1; then
            out="$(printf '%s' "$diff_content" | gtimeout --kill-after=2 "$OCCAM_ANALYZER_TIMEOUT" "$a" "$target" "${DIFF_MODE:-head}" 2>/dev/null)"
        else
            out="$(printf '%s' "$diff_content" | "$a" "$target" "${DIFF_MODE:-head}" 2>/dev/null)"
        fi
        [ -z "$out" ] && { log_json warn "analyzer produced no output" "analyzer=$name"; continue; }
        printf '%s' "$out" | jq -e 'type == "object" and (.findings | type == "array")' >/dev/null 2>&1 || {
            log_json warn "analyzer output invalid" "analyzer=$name"; continue
        }
        if [ -z "$acc" ]; then acc="$out"
        else acc="$acc"$'\n'"$out"; fi
    done
    if [ -z "$acc" ]; then printf '[]'; return 0; fi
    printf '%s' "$acc" | jq -sc '.'
}

# analyzer_severity_counts ANALYZERS_JSON  → emits "CRIT|HIGH|MED|LOW" counts
analyzer_severity_counts() {
    local j="$1"
    command -v jq >/dev/null 2>&1 || { printf '0|0|0|0\n'; return; }
    local c h m l
    c="$(printf '%s' "$j" | jq '[.[].findings[]? | select(.severity=="critical")] | length' 2>/dev/null || echo 0)"
    h="$(printf '%s' "$j" | jq '[.[].findings[]? | select(.severity=="high")]     | length' 2>/dev/null || echo 0)"
    m="$(printf '%s' "$j" | jq '[.[].findings[]? | select(.severity=="medium")]   | length' 2>/dev/null || echo 0)"
    l="$(printf '%s' "$j" | jq '[.[].findings[]? | select(.severity=="low")]      | length' 2>/dev/null || echo 0)"
    printf '%s|%s|%s|%s\n' "${c:-0}" "${h:-0}" "${m:-0}" "${l:-0}"
}

# ── VIOLATION EXTRACTION + BLAME ──────────────────────────────────────────────
# extract_violations DIFF_CONTENT REGEX_SEC REGEX_HYG
# Emits one record per pattern hit on an added line:  kind|file|line_no|text
# line_no is the 1-based line in the post-diff (new) file. Pure-bash parsing
# (=~ ERE with nocasematch) because awk -v drops the backslash-escapes users
# put into their YAML regex patterns (e.g. "print\(").
extract_violations() {
    local diff="$1" rs="$2" rh="$3"
    local file="" new_line=0 line body n
    shopt -s nocasematch
    while IFS= read -r line; do
        case "$line" in
            "+++ /dev/null") file="" ;;
            "+++ b/"*)       file="${line#+++ b/}" ;;
            "+++ "*)         file="${line#+++ }" ;;
            "@@ "*)
                # hunk header: @@ -a,b +c,d @@  → seed new_line = c - 1
                n="${line#*+}"; n="${n%% *}"; n="${n%%,*}"
                case "$n" in ''|*[!0-9]*) ;; *) new_line=$((n - 1)) ;; esac
                ;;
            "--- "*|"diff "*|"index "*|"new file"*|"deleted file"*|"similarity "*|"rename "*|"old mode"*|"new mode"*) ;;
            "-"*)  ;;   # removed line → new-file line number unchanged
            "+"*)
                new_line=$((new_line + 1))
                [ -z "$file" ] && continue
                body="${line#+}"
                if   [[ $body =~ $rs ]]; then
                    printf 'security|%s|%d|%s\n' "$file" "$new_line" "$body"
                elif [[ $body =~ $rh ]]; then
                    printf 'debt|%s|%d|%s\n'     "$file" "$new_line" "$body"
                fi
                ;;
            *)
                # context line (" content") — advances new-file line number
                new_line=$((new_line + 1)) ;;
        esac
    done <<< "$diff"
    shopt -u nocasematch
}

# blame_line TARGET FILE LINE_NO
# Emits "commit|author|author_time_iso" for the specified line, or
# "uncommitted|||" when the line has never been committed (new file / fresh
# addition). Uses --porcelain so parsing is deterministic.
blame_line() {
    local target="$1" file="$2" line="$3"
    # If file isn't tracked in HEAD, blame will fail → mark uncommitted.
    if ! git -C "$target" cat-file -e "HEAD:$file" 2>/dev/null; then
        printf 'uncommitted|||\n'; return 0
    fi
    local out
    out="$(git -C "$target" blame --porcelain -L "${line},${line}" -- "$file" 2>/dev/null)" || {
        printf 'uncommitted|||\n'; return 0
    }
    local commit author author_time
    commit="$(  printf '%s\n' "$out" | awk 'NR==1 { print $1; exit }')"
    author="$(  printf '%s\n' "$out" | awk '/^author /       { sub(/^author /,""); print; exit }')"
    author_time="$(printf '%s\n' "$out" | awk '/^author-time /  { print $2; exit }')"
    # Boundary commits (initial commit) are marked with ^ prefix by some tools;
    # --porcelain uses "boundary" header line — treat first-ever-line as normal.
    if [ -z "$commit" ] || [ "$commit" = "0000000000000000000000000000000000000000" ]; then
        printf 'uncommitted|||\n'; return 0
    fi
    local iso=""
    if [ -n "$author_time" ]; then
        # GNU date and BSD date differ; try both.
        iso="$(date -u -r "$author_time" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
            || date -u -d "@$author_time" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
            || printf '%s' "$author_time")"
    fi
    printf '%s|%s|%s\n' "${commit:0:12}" "$author" "$iso"
}

# ── CORE: ANALYSIS & RENDER ───────────────────────────────────────────────────
render_dashboard() {
    local target="$1"
    # Engine-side self-metrics — captured cheaply (seconds granularity on
    # BSD date; millisecond on bash 5's $EPOCHREALTIME). Written into the
    # cache as the `performance` block for the /metrics endpoint to scrape.
    local _t_start _t_start_human
    if [ -n "${EPOCHREALTIME:-}" ]; then
        _t_start="$EPOCHREALTIME"
    else
        _t_start="$(date +%s).000000"
    fi
    _t_start_human="$_t_start"

    local diff_content diff_stat diff_names added_lines
    # DIFF_MODE selects the git-diff revision pair:
    #   head    (default) — HEAD vs working tree (staged + unstaged)
    #   staged            — HEAD vs index (what `git commit` would record)
    #   working           — index vs working tree (what's not yet staged)
    local _diff_args
    case "${DIFF_MODE:-head}" in
        staged)  _diff_args="--cached" ;;
        working) _diff_args="" ;;
        head|*)  _diff_args="HEAD" ;;
    esac
    # shellcheck disable=SC2086
    diff_content="$(git -C "$target" diff $_diff_args             2>/dev/null)"
    # shellcheck disable=SC2086
    diff_stat="$(   git -C "$target" diff $_diff_args --shortstat 2>/dev/null)"
    # shellcheck disable=SC2086
    diff_names="$(  git -C "$target" diff $_diff_args --name-only 2>/dev/null)"

    # ── METRICS ──────────────────────────────────────────────────────────────
    local sec_count=0 files_changed=0 insertions=0 deletions=0
    local complexity=0 test_file_count=0 hygiene_count=0
    local sec_snippet="" hygiene_snippet=""

    if [ -n "$diff_content" ]; then
        added_lines="$(echo "$diff_content" | grep "^+" | grep -v "^+++")"

        # [1] SECURITY + [5] DEBT → RAW lines (secrets live inside strings/comments)
        sec_count="$(echo "$added_lines" | grep -ciE "$REGEX_SECURITY" || true)"
        if [[ $sec_count -gt 0 ]]; then
            sec_snippet="$(echo "$added_lines" | grep -iE "$REGEX_SECURITY" | head -1 | sed 's/^+[[:space:]]*//' | cut -c1-40 || true)"
        fi
        
        hygiene_count="$(echo "$added_lines" | grep -ciE "$REGEX_HYGIENE" || true)"
        if [[ $hygiene_count -gt 0 ]]; then
            hygiene_snippet="$(echo "$added_lines" | grep -iE "$REGEX_HYGIENE" | head -1 | sed 's/^+[[:space:]]*//' | cut -c1-40 || true)"
        fi

        # [3] ENTROPY → Lexical Stripper (Noise Cancelling anti-false-positives)
        # Vaporize strings and comments: "// this if" won't raise entropy.
        local sanitized_lines
        sanitized_lines="$(echo "$added_lines"       \
            | sed -E 's/"[^"]*"//g'                  \
            | sed -E "s/'[^']*'//g"                  \
            | sed -E 's/(\/\/|#|\/\*).*//')"
        complexity="$(echo "$sanitized_lines" | grep -oiE "$REGEX_COMPLEXITY" | wc -l | tr -d ' ')"

        test_file_count="$(echo "$diff_names" | grep -ciE "$REGEX_TEST_FILES" || true)"
        files_changed="$(echo "$diff_stat" | grep -oE "[0-9]+ file"      | grep -oE "[0-9]+" || echo 0)"
        insertions="$(   echo "$diff_stat" | grep -oE "[0-9]+ insertion" | grep -oE "[0-9]+" || echo 0)"
        deletions="$(    echo "$diff_stat" | grep -oE "[0-9]+ deletion"  | grep -oE "[0-9]+" || echo 0)"
    fi
    # Ensure variables default to 0 if empty
    sec_count="$(echo "$sec_count" | tail -1)"; sec_count="${sec_count:-0}"
    hygiene_count="$(echo "$hygiene_count" | tail -1)"; hygiene_count="${hygiene_count:-0}"
    test_file_count="$(echo "$test_file_count" | tail -1)"; test_file_count="${test_file_count:-0}"
    complexity="${complexity:-0}"
    files_changed="${files_changed:-0}"; insertions="${insertions:-0}"; deletions="${deletions:-0}"

    # ── HEALTH SCORE ──────────────────────────────────────────────────────────
    local health=100
    [[ $sec_count       -gt 0 ]]                          && health=$((health - 50))
    # Geometric penalty: if mass is high, multiply penalty by files_changed to heavily penalize broad, dispersed changes
    if [[ $insertions -gt $THRESHOLD_MASS_CRITICAL ]]; then
        health=$((health - (20 + files_changed * 2) ))
    elif [[ $insertions -gt $THRESHOLD_MASS_WARN ]]; then
        health=$((health - (10 + files_changed) ))
    fi
    [[ $complexity      -gt $THRESHOLD_ENTROPY_CRITICAL ]] && health=$((health - 15))
    [[ $complexity      -gt $THRESHOLD_ENTROPY_WARN ]]    && health=$((health - 8))
    [[ $hygiene_count   -gt 0 ]]                          && health=$((health - 5 * hygiene_count))
    [[ $test_file_count -gt 0 ]]                          && health=$((health + 10))
    [[ $health -lt 0   ]] && health=0
    [[ $health -gt 100 ]] && health=100

    # ── CACHE WRITE-THROUGH: update JSON before rendering ─────────────────────
    local ts_iso; ts_iso="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    # is_idle means "nothing to show" (empty diff). Historical bug: this
    # flag was carrying `is_dirty` semantics while the JSON field was named
    # `is_idle`, so the UI flipped its empty-state branches. Keep the JSON
    # field name — just compute it correctly.
    local is_idle_flag="false"
    [ -z "$diff_content" ] && is_idle_flag="true"

    local branch shash
    branch="$(git -C "$target" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    shash="$( git -C "$target" rev-parse --short HEAD         2>/dev/null || echo '?')"

    # ── ADVANCED INTELLIGENCE (Zero-Latency) ──────────────────────────────────
    local j_logic="[]" j_config="[]" j_docs="[]" j_media="[]" j_deps="[]"
    local j_syn_valid="[]" j_syn_invalid="[]"
    local j_infra="[]" j_schema="[]" j_network="[]" j_sigs="[]"
    if [ -n "${diff_names:-}" ]; then
        # to_j_arr: newline-separated lines → comma-separated JSON string literals.
        # Every line goes through json_escape_str so quotes/backslashes/tabs in
        # paths or code don't break the emitted JSON array.
        to_j_arr() {
            local line out="" first=1 esc
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                esc="$(json_escape_str "$line")"
                if [ "$first" = "1" ]; then
                    out="\"$esc\""; first=0
                else
                    out="$out,\"$esc\""
                fi
            done <<< "$1"
            printf '%s' "$out"
        }
        
        local f_logic f_config f_docs f_media
        f_logic="$(echo "$diff_names" | grep -iE '\.(go|js|jsx|ts|tsx|py|sh|bash|rb|php|java|c|cpp|rs|html|css)$' || true)"
        f_config="$(echo "$diff_names" | grep -iE '\.(yml|yaml|json|toml|ini|env|conf)$' || true)"
        f_docs="$(echo "$diff_names" | grep -iE '\.(md|txt|csv|pdf)$' || true)"
        f_media="$(echo "$diff_names" | grep -iE '\.(png|jpg|jpeg|svg|gif|webp|ico)$' || true)"
        
        [ -n "$f_logic" ]  && j_logic="[$(to_j_arr "$f_logic")]"
        [ -n "$f_config" ] && j_config="[$(to_j_arr "$f_config")]"
        [ -n "$f_docs" ]   && j_docs="[$(to_j_arr "$f_docs")]"
        [ -n "$f_media" ]  && j_media="[$(to_j_arr "$f_media")]"

        # 1. Infrastructure / High-Risk Changes
        local f_infra
        f_infra="$(echo "$diff_names" | grep -iE '^(Dockerfile|docker-compose\.yml|package\.json|go\.mod|requirements\.txt|Makefile|.*\.github/workflows/.*)$' || true)"
        [ -n "$f_infra" ] && j_infra="[$(to_j_arr "$f_infra")]"

        if [ -n "${added_lines:-}" ]; then
            # Raw extraction; to_j_arr handles RFC 8259 escaping downstream.
            local deps schema network sigs
            deps="$(echo "$added_lines" | grep -oiE '^\+[[:space:]]*(import|require|include|from)[[:space:]]+.*' | head -10 | sed 's/^+[[:space:]]*//' || true)"
            [ -n "$deps" ] && j_deps="[$(to_j_arr "$deps")]"

            schema="$(echo "$added_lines" | grep -iE '^\+[[:space:]]*(CREATE TABLE|ALTER TABLE|DROP TABLE|CREATE INDEX).*' | head -10 | sed 's/^+[[:space:]]*//' || true)"
            [ -n "$schema" ] && j_schema="[$(to_j_arr "$schema")]"

            network="$(echo "$added_lines" | grep -iE '^\+[[:space:]]*.*(fetch\(|http\.Get\(|axios\.|requests\.(get|post)|curl ).*' | head -10 | sed 's/^+[[:space:]]*//' || true)"
            [ -n "$network" ] && j_network="[$(to_j_arr "$network")]"

            sigs="$(echo "$added_lines" | grep -E '^\+[[:space:]]*(def |func |class |function ).*' | head -10 | sed 's/^+[[:space:]]*//' || true)"
            [ -n "$sigs" ] && j_sigs="[$(to_j_arr "$sigs")]"
        fi

        # Fast Syntax Checks. We resolve each path to its canonical form and
        # require it to still live under $target — otherwise an attacker-planted
        # symlink in the repo could make `bash -n` / `py_compile` read (and
        # leak parse errors about) files outside the repo, e.g. /etc/passwd.
        local sv="" si="" target_real
        target_real="$(cd "$target" 2>/dev/null && pwd -P)" || target_real="$target"
        for f in $diff_names; do
            local abs_f="$target/$f" real_f
            [ ! -f "$abs_f" ] && continue
            # -L: follow symlinks → we *want* to know where they point so we
            # can reject them if they escape the repo root.
            real_f="$(cd "$(dirname "$abs_f")" 2>/dev/null && pwd -P)/$(basename "$abs_f")" || continue
            case "$real_f" in
                "$target_real"/*) ;;
                *) continue ;;   # symlink pointing outside $target — skip
            esac
            local ext="${f##*.}"
            if [[ "$ext" == "sh" || "$ext" == "bash" ]]; then
                bash -n "$abs_f" 2>/dev/null && sv+="$f"$'\n' || si+="$f"$'\n'
            elif [[ "$ext" == "json" ]] && command -v jq &>/dev/null; then
                jq empty "$abs_f" 2>/dev/null && sv+="$f"$'\n' || si+="$f"$'\n'
            elif [[ "$ext" == "py" ]] && command -v python3 &>/dev/null; then
                python3 -m py_compile "$abs_f" 2>/dev/null && sv+="$f"$'\n' || si+="$f"$'\n'
            fi
        done
        [ -n "$sv" ] && j_syn_valid="[$(to_j_arr "$sv")]"
        [ -n "$si" ] && j_syn_invalid="[$(to_j_arr "$si")]"
    fi
    # ── VIOLATIONS WITH BLAME ────────────────────────────────────────────────
    # Per-line provenance (who introduced this violation?). Bounded at 10 rows
    # to keep blame cost O(N) with N small; the summary counters above already
    # carry full totals.
    local j_violations="[]"
    if [ -n "$diff_content" ]; then
        local raw_v
        raw_v="$(extract_violations "$diff_content" "$REGEX_SECURITY" "$REGEX_HYGIENE" | head -10)"
        if [ -n "$raw_v" ]; then
            local items="" first=1
            while IFS='|' read -r v_kind v_file v_line v_text; do
                [ -z "$v_kind" ] && continue
                local blame_out b_commit b_author b_time
                blame_out="$(blame_line "$target" "$v_file" "$v_line")"
                IFS='|' read -r b_commit b_author b_time <<< "$blame_out"
                local e_file  e_text  e_kind  e_commit e_author e_time
                e_file="$(  json_escape_str "$v_file")"
                e_text="$(  json_escape_str "$v_text")"
                e_kind="$(  json_escape_str "$v_kind")"
                e_commit="$(json_escape_str "$b_commit")"
                e_author="$(json_escape_str "$b_author")"
                e_time="$(  json_escape_str "$b_time")"
                local item="{\"kind\":\"${e_kind}\",\"file\":\"${e_file}\",\"line\":${v_line},\"text\":\"${e_text}\",\"blame\":{\"commit\":\"${e_commit}\",\"author\":\"${e_author}\",\"author_time\":\"${e_time}\"}}"
                if [ "$first" = "1" ]; then items="$item"; first=0
                else items="${items},${item}"; fi
            done <<< "$raw_v"
            j_violations="[${items}]"
        fi
    fi

    # ── PLUGGABLE ANALYZERS (Semgrep, tree-sitter/AST, …) ────────────────────
    # Each analyzer in analyzers/ is invoked with the diff on stdin and its
    # findings are merged into intel. Critical/high findings escalate the
    # overall check.level so --check --fail-on=high gates on them.
    local analyzers_json="[]"
    if [ -n "${diff_content:-}" ] && [ "${OCCAM_NO_ANALYZERS:-0}" != "1" ]; then
        analyzers_json="$(run_analyzers "$target" "$diff_content" 2>/dev/null || echo '[]')"
        [ -z "$analyzers_json" ] && analyzers_json="[]"
    fi

    local intel_json="{\"file_types\":{\"logic\":${j_logic},\"config\":${j_config},\"docs\":${j_docs},\"media\":${j_media}},\"infrastructure_changes\":${j_infra},\"schema_mutations\":${j_schema},\"network_outbound\":${j_network},\"signatures_added\":${j_sigs},\"dependencies_added\":${j_deps},\"syntax_valid\":${j_syn_valid},\"syntax_invalid\":${j_syn_invalid},\"violations\":${j_violations},\"analyzers\":${analyzers_json}}"

    # ── SEVERITY DERIVATION ──────────────────────────────────────────────────
    local _infra_n=0 _schema_n=0 _net_n=0 _synbad_n=0
    [ "$j_infra"       != "[]" ] && _infra_n=1
    [ "$j_schema"      != "[]" ] && _schema_n=1
    [ "$j_network"     != "[]" ] && _net_n=1
    [ "$j_syn_invalid" != "[]" ] && _synbad_n=1
    local _sev_out _sev_level _sev_reasons
    _sev_out="$(compute_severity "$sec_count" "$insertions" "$complexity" "$hygiene_count" \
                                 "$_infra_n" "$_schema_n" "$_net_n" "$_synbad_n")"
    _sev_level="$(  printf '%s\n' "$_sev_out" | sed -n '1p')"
    _sev_reasons="$(printf '%s\n' "$_sev_out" | sed -n '2p')"

    # Escalate severity based on analyzer findings (Semgrep/AST/…).
    if [ "$analyzers_json" != "[]" ]; then
        local _sc; _sc="$(analyzer_severity_counts "$analyzers_json")"
        local _c _h _m _l; IFS='|' read -r _c _h _m _l <<< "$_sc"
        _sev_promote() {
            local cand="$1"
            if [ "$(sev_rank "$cand")" -gt "$(sev_rank "$_sev_level")" ]; then _sev_level="$cand"; fi
        }
        _sev_add_reason() {
            local r; r="$(json_escape_str "$1")"
            if [ "$_sev_reasons" = "[]" ]; then _sev_reasons="[\"$r\"]"
            else _sev_reasons="${_sev_reasons%]},\"$r\"]"; fi
        }
        if [ "${_c:-0}" -gt 0 ]; then _sev_promote critical; _sev_add_reason "analyzer_critical=$_c"; fi
        if [ "${_h:-0}" -gt 0 ]; then _sev_promote high;     _sev_add_reason "analyzer_high=$_h"; fi
        if [ "${_m:-0}" -gt 0 ]; then _sev_promote medium;   _sev_add_reason "analyzer_medium=$_m"; fi
        if [ "${_l:-0}" -gt 0 ]; then _sev_promote low;      _sev_add_reason "analyzer_low=$_l"; fi
    fi

    # expose for CLI --check path (command substitution forks a subshell, so
    # also persist through the cache file written below)
    LAST_CHECK_LEVEL="$_sev_level"
    LAST_CHECK_REASONS="$_sev_reasons"

    # ── ADVANCED GIT METADATA ─────────────────────────────────────────────────
    local g_auth g_msg g_time g_remote g_dirty="false"
    g_auth="$(git -C "$target" log -1 --pretty=format:'%an <%ae>' 2>/dev/null || true)"
    g_msg="$(git -C "$target" log -1 --pretty=format:'%s' 2>/dev/null || true)"
    g_time="$(git -C "$target" log -1 --pretty=format:'%cI' 2>/dev/null || true)"
    g_remote="$(git -C "$target" remote get-url origin 2>/dev/null || true)"
    [ -n "$diff_stat" ] && g_dirty="true"
    g_auth="$(json_escape_str "$g_auth")"
    g_msg="$(json_escape_str "$g_msg")"
    g_time="$(json_escape_str "$g_time")"
    g_remote="$(json_escape_str "$g_remote")"
    local git_json="{\"author\":\"${g_auth}\",\"message\":\"${g_msg}\",\"time\":\"${g_time}\",\"remote\":\"${g_remote}\",\"is_dirty\":${g_dirty}}"

    # ── PERFORMANCE BLOCK ────────────────────────────────────────────────────
    local _t_end _dur_ms _diff_bytes _analyzers_run
    if [ -n "${EPOCHREALTIME:-}" ]; then _t_end="$EPOCHREALTIME"
    else _t_end="$(date +%s).000000"; fi
    _dur_ms="$(awk -v s="$_t_start" -v e="$_t_end" 'BEGIN{printf "%d", (e-s)*1000}')"
    _diff_bytes="${#diff_content}"
    _analyzers_run="$(printf '%s' "$analyzers_json" | jq -c '[.[].name]' 2>/dev/null || echo '[]')"
    local _perf_json
    _perf_json="{\"engine_duration_ms\":${_dur_ms:-0},\"diff_bytes\":${_diff_bytes:-0},\"analyzers_run\":${_analyzers_run}}"

    write_cache "$is_idle_flag" "${branch}" "${shash}" "$ts_iso" \
        "$sec_count" "$insertions" "$deletions" "$files_changed" \
        "$complexity" "$test_file_count" "$hygiene_count" "$health" \
        "$sec_snippet" "$hygiene_snippet" "$intel_json" "$git_json" \
        "$_sev_level" "$_sev_reasons" "$_perf_json" 2>/dev/null || true

    persist_snapshot "$CACHE_FILE" 2>/dev/null || true

    # ── RENDER: zero-flicker overwrite (cursor to top, no full clear) ─────────
    # Bell before render if integrity violated
    [[ $sec_count -gt 0 && "$BELL_ON_CRITICAL" == "true" ]] && printf "\a"

    printf "\033[H"   # ← cursor to top-left (no clear = no flicker)

    local ts; ts="$(date '+%H:%M:%S')"

    # ── PANEL A: HEADER ───────────────────────────────────────────────────────
    printf "${GRAY}╭$(hline $((PANEL_W-2)) ─)╮${RST}\n"
    local title="${CYAN2}${BLD}🔭 OCCAM OBSERVER${RST}  ${DIM}Out-of-Band Git Telemetry${RST}"
    local ver="${GRAY}v${OCCAM_VERSION}${RST}"
    printf "${GRAY}│${RST}  %b\033[%dG%b  \033[%dG${GRAY}│${RST}\n" "$title" "$((PANEL_W - 9))" "$ver" "$PANEL_W"
    box_div
    # Info row
    local info="${DIM}⎇ ${RST}${TEAL}${BLD}${branch}${RST}   ${DIM}#${RST}${PURPLE}${shash}${RST}   ${DIM}⏱ ${RST}${GRAY}${ts}${RST}   ${DIM}📂 ${RST}${GRAY}$(basename "$target")${RST}"
    printf "${GRAY}│${RST}  %b\033[%dG${GRAY}│${RST}\n" "$info" "$PANEL_W"
    box_bot
    printf "\n"

    # ── PANEL B: METRIC BOARD ─────────────────────────────────────────────────
    box_top "STATE VECTOR" "${CYAN2}"

    # [1] SECURITY
    if [[ $sec_count -gt 0 ]]; then
        metric_row "🔐" "SECURITY" "CRITICAL — ${sec_count} plain secrets: ${sec_snippet}" "${ROSE}${REV}" "🚨"
    else
        metric_row "🔐" "SECURITY" "OK — No tokens/secrets detected" "${LIME}" "✓"
    fi

    # [2] MASS
    local mass_val="▲ ${insertions} ins  ▼ ${deletions} del  in ${files_changed} file/s"
    if   [[ $insertions -gt $THRESHOLD_MASS_CRITICAL ]]; then
        metric_row "📦" "MASS" "$mass_val" "${ROSE}" "🔴"
    elif [[ $insertions -gt $THRESHOLD_MASS_WARN ]]; then
        metric_row "📦" "MASS" "$mass_val" "${GOLD}" "⚠"
    else
        metric_row "📦" "MASS" "$mass_val" "${GRAY}" "·"
    fi

    # [3] ENTROPY
    local ent_val="+${complexity} logic nodes (if/for/while/switch/catch)"
    if   [[ $complexity -gt $THRESHOLD_ENTROPY_CRITICAL ]]; then
        metric_row "🌀" "ENTROPY" "$ent_val" "${ROSE}" "🔴"
    elif [[ $complexity -gt $THRESHOLD_ENTROPY_WARN ]]; then
        metric_row "🌀" "ENTROPY" "$ent_val" "${GOLD}" "⚠"
    else
        metric_row "🌀" "ENTROPY" "$ent_val" "${GRAY}" "·"
    fi

    # [4] TESTING
    if [[ $test_file_count -gt 0 ]]; then
        local tf; tf="$(echo "$diff_names" | grep -iE "$REGEX_TEST_FILES" | head -2 | tr '\n' ' ')"
        metric_row "🧪" "TESTING" "⚡ FAST PATH — ${tf}" "${LIME}" "✓"
    else
        metric_row "🧪" "TESTING" "No test/spec files in this delta" "${GRAY}" "·"
    fi

    # [5] DEBT
    if [[ $hygiene_count -gt 0 ]]; then
        metric_row "🔈" "DEBT" "⚠  ${hygiene_count} debts: ${hygiene_snippet}" "${GOLD}" "⚠"
    else
        metric_row "🔈" "DEBT" "OK — No debug leftovers" "${GRAY}" "·"
    fi
    box_bot
    printf "\n"

    # ── PANEL C: HEALTH SCORE ─────────────────────────────────────────────────
    box_top "HEALTH SCORE" "${TEAL}"
    local bar; bar="$(progress_bar "$health")"
    local slabel; slabel="$(score_label "$health")"
    local score_line="${bar}  ${W}${BLD}${health}${RST}${DIM}/100${RST}   ${slabel}"
    printf "${GRAY}│${RST}  %b\033[%dG${GRAY}│${RST}\n" "$score_line" "$PANEL_W"
    box_bot
    printf "\n"

    # ── PANEL D: STATUS / FOOTER ──────────────────────────────────────────────
    printf "${GRAY}╭$(hline $((PANEL_W-2)) ─)╮${RST}\n"
    # Spinner row — content is overwritten by the spinner subshell at SPINNER_ROW
    printf "${GRAY}│${RST}     \033[%dG${GRAY}│${RST}\n" "$PANEL_W"
    printf "${GRAY}│${RST}  ${DIM}Config: %-$((INNER_W-8))s${RST}\033[%dG${GRAY}│${RST}\n" \
        "$(basename "$CONFIG_FILE_USED")  ·  watcher: ${OS_WATCHER}  ·  CTRL+C exit" "$PANEL_W"
    # API server status row
    local api_status
    if [[ -n "${API_PID:-}" ]] && kill -0 "$API_PID" 2>/dev/null; then
        api_status="${LIME}●${RST} ${DIM}API Server: ${RST}${GRAY}127.0.0.1:${API_PORT}${RST}  ${DIM}[O(1) Cached · GET /]${RST}"
    else
        api_status="${ROSE}○${RST} ${DIM}API Server: offline${RST}"
    fi
    printf "${GRAY}│${RST}  %b\033[%dG${GRAY}│${RST}\n" "$api_status" "$PANEL_W"
    box_bot

    # Erase anything below the dashboard (handles terminal resize artifacts)
    printf "\033[J"
}

# ── HEADLESS MODE ─────────────────────────────────────────────────────────────
analyze_and_json() {
    local target="$1"
    # Execute analysis silently
    render_dashboard "$target" > /dev/null 2>&1
    cat "$CACHE_FILE" 2>/dev/null || echo '{"error": "Failed to generate JSON"}'
    # Clean up temporary cache file
    rm -f "$CACHE_FILE"
}

render_idle() {
    local ts; ts="$(date '+%H:%M:%S')"
    # Only refresh the footer spinner row — the rest stays painted
    stop_spinner
    start_spinner "$SPINNER_ROW" "$SPINNER_COL" "Idle — no uncommitted changes  [$ts]"
}

analyze_and_render() {
    local target="$1"
    stop_spinner
    render_dashboard "$target"
    # Restart spinner in the footer status row after render
    start_spinner "$SPINNER_ROW" "$SPINNER_COL" "Listening for filesystem events…   CTRL+C to exit"
}

# ── GRACEFUL EXIT ─────────────────────────────────────────────────────────────
cleanup() {
    stop_spinner
    stop_api_server
    tui_exit
    printf "\n${CYAN2}[OCCAM OBSERVER]${RST} ${DIM}Shutting down. Cache: ${CACHE_FILE} · Goodbye.${RST}\n\n"
    exit 0
}
trap cleanup SIGINT SIGTERM

# ── WATCHER LOOPS ─────────────────────────────────────────────────────────────
# Debounce window. Agents tend to rewrite many files in quick bursts; coalescing
# them into a single analysis avoids engine spin. Override with OCCAM_DEBOUNCE_MS.
OCCAM_DEBOUNCE_MS="${OCCAM_DEBOUNCE_MS:-400}"
_debounce_secs() { awk -v ms="$OCCAM_DEBOUNCE_MS" 'BEGIN{printf "%.3f", ms/1000}'; }

run_fswatch_loop() {
    local target="$1" secs; secs="$(_debounce_secs)"
    while read -r _ev; do
        analyze_and_render "$target"
    done < <(fswatch -o -r -l "$secs" --event Updated -e "\.git" "$target" 2>/dev/null)
}

run_inotifywait_loop() {
    local target="$1" secs; secs="$(_debounce_secs)"
    # -m keeps one long-running process; previously each event forked a new
    # inotifywait. Inner read drains the debounce window into /dev/null.
    # Requires bash 4+ for fractional read -t; falls back to 1s on bash 3.2.
    inotifywait -m -r -e close_write --exclude "\.git" --format "%f" -q "$target" 2>/dev/null \
    | while read -r _f; do
        while read -r -t "$secs" _junk 2>/dev/null || read -r -t 1 _junk 2>/dev/null; do :; done
        analyze_and_render "$target"
    done
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
main() {
    local cfg_arg="" pos_target="" is_json_mode="false" is_check_mode="false" is_validate_mode="false" is_watch_mode="false"
    local fail_on="high"
    DIFF_MODE="head"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config|-c) [[ $# -ge 2 ]] || { echo "Error: --config requires a file argument" >&2; exit 3; }
                         cfg_arg="$2"; shift 2 ;;
            --json)      is_json_mode="true"; shift ;;
            --check)     is_check_mode="true"; is_json_mode="true"; shift ;;
            --validate)  is_validate_mode="true"; shift ;;
            --watch)     is_watch_mode="true"; shift ;;
            --fail-on)   [[ $# -ge 2 ]] || { echo "Error: --fail-on requires a level" >&2; exit 3; }
                         fail_on="$2"; shift 2 ;;
            --fail-on=*) fail_on="${1#--fail-on=}"; shift ;;
            --diff)      [[ $# -ge 2 ]] || { echo "Error: --diff requires a mode (head|staged|working)" >&2; exit 3; }
                         DIFF_MODE="$2"; shift 2 ;;
            --diff=*)    DIFF_MODE="${1#--diff=}"; shift ;;
            --staged)    DIFF_MODE="staged"; shift ;;
            --working)   DIFF_MODE="working"; shift ;;
            --help|-h)
                cat <<USAGE
USAGE: $(basename "$0") [OPTIONS] [/path/to/repo]

OPTIONS
  --json                  emit JSON telemetry to stdout and exit (no TUI)
  --check                 like --json, plus exit code based on severity
  --fail-on=LEVEL         threshold for --check (low|medium|high|critical)
                          default: high — exit 1 if severity >= threshold
  --diff=MODE             diff revision pair: head|staged|working (default: head)
  --staged                shorthand for --diff=staged
  --working               shorthand for --diff=working
  --watch                 headless filesystem watcher — re-analyzes on save
                          and writes \$CACHE_FILE (no TUI, no API server).
                          Pair with the Go gateway for live dashboards.
  --validate              validate config/main.yml + config/rules/*.yml and exit
  --config FILE           YAML config (default: ./config/main.yml)
  --help, -h              this screen

EXIT CODES
  0   success or severity below --fail-on threshold
  1   severity meets/exceeds --fail-on threshold (--check mode only)
  2   engine/runtime error
  3   bad arguments / config

Priority: CLI arg > config/main.yml > internal defaults
USAGE
                exit 0 ;;
            -*) echo "Unknown flag: $1 (use --help)" >&2; exit 3 ;;
            *)  pos_target="$1"; shift ;;
        esac
    done

    case "$DIFF_MODE" in head|staged|working) ;; *)
        echo "Error: invalid --diff mode '$DIFF_MODE' (want head|staged|working)" >&2; exit 3 ;;
    esac
    case "$fail_on" in low|medium|high|critical) ;; *)
        echo "Error: invalid --fail-on level '$fail_on' (want low|medium|high|critical)" >&2; exit 3 ;;
    esac
    export DIFF_MODE

    # Resolve absolute path from CLI target (if provided)
    if [[ -n "$pos_target" ]]; then
        pos_target="$(cd "$pos_target" 2>/dev/null && pwd)" \
            || { echo "Path not accessible: '$pos_target'" >&2; exit 1; }
    fi

    load_config "$cfg_arg" "$pos_target"

    if [[ "$is_validate_mode" == "true" ]]; then
        local cfg_to_check="$CONFIG_FILE_USED"
        [ "$cfg_to_check" = "(defaults)" ] && cfg_to_check=""
        if validate_config "$cfg_to_check"; then
            log_json info "config valid" "file=${cfg_to_check:-none}"
            exit 0
        else
            exit 3
        fi
    fi

    if [[ -n "$TARGET_PATH" && -z "$pos_target" ]]; then
        TARGET_PATH="$(cd "$TARGET_PATH" 2>/dev/null && pwd)" \
            || { echo "target_path from config not accessible: $TARGET_PATH" >&2; exit 1; }
    fi

    validate_target

    if [[ "$is_json_mode" == "true" ]]; then
        # mktemp + umask 0077 in a subshell → mode 0600 at creation time
        # (no TOCTOU window between mktemp and chmod).
        CACHE_FILE="$(umask 0077; mktemp /tmp/occam_json_XXXXXX.json)"
        # Run analysis in-process so LAST_CHECK_LEVEL is visible to this shell.
        # Capture the JSON payload via the cache file rather than $(…) subshell.
        render_dashboard "$TARGET_PATH" > /dev/null 2>&1 || {
            log_json error "engine analysis failed" "target=$TARGET_PATH"
            rm -f "$CACHE_FILE"
            exit 2
        }
        cat "$CACHE_FILE"
        rm -f "$CACHE_FILE"

        if [[ "$is_check_mode" == "true" ]]; then
            local got_rank want_rank
            got_rank="$(sev_rank "${LAST_CHECK_LEVEL:-none}")"
            want_rank="$(sev_rank "$fail_on")"
            local passed="true"
            [ "$got_rank" -ge "$want_rank" ] && passed="false"
            log_json info "check completed" \
                "check_level=${LAST_CHECK_LEVEL:-none}" \
                "fail_on=$fail_on" \
                "passed=$passed" \
                "diff_mode=$DIFF_MODE"
            [ "$passed" = "false" ] && exit 1
        fi
        exit 0
    fi

    # ── Headless watcher mode ────────────────────────────────────────────────
    # Drives the same filesystem watchers as interactive TUI, but writes to
    # $CACHE_FILE silently (no spinner, no screen buffer, no internal API
    # server). Pair with the Go gateway (./occam start) so the dashboard
    # stays live without the terminal UI taking over.
    if [[ "$is_watch_mode" == "true" ]]; then
        detect_os_watcher
        log_json info "watcher starting" "target=$TARGET_PATH" "cache=$CACHE_FILE" "watcher=$OS_WATCHER"
        # Seed the cache synchronously so /ui/ has data immediately.
        render_dashboard "$TARGET_PATH" > /dev/null 2>&1 || true
        case "$OS_WATCHER" in
            fswatch)
                local secs; secs="$(_debounce_secs)"
                while read -r _ev; do
                    render_dashboard "$TARGET_PATH" > /dev/null 2>&1 || true
                done < <(fswatch -o -r -l "$secs" --event Updated -e "\.git" "$TARGET_PATH" 2>/dev/null)
                ;;
            inotifywait)
                local secs; secs="$(_debounce_secs)"
                inotifywait -m -r -e close_write --exclude "\.git" --format "%f" -q "$TARGET_PATH" 2>/dev/null \
                | while read -r _f; do
                    while read -r -t "$secs" _junk 2>/dev/null || read -r -t 1 _junk 2>/dev/null; do :; done
                    render_dashboard "$TARGET_PATH" > /dev/null 2>&1 || true
                done
                ;;
        esac
        exit 0
    fi

    detect_os_watcher
    tui_init

    # Seed the cache with an idle snapshot so the gateway never 503s between
    # startup and the first real render. is_idle=true matches the semantics
    # (all zero metrics → nothing to show).
    local init_branch init_hash
    init_branch="$(git -C "$TARGET_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
    init_hash="$(  git -C "$TARGET_PATH" rev-parse --short HEAD         2>/dev/null || echo '0000000')"
    write_cache "true" "$init_branch" "$init_hash" "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
        0 0 0 0 0 0 0 100 2>/dev/null || true

    # Avvia il server API in background prima del primo render
    start_api_server

    # Initial render (shows idle state + spinner)
    render_dashboard "$TARGET_PATH"
    start_spinner "$SPINNER_ROW" "$SPINNER_COL" "Listening for filesystem events…   CTRL+C to exit"
    sleep "$STARTUP_DELAY"

    case "$OS_WATCHER" in
        fswatch)     run_fswatch_loop     "$TARGET_PATH" ;;
        inotifywait) run_inotifywait_loop "$TARGET_PATH" ;;
    esac
}

# Only invoke main when executed as a script; allow `source` for unit tests.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
