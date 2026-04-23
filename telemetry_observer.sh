#!/usr/bin/env bash
# =============================================================================
# telemetry_observer.sh — Occam Observer TUI v2.1.0
# =============================================================================
# UI   : Alternate Screen Buffer · Zero-Flicker · Braille Spinner
#        Unicode Box Drawing · 256-color · Progress Bar · Fixed-layout panels
# Logic: YAML parser · OS watcher · 5 vector metrics · Health Score
# API  : CQRS REST server (nc) · Write-through JSON cache · O(1) GET latency
# Deps : fswatch (macOS) OR inotifywait (Linux) — nothing else
# =============================================================================
set -euo pipefail

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

# ── API: JSON CACHE WRITER (Write-Through, chiamato dopo ogni analisi) ────────
# write_cache — serialize the state to $CACHE_FILE (RAM disk on /tmp)
write_cache() {
    local is_idle="${1}" branch="${2}" commit="${3}" ts="${4}"
    local sec="${5}" ins="${6}" del="${7}" files="${8}"
    local comp="${9}" test_f="${10}" hygi="${11}" health="${12}"
    local sec_snip="${13:-}" hygi_snip="${14:-}"
    local intel_json="{}" git_json="{}"
    [ $# -ge 15 ] && intel_json="${15}"
    [ $# -ge 16 ] && git_json="${16}"
    # Atomic write: write to tmp, then atomic mv to prevent partial reads
    local tmp_file; tmp_file="$(mktemp /tmp/occam_state_XXXXXX.json)"
    
    # Escape quotes and newlines for JSON
    sec_snip="${sec_snip//\"/\\\"}"; sec_snip="${sec_snip//$'\n'/}"
    hygi_snip="${hygi_snip//\"/\\\"}"; hygi_snip="${hygi_snip//$'\n'/}"

    cat > "$tmp_file" << ENDJSON
{
  "version": "3.0.0",
  "timestamp": "${ts}",
  "branch": "${branch}",
  "commit": "${commit}",
  "target": "${TARGET_PATH}",
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
    "security": "${sec_snip}",
    "debt": "${hygi_snip}"
  },
  "git": ${git_json},
  "intelligence": ${intel_json},
  "health_score": ${health},
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

# ── CORE: ANALYSIS & RENDER ───────────────────────────────────────────────────
render_dashboard() {
    local target="$1"
    local diff_content diff_stat diff_names added_lines
    diff_content="$(git -C "$target" diff HEAD 2>/dev/null)"
    diff_stat="$(   git -C "$target" diff HEAD --shortstat 2>/dev/null)"
    diff_names="$(  git -C "$target" diff HEAD --name-only 2>/dev/null)"

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
    local is_dirty_flag="true"
    [ -z "$diff_content" ] && is_dirty_flag="false"

    local branch shash
    branch="$(git -C "$target" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    shash="$( git -C "$target" rev-parse --short HEAD         2>/dev/null || echo '?')"

    # ── ADVANCED INTELLIGENCE (Zero-Latency) ──────────────────────────────────
    local j_logic="[]" j_config="[]" j_docs="[]" j_media="[]" j_deps="[]"
    local j_syn_valid="[]" j_syn_invalid="[]"
    local j_infra="[]" j_schema="[]" j_network="[]" j_sigs="[]"
    if [ -n "${diff_names:-}" ]; then
        to_j_arr() { echo "$1" | awk 'NF {printf "\"%s\",", $0}' | sed 's/,$//'; }
        
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
            local deps
            deps="$(echo "$added_lines" | grep -oiE '^\+[[:space:]]*(import|require|include|from)[[:space:]]+.*' | head -10 | sed 's/^+[[:space:]]*//' || true)"
            deps="${deps//\"/\\\"}"
            [ -n "$deps" ] && j_deps="[$(to_j_arr "$deps")]"

            # 2. Schema Mutations
            local schema
            schema="$(echo "$added_lines" | grep -iE '^\+[[:space:]]*(CREATE TABLE|ALTER TABLE|DROP TABLE|CREATE INDEX).*' | head -10 | sed 's/^+[[:space:]]*//' || true)"
            schema="${schema//\"/\\\"}"
            [ -n "$schema" ] && j_schema="[$(to_j_arr "$schema")]"

            # 3. Network Outbound
            local network
            network="$(echo "$added_lines" | grep -iE '^\+[[:space:]]*.*(fetch\(|http\.Get\(|axios\.|requests\.(get|post)|curl ).*' | head -10 | sed 's/^+[[:space:]]*//' || true)"
            network="${network//\"/\\\"}"
            [ -n "$network" ] && j_network="[$(to_j_arr "$network")]"

            # 4. Signatures Added
            local sigs
            sigs="$(echo "$added_lines" | grep -E '^\+[[:space:]]*(def |func |class |function ).*' | head -10 | sed 's/^+[[:space:]]*//' || true)"
            sigs="${sigs//\"/\\\"}"
            [ -n "$sigs" ] && j_sigs="[$(to_j_arr "$sigs")]"
        fi

        # Fast Syntax Checks
        local sv="" si=""
        for f in $diff_names; do
            local abs_f="$target/$f"
            [ ! -f "$abs_f" ] && continue
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
    local intel_json="{\"file_types\":{\"logic\":${j_logic},\"config\":${j_config},\"docs\":${j_docs},\"media\":${j_media}},\"infrastructure_changes\":${j_infra},\"schema_mutations\":${j_schema},\"network_outbound\":${j_network},\"signatures_added\":${j_sigs},\"dependencies_added\":${j_deps},\"syntax_valid\":${j_syn_valid},\"syntax_invalid\":${j_syn_invalid}}"

    # ── ADVANCED GIT METADATA ─────────────────────────────────────────────────
    local g_auth g_msg g_time g_remote g_dirty="false"
    g_auth="$(git -C "$target" log -1 --pretty=format:'%an <%ae>' 2>/dev/null | sed -E 's/(["\\])/\\\1/g' || true)"
    g_msg="$(git -C "$target" log -1 --pretty=format:'%s' 2>/dev/null | sed -E 's/(["\\])/\\\1/g' || true)"
    g_time="$(git -C "$target" log -1 --pretty=format:'%cI' 2>/dev/null || true)"
    g_remote="$(git -C "$target" remote get-url origin 2>/dev/null || true)"
    [ -n "$diff_stat" ] && g_dirty="true"
    local git_json="{\"author\":\"${g_auth}\",\"message\":\"${g_msg}\",\"time\":\"${g_time}\",\"remote\":\"${g_remote}\",\"is_dirty\":${g_dirty}}"

    write_cache "$is_dirty_flag" "${branch}" "${shash}" "$ts_iso" \
        "$sec_count" "$insertions" "$deletions" "$files_changed" \
        "$complexity" "$test_file_count" "$hygiene_count" "$health" \
        "$sec_snippet" "$hygiene_snippet" "$intel_json" "$git_json" 2>/dev/null || true

    # ── RENDER: zero-flicker overwrite (cursor to top, no full clear) ─────────
    # Bell before render if integrity violated
    [[ $sec_count -gt 0 && "$BELL_ON_CRITICAL" == "true" ]] && printf "\a"

    printf "\033[H"   # ← cursor to top-left (no clear = no flicker)

    local ts; ts="$(date '+%H:%M:%S')"

    # ── PANEL A: HEADER ───────────────────────────────────────────────────────
    printf "${GRAY}╭$(hline $((PANEL_W-2)) ─)╮${RST}\n"
    local title="${CYAN2}${BLD}🔭 OCCAM OBSERVER${RST}  ${DIM}Out-of-Band Git Telemetry${RST}"
    local ver="${GRAY}v3.0.0${RST}"
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
run_fswatch_loop() {
    local target="$1"
    # -l 0.2: debounce 200ms — aggregates IDE "Save All" events into a single trigger.
    # Prevents engine spin-loops on mass saves.
    while read -r _ev; do
        analyze_and_render "$target"
    done < <(fswatch -o -r -l 0.2 --event Updated -e "\.git" "$target" 2>/dev/null)
}

