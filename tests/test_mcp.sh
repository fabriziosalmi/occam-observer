#!/usr/bin/env bash
# MCP server smoke: full JSON-RPC exchange over stdio.
# Covers: initialize, tools/list, tools/call (analyze + check + health + validate + trend).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v jq  >/dev/null || { echo "FAIL: jq required" >&2; exit 1; }
command -v go  >/dev/null || { echo "SKIP: go required" >&2; exit 0; }

PASS=0; FAIL=0
pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }

echo "────────────────────────────────────────────────────────────"
echo "  MCP server (stdio JSON-RPC)"
echo "────────────────────────────────────────────────────────────"

bin="$(mktemp /tmp/occam_mcp_bin_XXXXXX)"
db="$(mktemp /tmp/occam_mcp_db_XXXXXX.db)"; rm -f "$db"
repo="$(mktemp -d /tmp/occam_mcp_repo_XXXXXX)"

cleanup() { rm -rf "$bin" "$db" "${db}-wal" "${db}-shm" "$repo"; }
trap cleanup EXIT

( cd "$SCRIPT_DIR/mcp" && go build -o "$bin" . ) 2>/dev/null || { fail "go build mcp"; exit 1; }

git -C "$repo" init -q
git -C "$repo" config user.email t@t.t && git -C "$repo" config user.name t
echo seed > "$repo/s.txt" && git -C "$repo" add . >/dev/null
git -C "$repo" commit -q -m init

# Helper: send a list of JSON-RPC frames on stdin, collect responses.
mcp_exchange() {
    ENGINE_SCRIPT="$SCRIPT_DIR/telemetry_observer.sh" \
    OCCAM_DB="$db" \
    "$bin" 2>/dev/null
}

# ── T1: initialize handshake ──────────────────────────────────────────────────
req='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","clientInfo":{"name":"test","version":"1"}}}'
resp="$(printf '%s\n' "$req" | mcp_exchange | head -1)"
pv="$(echo "$resp" | jq -r '.result.protocolVersion')"
name="$(echo "$resp" | jq -r '.result.serverInfo.name')"
if [ "$pv" = "2024-11-05" ] && [ "$name" = "occam-observer-mcp" ]; then
    pass "T1 initialize returns protocolVersion + serverInfo"
else
    fail "T1 pv=$pv name=$name"
fi

# ── T2: tools/list ────────────────────────────────────────────────────────────
req='{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
resp="$(printf '%s\n' "$req" | mcp_exchange | head -1)"
tools_count="$(echo "$resp" | jq -r '.result.tools | length')"
# Core 5 + 15 coordination = 20 total (see mcp/main.go toolCatalog + httpToolRoutes)
if [ "${tools_count:-0}" = "20" ]; then
    pass "T2 tools/list returns 20 tools (5 core + 15 coordination)"
else
    fail "T2 got $tools_count tools, want 20"
fi
# Spot-check: core + coordination names present
core_ok="$(echo "$resp" | jq '[.result.tools[].name] | contains(["occam_analyze","occam_check","occam_trend","occam_validate_config","occam_health"])')"
coord_ok="$(echo "$resp" | jq '[.result.tools[].name] | contains(["occam_repo_context","occam_observation","occam_claim_acquire","occam_symbol","occam_file_imports"])')"
[ "$core_ok" = "true" ] && pass "T2a core tools present"        || fail "T2a core missing"
[ "$coord_ok" = "true" ] && pass "T2b coordination tools present" || fail "T2b coordination missing"

