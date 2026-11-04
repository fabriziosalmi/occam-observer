#!/usr/bin/env bash
# docker-smoke.sh: run the image the way the README documents it and require
# /analyze to answer 200 with JSON through the published port.
#
#   scripts/docker-smoke.sh [image]          (default image: occam-observer:ci)
#
# The repo under analysis lives in a named volume created by root, so its
# owner is never the image's unprivileged `occam` user: the same situation as
# a host directory mounted with -v "$PWD:/repo". SMOKE_PORT picks the host
# port (default 19999), always bound to 127.0.0.1.
set -euo pipefail

IMAGE="${1:-occam-observer:ci}"
PORT="${SMOKE_PORT:-19999}"
NAME="occam-smoke-$$"
VOL="occam-smoke-repo-$$"

cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker volume rm -f "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; docker logs "$NAME" 2>&1 | tail -20 >&2 || true; exit 1; }

# Fixture repo, created as root inside the volume.
docker run --rm --user 0 --entrypoint sh -v "$VOL:/repo" "$IMAGE" -c '
    cd /repo && git init -q \
    && printf "def f():\n    return 1\n" > app.py \
    && git add . \
    && git -c user.email=smoke@local -c user.name=smoke commit -q -m init'

# Precondition: the repo owner differs from the user the API runs as,
# otherwise this run would not exercise the mounted-repo case at all.
owner="$(docker run --rm --entrypoint stat -v "$VOL:/repo:ro" "$IMAGE" -c %u /repo)"
runner="$(docker run --rm --entrypoint id "$IMAGE" -u)"
[ "$owner" != "$runner" ] || fail "repo owner uid ($owner) equals container uid ($runner)"
echo "repo owner uid=$owner, container uid=$runner"

# The documented shape: published port, repo mounted at /repo.
docker run -d --name "$NAME" -p "127.0.0.1:${PORT}:9999" -v "$VOL:/repo:ro" "$IMAGE" >/dev/null

code=000
for _ in $(seq 1 30); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/healthz" || true)"
    [ "$code" = "200" ] && break
    sleep 1
done
[ "$code" = "200" ] || fail "/healthz through the published port answered $code"
echo "/healthz -> $code"

body="$(mktemp)"
code="$(curl -s -o "$body" -w '%{http_code}' "http://127.0.0.1:${PORT}/analyze?path=/repo" || true)"
# jq from the image itself, so the host only needs docker and curl.
if [ "$code" != "200" ] \
    || ! docker run --rm -i --entrypoint jq "$IMAGE" -e 'type == "object"' < "$body" >/dev/null 2>&1; then
    fail "/analyze answered $code: $(head -c 600 "$body")"
fi
echo "/analyze -> $code, $(wc -c < "$body" | tr -d ' ') bytes of JSON"
rm -f "$body"
echo "PASS: docker smoke"
