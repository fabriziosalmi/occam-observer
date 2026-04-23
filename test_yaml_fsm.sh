#!/usr/bin/env bash
# test_yaml_fsm.sh — verifica parser awk FSM su config.yml reale
source ./telemetry_observer.sh --help > /dev/null 2>&1 || true

# Reimporta solo yaml_get dal file sorgente
eval "$(grep -A 50 '^yaml_get\(\)' telemetry_observer.sh | head -50)"

echo "=== Test awk FSM yaml_get ==="
printf "  %-30s → %s\n" "target_path"      "$(yaml_get config.yml target_path)"
printf "  %-30s → %s\n" "startup_delay"    "$(yaml_get config.yml startup_delay)"
printf "  %-30s → %s\n" "api_port"         "$(yaml_get config.yml api_port)"
printf "  %-30s → %s\n" "bell_on_critical" "$(yaml_get config.yml bell_on_critical)"
printf "  %-30s → %s\n" "regex_security"   "$(yaml_get config.yml regex_security)"
printf "  %-30s → %s\n" "regex_complexity (array)" "$(yaml_get config.yml regex_complexity)"

echo ""
COMPLEXITY="$(yaml_get config.yml regex_complexity)"
if echo "$COMPLEXITY" | grep -q "|"; then
    echo "✓ PASS — array YAML joinato con pipe: '$COMPLEXITY'"
else
    echo "✗ FAIL — atteso pipe-joined array"
fi
