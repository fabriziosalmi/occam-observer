# syntax=docker/dockerfile:1.6
# ─────────────────────────────────────────────────────────────────────────────
# Occam Observer — multi-stage container
#
#   docker build -t occam-observer .
#   docker run --rm -p 9999:9999 -v "$PWD:/repo" occam-observer
#   curl "http://127.0.0.1:9999/analyze?path=/repo"
#
# The container runs the TUI-less API mode: starts the Go gateway and, in
# parallel, keeps the engine warm against /repo. Agents consume /analyze,
# /trend, /. Single-node by design (matches the solo use case).
# ─────────────────────────────────────────────────────────────────────────────

# ── Stage 1: Go API gateway ──────────────────────────────────────────────────
FROM golang:1.22-alpine AS gobuild
WORKDIR /src
COPY api/go.mod api/go.sum* ./
RUN go mod download 2>/dev/null || true
COPY api/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/occam-api .

# ── Stage 2: runtime (Alpine — bash + git + sqlite + jq) ─────────────────────
FROM alpine:3.19
# safe.directory '*': the container exists to read repos mounted from the host,
# which belong to a host uid and never to the unprivileged `occam` user. Without
# it git refuses every mount ("detected dubious ownership") and /analyze fails.
# The check guards against repos planted by other users on a shared machine;
# here the only repos are the ones the operator chooses to mount.
RUN apk add --no-cache bash git jq sqlite coreutils ca-certificates \
    && addgroup -S occam && adduser -S -G occam occam \
    && git config --system --add safe.directory '*'

WORKDIR /opt/occam
COPY --from=gobuild /out/occam-api            /usr/local/bin/occam-api
COPY telemetry_observer.sh                    /opt/occam/telemetry_observer.sh
COPY config/                                  /opt/occam/config/
COPY api/public/                              /opt/occam/api/public/
RUN chmod +x /opt/occam/telemetry_observer.sh

# Data dir for the SQLite TSDB. Mount a volume here to keep history across
# container restarts: -v occam-data:/var/lib/occam
#
# API_HOST=0.0.0.0: inside the container 127.0.0.1 is the container's own
# loopback, which a published port never reaches. Binding all interfaces here
# exposes the API only on the container network; what reaches the host is
# decided by -p (use -p 127.0.0.1:9999:9999 to keep it host-local). The
# binary's own default outside the image stays 127.0.0.1.
ENV OCCAM_DATA_DIR=/var/lib/occam \
    OCCAM_DB=/var/lib/occam/snapshots.db \
    ENGINE_SCRIPT=/opt/occam/telemetry_observer.sh \
    API_HOST=0.0.0.0 \
    API_PORT=9999
RUN mkdir -p /var/lib/occam && chown -R occam:occam /var/lib/occam /opt/occam

USER occam
EXPOSE 9999
WORKDIR /opt/occam

# API-only runtime. Agents drive everything through:
#   GET /analyze?path=/repo → run the engine on demand, return JSON
#   GET /trend?...          → query the SQLite TSDB
#   GET /                   → last cached snapshot (503 until first analyze)
# No persistent watcher, no TUI — keeps the container stateless and cheap.
ENTRYPOINT ["/usr/local/bin/occam-api"]
