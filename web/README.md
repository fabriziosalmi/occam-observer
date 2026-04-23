# web/

React + Vite + Tailwind source for the Occam Observer dashboard.

The Go gateway (`api/main.go`) serves the **built** bundle from
`api/public/` at `http://127.0.0.1:9999/ui/`. This directory is the
*source*; `api/public/` is the deployed artifact.

## Develop

```bash
cd web
npm ci
npm run dev      # Vite dev server (typically http://localhost:5173/)
```

Run the engine separately (`./telemetry_observer.sh /path/to/repo`) and
the UI will poll `GET /` for live data.

## Build → deploy to `api/public/`

From the repo root:

```bash
./scripts/build-ui.sh
```

This runs `npm ci` (if needed) + `npm run build` inside `web/`, then
replaces `api/public/` with the fresh bundle. Commit the updated artifacts
if you want `go run ./api` to ship the new UI out of the box.

## Source layout

- `src/App.tsx` — single-page dashboard
- `src/index.css` / `App.css` — Tailwind directives + theme tokens
- `index.html` — Vite entry (imports `src/main.tsx`)
- `tailwind.config.js` / `postcss.config.js` — styling pipeline
- `vite.config.ts` — `base: "./"` so the bundle is relocatable under `/ui/`

## Data contract

The dashboard polls `GET /` every second and `GET /analyze?path=…` on
demand from the playground. Response schema: [`docs/api/telemetry.md`](../docs/api/telemetry.md).

The component is defensive against missing optional fields (older engine
versions, partial cache writes), but schema drift should be resolved by
bumping the engine rather than by adding UI fallbacks.