# ── T3: occam_analyze on a real repo ──────────────────────────────────────────
req='{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"occam_analyze","arguments":{"path":"'"$repo"'"}}}'
resp="$(printf '%s\n' "$req" | mcp_exchange | head -1)"
is_err="$(echo "$resp" | jq -r '.result.isError')"
text="$(echo "$resp" | jq -r '.result.content[0].text')"
ver="$(echo "$text" | jq -r '.version' 2>/dev/null)"
if [ "$is_err" = "false" ] && [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    pass "T3 occam_analyze returns engine JSON (version=$ver)"
else
    fail "T3 is_err=$is_err ver=$ver body=${text:0:200}"
fi

# ── T4: occam_check passes on clean repo ──────────────────────────────────────
req='{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"occam_check","arguments":{"path":"'"$repo"'","fail_on":"high"}}}'
resp="$(printf '%s\n' "$req" | mcp_exchange | head -1)"
text="$(echo "$resp" | jq -r '.result.content[0].text')"
passed="$(echo "$text" | jq -r '.passed')"
ec="$(echo "$text" | jq -r '.exit_code')"
if [ "$passed" = "true" ] && [ "$ec" = "0" ]; then
    pass "T4 occam_check clean repo: passed=true exit=0"
else
    fail "T4 passed=$passed exit=$ec"
fi

# ── T5: occam_check fails on injected secret ──────────────────────────────────
echo 'API_KEY="leaked"' > "$repo/bad.py"
git -C "$repo" add bad.py >/dev/null
req='{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"occam_check","arguments":{"path":"'"$repo"'","fail_on":"high","diff_mode":"staged"}}}'
resp="$(printf '%s\n' "$req" | mcp_exchange | head -1)"
text="$(echo "$resp" | jq -r '.result.content[0].text')"
passed="$(echo "$text" | jq -r '.passed')"
level="$(echo "$text" | jq -r '.result.check.level')"
if [ "$passed" = "false" ] && [ "$level" = "critical" ]; then
    pass "T5 occam_check fails critical: passed=false level=critical"
else
    fail "T5 passed=$passed level=$level"
fi

# ── T6: validation of path rejection ──────────────────────────────────────────
req='{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"occam_analyze","arguments":{"path":"--json"}}}'
resp="$(printf '%s\n' "$req" | mcp_exchange | head -1)"
is_err="$(echo "$resp" | jq -r '.result.isError')"
if [ "$is_err" = "true" ]; then
    pass "T6 flag-like path rejected"
else
    fail "T6 is_err=$is_err"
fi

# ── T7: occam_trend returns array (no snapshots yet from analyze via MCP) ─────
# MCP invocations don't persist because --json path uses ephemeral cache.
# We populate the DB directly by running the engine normally once.
OCCAM_DB="$db" "$SCRIPT_DIR/telemetry_observer.sh" --json "$repo" >/dev/null 2>/dev/null
req='{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"occam_trend","arguments":{"limit":5}}}'
resp="$(printf '%s\n' "$req" | mcp_exchange | head -1)"
text="$(echo "$resp" | jq -r '.result.content[0].text')"
len="$(echo "$text" | jq -r 'length' 2>/dev/null || echo 0)"
if [ "${len:-0}" -ge 1 ]; then
    pass "T7 occam_trend returns $len row(s)"
else
    fail "T7 trend len=$len"
fi

# ── T8: occam_validate_config returns valid=true ──────────────────────────────
req='{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"occam_validate_config","arguments":{}}}'
resp="$(printf '%s\n' "$req" | mcp_exchange | head -1)"
text="$(echo "$resp" | jq -r '.result.content[0].text')"
valid="$(echo "$text" | jq -r '.valid')"
if [ "$valid" = "true" ]; then
    pass "T8 validate_config: valid=true"
else
    fail "T8 valid=$valid"
fi

# ── T9: occam_health reports deps ─────────────────────────────────────────────
req='{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"occam_health","arguments":{}}}'
resp="$(printf '%s\n' "$req" | mcp_exchange | head -1)"
text="$(echo "$resp" | jq -r '.result.content[0].text')"
git_avail="$(echo "$text" | jq -r '.deps.git.available')"
if [ "$git_avail" = "true" ]; then
    pass "T9 health probes deps (git available)"
else
    fail "T9 git_avail=$git_avail"
fi

# ── T10: unknown method returns JSON-RPC error ────────────────────────────────
req='{"jsonrpc":"2.0","id":10,"method":"does/not/exist"}'
resp="$(printf '%s\n' "$req" | mcp_exchange | head -1)"
code="$(echo "$resp" | jq -r '.error.code')"
if [ "$code" = "-32601" ]; then
    pass "T10 unknown method → -32601"
else
    fail "T10 code=$code"
fi

# ── T11: parse error on garbage ───────────────────────────────────────────────
resp="$(printf 'not json at all\n' | mcp_exchange | head -1)"
code="$(echo "$resp" | jq -r '.error.code')"
if [ "$code" = "-32700" ]; then
    pass "T11 parse error → -32700"
else
    fail "T11 code=$code resp=${resp:0:200}"
fi

# ── T12: notifications/initialized elicits no response (no crash) ─────────────
req='{"jsonrpc":"2.0","method":"notifications/initialized"}'
# if the server responded anything on stdout, that would be a bug; empty is good
resp="$(printf '%s\n' "$req" | mcp_exchange)"
if [ -z "$resp" ]; then
    pass "T12 notifications/initialized emits no response"
else
    fail "T12 unexpected response: ${resp:0:100}"
fi

# ── T13: coordination tool via HTTP proxy (gateway must be up) ───────────────
if command -v curl >/dev/null && command -v sqlite3 >/dev/null; then
    gw_bin="$(mktemp /tmp/occam_mcp_gw_XXXXXX)"
    ( cd "$SCRIPT_DIR/api" && go build -o "$gw_bin" . ) 2>/dev/null || gw_bin=""
    if [ -n "$gw_bin" ]; then
        port=$(( 40000 + RANDOM % 10000 ))
        ENGINE_SCRIPT="$SCRIPT_DIR/telemetry_observer.sh" \
        OCCAM_DB="$db" \
        API_PORT="$port" \
        "$gw_bin" >/dev/null 2>&1 &
        gw_pid=$!
        sleep 1

        # POST /observation via MCP occam_observation tool
        obs_args='{"run_id":"run-mcp-t13","agent":"mcp-smoke","outcome":"success","touched_files":["src.py"]}'
        req="$(printf '{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"occam_observation","arguments":%s}}' "$obs_args")"
        resp="$(printf '%s\n' "$req" | OCCAM_API_URL="http://127.0.0.1:${port}" ENGINE_SCRIPT="$SCRIPT_DIR/telemetry_observer.sh" OCCAM_DB="$db" "$bin" 2>/dev/null | head -1)"
        text="$(echo "$resp" | jq -r '.result.content[0].text')"
        id_set="$(echo "$text" | jq -r '.id')"
        if [[ "$id_set" =~ ^[0-9]+$ ]]; then
            pass "T13 MCP occam_observation (HTTP-proxied) → observation id=$id_set"
        else
            fail "T13 text=${text:0:200}"
        fi

        # GET /repo/agent-log via MCP occam_repo_agent_log
        req='{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"occam_repo_agent_log","arguments":{"run_id":"run-mcp-t13","limit":10}}}'
        resp="$(printf '%s\n' "$req" | OCCAM_API_URL="http://127.0.0.1:${port}" ENGINE_SCRIPT="$SCRIPT_DIR/telemetry_observer.sh" OCCAM_DB="$db" "$bin" 2>/dev/null | head -1)"
        text="$(echo "$resp" | jq -r '.result.content[0].text')"
        len="$(echo "$text" | jq -r 'length' 2>/dev/null || echo 0)"
        if [ "${len:-0}" -ge 1 ]; then
            pass "T14 MCP occam_repo_agent_log returns the recorded event"
        else
            fail "T14 len=$len text=${text:0:200}"
        fi

        # Gateway unreachable path: point MCP at a dead port → tool error (isError:true)
        req='{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"occam_repo_agent_log","arguments":{}}}'
        resp="$(printf '%s\n' "$req" | OCCAM_API_URL="http://127.0.0.1:1" "$bin" 2>/dev/null | head -1)"
        is_err="$(echo "$resp" | jq -r '.result.isError')"
        if [ "$is_err" = "true" ]; then
            pass "T15 MCP tool gracefully reports gateway unreachable"
        else
            fail "T15 is_err=$is_err"
        fi

        kill $gw_pid 2>/dev/null; wait $gw_pid 2>/dev/null
        rm -f "$gw_bin"
    fi
fi

echo "────────────────────────────────────────────────────────────"
printf "  passed=%d  failed=%d\n" "$PASS" "$FAIL"
echo "────────────────────────────────────────────────────────────"
[ "$FAIL" -eq 0 ] || exit 1
