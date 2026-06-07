# Deploy SaveVision on Cloudflare (Workers + Durable Object + static assets)

The whole web app runs as **one Cloudflare Worker**:
- **Static frontend** (`operator-web/public/`) → the `[assets]` binding.
- **REST API** (`/api/cases`, `/api/tasks`, `/api/guidance`, `/api/ice`) and the
  **WebSocket** (WebRTC signaling + live operator sync) → a **Durable Object**
  (`Hub`) — required because Workers are stateless and can't hold/broadcast
  connections or keep room/sync state.
- **Persistence** → Durable Object storage (replaces `data.json`).

Files: `operator-web/worker.js`, `operator-web/wrangler.toml`. Validated with
`wrangler deploy --dry-run` ✓.

## Prerequisites
- A **Cloudflare account** (the **free plan works** — the DO uses a SQLite-backed
  class, which is free-tier eligible).
- **Node 22+** recommended (wrangler 4 wants it; Node 21 builds with warnings).

## Deploy (interactive)
```bash
cd operator-web
npx wrangler login        # opens the browser to authorize your Cloudflare account
npx wrangler deploy       # builds + uploads the Worker, DO, and assets
```
You'll get a URL like **`https://savevision.<your-subdomain>.workers.dev`**.
Everything — landing, medic, console, map, glasses-sim, mobile, `/api/*`, and the
WebSocket — is served from that one HTTPS domain.

## Deploy (CI / token, non-interactive)
Create a Cloudflare API token with **Workers Scripts: Edit** (and Account →
Workers permissions), then:
```bash
cd operator-web
CLOUDFLARE_API_TOKEN=xxxxx CLOUDFLARE_ACCOUNT_ID=yyyyy npx wrangler deploy
```

## Local dev
- Cloudflare-like local run: `npx wrangler dev` (serves the Worker + DO + assets locally).
- Plain Node (unchanged): `node server.js`.

## After deploy
- Public **HTTPS** URL → share with your friend; the **phone camera works** (HTTPS).
- The **Matrix** call path (Element/MatrixRTC) is independent and works anywhere.
- The built-in **WebRTC signaling** (glasses-sim ↔ medic) still needs a **TURN**
  relay for cross-network peers; same-network works. (Production should use the
  Matrix/LiveKit path, which already has a relay.)
- Custom domain: add a route in `wrangler.toml` or the Cloudflare dashboard.