run_inotifywait_loop() {
    local target="$1"
    # inotifywait lacks native debounce. After the first event,
    # silently drain all subsequent events arriving within a 200ms window.
    while inotifywait -r -e close_write --exclude "\.git" --format "%f" \
          -q "$target" 2>/dev/null | read -r _f; do
        while read -r -t 0.2 _junk 2>/dev/null; do :; done  # drain window
        analyze_and_render "$target"
    done
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
main() {
    local cfg_arg="" pos_target="" is_json_mode="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config|-c) [[ $# -ge 2 ]] || { echo "Error: --config requires a file argument" >&2; exit 1; }
                         cfg_arg="$2"; shift 2 ;;
            --json)      is_json_mode="true"; shift ;;
            --help|-h)
                printf "USAGE: %s [--json] [--config file.yml] [/path/to/repo]\n" "$0"
                printf "  Priority: CLI arg > config/main.yml > internal defaults\n"; exit 0 ;;
            -*) echo "Unknown flag: $1 (use --help)" >&2; exit 1 ;;
            *)  pos_target="$1"; shift ;;
        esac
    done

    # Resolve absolute path from CLI target (if provided)
    if [[ -n "$pos_target" ]]; then
        pos_target="$(cd "$pos_target" 2>/dev/null && pwd)" \
            || { echo "Path not accessible: '$pos_target'" >&2; exit 1; }
    fi

    load_config "$cfg_arg" "$pos_target"

    if [[ -n "$TARGET_PATH" && -z "$pos_target" ]]; then
        TARGET_PATH="$(cd "$TARGET_PATH" 2>/dev/null && pwd)" \
            || { echo "target_path from config not accessible: $TARGET_PATH" >&2; exit 1; }
    fi

    validate_target

    if [[ "$is_json_mode" == "true" ]]; then
        CACHE_FILE="/tmp/occam_state_$$_${RANDOM}.json"
        analyze_and_json "$TARGET_PATH"
        exit 0
    fi

    detect_os_watcher
    tui_init

    # Popola il cache con stato IDLE iniziale — API risponde subito, senza 404
    local init_branch init_hash
    init_branch="$(git -C "$TARGET_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
    init_hash="$(  git -C "$TARGET_PATH" rev-parse --short HEAD         2>/dev/null || echo '0000000')"
    write_cache "false" "$init_branch" "$init_hash" "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
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

main "$@"
