# SaveVision signaling protocol (the shared contract)

Both halves of the project — `user-ios/` (publisher) and `operator-web/`
(viewer) — talk to the same signaling server and obey the messages below.
**This file is the seam between the two team members.** As long as both sides
honor it, they can be built and tested independently.

## Roles

| Role | Who | WebRTC | Media |
|------|-----|--------|-------|
| `user` | glasses wearer's iOS app | **offerer**, creates data channel | sends video + audio |
| `operator` | web dashboard | **answerer** | receives; sends guidance |

## Transport

- **Signaling**: one WebSocket to the server (`ws://` / `wss://`).
- **Media + guidance**: a direct WebRTC `RTCPeerConnection` between the two peers.
- **ICE**: `GET /api/ice` → `{ "iceServers": [...] }`.

## Message flow

```
user                      server                     operator
 │  {type:create}          │                            │
 │ ───────────────────────▶│                            │
 │  {type:room_created,     │                           │
 │        room:"ABC123"} ◀──│                           │
 │                          │     {type:join,room} ◀─────│
 │                          │──▶ {type:room_joined}      │
 │   {type:peer_joined} ◀───│                            │
 │  (create offer + DC)     │                            │
 │  {type:offer,sdp} ──────▶│──▶ {type:offer,sdp}        │
 │                          │   {type:answer,sdp} ◀──────│
 │  {type:answer,sdp} ◀─────│                            │
 │  {type:candidate} ⇄──────│──────⇄ {type:candidate}    │
 │ ═══════════ WebRTC media + data channel ═════════════ │
```

## Messages

| `type` | Sent by | Fields | Meaning |
|--------|---------|--------|---------|
| `create` | user | optional `caseId` | open a new room. If `caseId` is provided, the server reuses the backend case's `roomCode` |
| `room_created` | server | `room` | room code to share |
| `rejoin` | user | `room` | reconnect after backgrounding |
| `room_rejoined` | server | `room` | reconnect ok |
| `join` | operator | `room` | join by code |
| `room_joined` | server | — | join ok |
| `peer_joined` | server | — | the other peer is present → start offer |
| `peer_left` | server | — | other peer disconnected |
| `offer` | user | `sdp` | SDP offer |
| `answer` | operator | `sdp` | SDP answer |
| `candidate` | both | `candidate` | trickle ICE candidate |
| `error` | server | `message` | room full / not found / ended |

## Application payloads — ONE-WAY: doctor → wearer

Channel label: `guidance`. The **wearer** (offerer) creates it; **only the
operator (doctor) sends on it.** The wearer never sends application data back —
they only publish their live POV video + audio. Every payload is JSON with a
`kind` and a `ts`:

| `kind` | Fields | Rendered on the glasses as |
|--------|--------|----------------------------|
| `guidance` | `text` | instruction banner (red if it matches stop/unsafe) |
| `drawing` | `strokes: [{ color, points:[{x,y}] }]` | freehand overlay. **Coords are normalised 0..1** so they map to any display resolution |
| `clear` | — | wipe the overlay + banner |
| `image` | `dataUrl`, `caption` | example diagram / frozen frame inset (downscaled JPEG) |
| `map` | `bearing` (0–359°), `label` | direction arrow + label |

```json
{ "kind": "drawing", "ts": 1733500000000,
  "strokes": [{ "color": "#00e0ff", "points": [{"x":0.4,"y":0.5},{"x":0.6,"y":0.55}] }] }
```

## Backend case/location/events API

The wearer app also talks to the backend REST API for durable case metadata,
location, device status, and reconnect history. See [BACKEND_API.md](BACKEND_API.md).
The signaling `create` message can include the returned `caseId`:

```json
{ "type": "create", "caseId": "C-10" }
```

The server replies with the same local room code as the case:

```json
{ "type": "room_created", "room": "K7P9Q2", "caseId": "C-10" }
```

## iOS virtual overlay fallback

The iOS wearer app mirrors ordinary inbound Matrix chat into a virtual glasses
HUD for transparency/debugging:

- text / notice / emote → message banner
- image / gallery → image card
- location (`m.location`) → location card

Because high-level Matrix timeline SDKs may not always expose arbitrary custom
event payloads, the iOS app also accepts a plain-message fallback prefix:

```text
SVHUD|{"kind":"guidance","text":"Apply firm pressure now","ts":1733500000000}
SVHUD|{"kind":"image","dataUrl":"data:image/jpeg;base64,...","caption":"Tourniquet"}
SVHUD|{"kind":"map","label":"Move to casualty collection point","bearing":90}
SVHUD|{"kind":"clear"}
```

These messages are hidden from normal chat and rendered only on the overlay.

## Production transport: Matrix (see [MATRIX.md](MATRIX.md))

The WebSocket signaling + WebRTC data channel above are the **local dev
harness**. In production everything rides **Matrix**, end to end:

- **Video + audio** → MatrixRTC / Element Call (E2E encrypted).
- **The doctor→wearer payloads** (same `kind` shapes) → custom **E2E-encrypted
  Matrix room events** (`org.savevision.guidance`, `.drawing`, `.image`, `.map`,
  `.clear`). Images upload to the homeserver as `mxc://` and the event carries
  the URI.

The payload shapes are identical in both transports, so swapping dev → Matrix
does not change the renderer in `user-ios` or the simulator.

## Try it end-to-end in two browser tabs (no hardware, no Matrix)

1. `cd operator-web && npm install && npm start`
2. Tab A → `http://localhost:8080/glasses-sim.html` → **Call for help** → copy the code.
3. Tab B → `http://localhost:8080/` → enter the code → **Join**.
4. Draw on the POV, send text / an image / a direction — it appears on the
   simulated glasses HUD in Tab A.
