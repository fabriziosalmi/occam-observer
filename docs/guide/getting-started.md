# Getting Started

Occam Observer is designed to be as lightweight and frictionless as possible.

## Prerequisites

- **macOS** or **Linux**
- `git`
- `bash` (v3.2+)
- `go` (for the API Gateway)
- `fswatch` (macOS) or `inotifywait` (Linux) for file system events.

## Installation

Clone the repository and build the Go API Gateway:

```bash
git clone https://github.com/fabriziosalmi/occam-observer.git
cd occam-observer/api
go build -o server main.go
```

## Running the Observer

To start watching a target repository:

```bash
cd occam-observer
./telemetry_observer.sh /path/to/your/git/repo
```

The script will instantly launch the terminal UI (TUI) and spawn the Go API server in the background.

## Accessing the Dashboard

Once running, open your browser and navigate to:

```text
http://127.0.0.1:9999/ui/
```

This will load the **React Dashboard** which displays real-time health metrics, semantic intelligence, and a live JSON API Playground.

## Headless API Mode

If you just want the JSON output without launching the continuous observer daemon, use the `--json` flag:

```bash
./telemetry_observer.sh --json /path/to/your/git/repo
```

This acts as a "one-shot" analysis and outputs the telemetry payload to `stdout`.
