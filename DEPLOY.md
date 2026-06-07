# Share SaveVision with a public link

`localhost:8080` only works on the machine running the server. To let a friend /
sponsor open it, host it. The static pages (`demo.html`, the landing `index.html`,
`console.html`, `map.html`, the mockups) work on any static host — no server.

## Option 1 — Netlify Drop (fastest, zero setup, ~30 seconds)
1. Open https://app.netlify.com/drop
2. Drag the **`operator-web/public`** folder onto the page.
3. You instantly get a public URL like `https://random-name.netlify.app`.
4. Share `…netlify.app/demo.html` (or just the root for the landing page).

## Option 2 — Netlify / Vercel from the repo (a real, updating link)
Netlify (uses `netlify.toml` in this repo, publishes `operator-web/public`):
```bash
npx netlify-cli deploy --prod
```
Vercel:
```bash
cd operator-web/public && npx vercel --prod
```
Both give a permanent HTTPS URL and redeploy when you push.

## Option 3 — Share your RUNNING server live (temporary, includes WebRTC pairing)
Keep `npm start` running, then expose it with a tunnel:
```bash
# Cloudflare (no signup):
npx cloudflared tunnel --url http://localhost:8080
# or ngrok:
npx ngrok http 8080
```
It prints a public `https://…` URL — share it. Works only while your machine +
tunnel stay on, but the full app (incl. glasses-sim ↔ operator) works.

## Option 4 — Friend runs it locally (they have repo access)
```bash
git clone https://github.com/AslanKhatkhokhu/SaveVision.git
cd SaveVision/operator-web && npm install && npm start
# open http://localhost:8080  ON THEIR OWN MACHINE
```

## What works where
| Page | Static host (Opt 1/2) | Tunnel/local (Opt 3/4) |
|------|:--:|:--:|
| Landing `/`, `demo.html`, `console.html`, `map.html`, mockups | ✅ | ✅ |
| `glasses-sim.html` ↔ `medic.html` live pairing (WebRTC + WS) | ❌ (needs the Node server) | ✅ |

For sponsors, **Option 1 + share `/demo.html`** is the quickest impressive link.
