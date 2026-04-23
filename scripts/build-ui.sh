#!/usr/bin/env bash
# Rebuild the React dashboard into api/public/ so the Go gateway can serve
# it at /ui/. Run this whenever you change anything under web/src/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB="${ROOT}/web"
OUT="${ROOT}/api/public"

command -v npm >/dev/null || { echo "npm not found — install Node.js 20+" >&2; exit 1; }

cd "$WEB"
if [ ! -d node_modules ]; then
    echo "→ installing web/ dependencies"
    npm ci
fi

echo "→ building dashboard"
npm run build

# Vite writes to web/dist by default; Go serves api/public.
rm -rf "$OUT"
mkdir -p "$OUT"
cp -R dist/. "$OUT/"
echo "→ wrote $(find "$OUT" -type f | wc -l | tr -d ' ') files to ${OUT}"
