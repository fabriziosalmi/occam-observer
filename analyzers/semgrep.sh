#!/usr/bin/env bash
# Semgrep → Occam analyzer protocol adapter.
#
# Contract (run_analyzers):  $1 = target path  $2 = diff mode  stdin = diff
# Stdout = Occam findings JSON.  Exit 0 on success, else error (engine skips).
#
# Behavior:
#   - If `semgrep` isn't installed, emit an empty-findings envelope and exit 0
#     (the engine should gracefully no-op on missing analyzers).
#   - Scan ONLY the files touched by the diff (fast path; avoids whole-repo
#     latency). The file list comes from the diff on stdin, not a re-run of git.
#   - Use the `auto` config so Semgrep picks rule packs per detected language.
#     Override via OCCAM_SEMGREP_CONFIG=p/security-audit etc.
set -u

TARGET="${1-}"
[ -z "$TARGET" ] && { printf '{"name":"semgrep","version":"","findings":[]}\n'; exit 0; }
[ -d "$TARGET" ] || { printf '{"name":"semgrep","version":"","findings":[]}\n'; exit 0; }

if ! command -v semgrep >/dev/null 2>&1; then
    printf '{"name":"semgrep","version":"","findings":[],"skipped":"semgrep not installed"}\n'
    exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
    printf '{"name":"semgrep","version":"","findings":[],"skipped":"jq not installed"}\n'
    exit 0
fi

SEMGREP_CONFIG="${OCCAM_SEMGREP_CONFIG:-auto}"
SEMGREP_TIMEOUT="${OCCAM_SEMGREP_TIMEOUT:-20}"

# Collect changed file paths from the diff on stdin (lines like "+++ b/path").
files="$(awk '/^\+\+\+ b\// { sub(/^\+\+\+ b\//, ""); print }' | sort -u)"
# If no changed files (e.g. clean repo, diff empty), exit with empty findings.
if [ -z "$files" ]; then
    printf '{"name":"semgrep","version":"%s","findings":[]}\n' "$(semgrep --version 2>/dev/null | head -1)"
    exit 0
fi

# Build absolute paths and filter out any that no longer exist (deleted files).
abs_files=()
while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ -f "${TARGET}/${f}" ] && abs_files+=("${TARGET}/${f}")
done <<< "$files"
if [ "${#abs_files[@]}" -eq 0 ]; then
    printf '{"name":"semgrep","version":"%s","findings":[]}\n' "$(semgrep --version 2>/dev/null | head -1)"
    exit 0
fi

# Run semgrep on the touched-files set. --error=false so a finding doesn't
# change the exit code; --disable-version-check avoids network calls.
raw="$(semgrep --config="$SEMGREP_CONFIG" \
               --json \
               --quiet \
               --error=false \
               --disable-version-check \
               --timeout="$SEMGREP_TIMEOUT" \
               "${abs_files[@]}" 2>/dev/null)" || {
    printf '{"name":"semgrep","version":"","findings":[],"error":"semgrep_failed"}\n'
    exit 0
}

# Map Semgrep's severity (ERROR / WARNING / INFO) → Occam severity.
# Map Semgrep's metadata.impact (HIGH/MEDIUM/LOW) to refine when present.
printf '%s' "$raw" | jq --arg target "$TARGET" --arg ver "$(semgrep --version 2>/dev/null | head -1)" '{
    name: "semgrep",
    version: $ver,
    findings: [
        .results[]? | {
            severity: (
                .extra.severity as $s
                | .extra.metadata.impact as $i
                | if   $i == "HIGH"   or $s == "ERROR"   then "critical"
                  elif $i == "MEDIUM" or $s == "WARNING" then "high"
                  elif $i == "LOW"                       then "medium"
                  elif $s == "INFO"                      then "low"
                  else "info" end
            ),
            kind: (
                (.extra.metadata.category // "") as $c
                | if $c == "security"       then "security"
                  elif $c == "correctness"  then "bug"
                  elif $c == "performance"  then "perf"
                  elif $c == "best-practice" or $c == "maintainability" then "debt"
                  else "other" end
            ),
            rule_id:  (.check_id // "unknown"),
            file:     (.path | sub("^" + $target + "/?"; "")),
            line:     (.start.line // 0),
            message:  (.extra.message // .check_id),
            text:     (.extra.lines // "" | .[0:200])
        }
    ]
}'
