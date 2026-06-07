# SaveVision — Full API reference

Backends (identical contract): **Node** `operator-web/server.js` and **Cloudflare
Worker + Durable Object** `operator-web/worker.js`.

Base URLs:
- Local: `http://localhost:8080`
- Deployed: `https://your-worker.example.workers.dev`

All REST responses are JSON. CORS is open (`Access-Control-Allow-Origin: *`).
Data is held in memory + persisted (JSON file on Node, DO storage on Cloudflare).
No auth on the prototype REST/WS layer (the production transport is Matrix; see §5).

---

## 1. REST API

### Health & ICE
| Method | Path | Response |
|---|---|---|
| GET | `/api/health` | `{ ok, cases, events, locations }` |
| GET | `/api/ice` | `{ iceServers: [{ urls }] }` (STUN; TURN via env) |

### Cases
| Method | Path | Body / query | Response |
|---|---|---|---|
| GET | `/api/cases` | `?status=open&operator=…&limit=200` | `Case[]` (newest first) |
| POST | `/api/cases` | `CaseCreate` (below) | `Case` + `{ iceServers }` |
| GET | `/api/cases/:id` | — | `CaseSnapshot` (case + locations + events + guidance) |
| PATCH | `/api/cases/:id` | partial `Case` (+ `actor`) | `Case` |
| DELETE | `/api/cases/:id` | — | `{ ok:true }` |
| POST | `/api/cases/:id/claim` | `{ operator, operatorId?, userId? }` | `Case` (caseStatus=`claimed`) |
| POST | `/api/cases/:id/close` | `{ reason? }` | `Case` (caseStatus=`closed`) |

`CaseCreate` example:
```json
{ "category":"medical", "source":"glasses", "status":"waiting", "sev":"urg",
  "injury":"unspecified emergency",
  "initialLocation":{ "lat":50.45,"lng":30.52,"accuracyM":12,"ts":1760000000000 },
  "deviceStatus":{ "batteryPct":78,"network":"cellular" } }
```
Response adds server IDs to keep: `id`, `caseStatus` (`open|claimed|closed|cancelled`),
`roomCode` (6-char WebRTC dev room), `matrixRoomId`, `iceServers`.
- `caseStatus` = lifecycle; `status` = free-text clinical label (`waiting`, `tourniquet applied`…).

### Location
| Method | Path | Body / query | Response |
|---|---|---|---|
| POST | `/api/cases/:id/location` | `Location` | `Location` |
| POST | `/api/cases/:id/location/batch` | `{ locations:[Location…] }` | `{ locations:[…] }` |
| GET | `/api/cases/:id/location/latest` | — | `Location \| null` |
| GET | `/api/cases/:id/location/history` | `?since=ts&limit=500` | `Location[]` (asc) |

`Location`: `{ lat, lng, accuracyM?, altitudeM?, heading?, speedMps?, source?, ts? }`
(accepts `latitude/longitude`, `accuracy`, `course`, `speed`, `timestamp` aliases).
Every location emits a `location.updated` event over WebSocket.

### Events & guidance history
| Method | Path | Body / query | Response |
|---|---|---|---|
| GET | `/api/cases/:id/events` | `?after=ts&limit=200` | `Event[]` (asc) |
| POST | `/api/cases/:id/events` | `{ type, payload?, actor?, ts? }` | `Event` |
| GET | `/api/cases/:id/guidance` | `?limit=100` | guidance `Event[]` |
| POST | `/api/cases/:id/guidance` | `Guidance` (kind: guidance/drawing/clear/image/map) | `Event` |

### Tasks
| Method | Path | Body | Response |
|---|---|---|---|
| GET | `/api/tasks` | `?caseId=…` | `Task[]` |
| POST | `/api/tasks` | `{ text, assignee, prio?, caseId? }` | `Task` |
| PATCH | `/api/tasks/:id` | partial `Task` | `Task` |

### AI guidance proposal (operator-approval gate) — Claude vision
| Method | Path | Body | Response |
|---|---|---|---|
| POST | `/api/guidance` | `{ frame: dataURL(JPEG), hint? }` | `{ proposal:{ assessment, march:[{step,action}], banner, steps:[] }, model?, usage? }` |

- **Opt-in + paid:** set `ANTHROPIC_API_KEY` (Worker secret / env) to enable real
  Claude vision; optional `ANTHROPIC_MODEL` (default `claude-haiku-4-5-20251001`).
  No key (or no frame) → a **free sample** ($0). Each real call is billed per
  Anthropic pricing (one image + short JSON; cheapest on Haiku).
- The operator **approves** the `banner` before it reaches the wearer.
- **ICE/TURN (#1):** `/api/ice` adds a TURN server when `TURN_URL`,`TURN_USER`,`TURN_PASS` env are set (else STUN only).

---

## 2. WebSocket API

One socket to `ws(s)://<host>/` (any path; e.g. `/api/ws`). JSON messages.

### Client → server
| `type` | Fields | Purpose |
|---|---|---|
| `create` | `caseId?` | open a WebRTC room (reuses the case `roomCode` if `caseId` given) |
| `rejoin` | `room` | reconnect a dropped publisher |
| `join` | `room` | operator joins a room |
| `offer` / `answer` / `candidate` | `sdp`/`candidate` | relayed to the other peer |
| `subscribe_sync` | — | legacy: snapshot + all case/task updates |
| `subscribe_cases` | — | snapshot of all cases, then updates |
| `subscribe_case` | `caseId` | snapshot + updates for one case |
| `unsubscribe_case` | `caseId` | stop one-case updates |
| `ping` | — | → `pong` |

### Server → client
`room_created {room,caseId?}`, `room_rejoined {room}`, `room_joined`, `peer_joined`,
`peer_left`, `offer`/`answer`/`candidate`, `error {message}`,
`sync_snapshot {cases,tasks}`, `cases.snapshot {cases}`, `case.snapshot {caseId,case}`,
`case.created`/`case.updated {caseId,case}`, `case.deleted {caseId}`,
`location.updated {caseId,location,case}`, `guidance.created {caseId,event,guidance}`,
`case.event {caseId,event}`, `task.created`/`task.updated {task}`,
`sync {entity,data}` (legacy mirror).

---

## 3. Data models
```ts
Case = { id, caseStatus, status, category, source, name, injury, sev, sector,
         operator, operatorId?, danger, roomCode, matrixRoomId, lat?, lng?,
         latestLocation?, eta?, createdAt, updatedAt }
Location = { id, caseId, lat, lng, accuracyM?, altitudeM?, heading?, speedMps?, source, ts }
Event = { id, caseId, type, payload, actor, ts }   // type e.g. case.created, location.updated, guidance.image
Task  = { id, caseId?, text, assignee, prio, status, createdAt, updatedAt }
```

---

## 4. Guidance payloads (doctor → wearer) — one-way
`kind`: `guidance`{text} · `drawing`{strokes:[{color,points:[{x,y}]}]} (coords 0..1) ·
`image`{url|dataUrl,caption} · `map`{label,bearing} · `clear`. Carried over the
WebRTC data channel (dev), the backend `…/guidance` API, or Matrix (§5).

---

## 5. Matrix transport (production) — see MATRIX.md / MATRIX_CONNECTION.md
- One **encrypted room per case**. Video/audio over **MatrixRTC / Element Call**
  (LiveKit focus from `/.well-known/matrix/client` → `org.matrix.msc4143.rtc_foci`).
- **LiveKit token**: `POST /_matrix/client/v3/user/{uid}/openid/request_token` →
  `POST {livekit_service_url}/sfu/get { room, openid_token, device_id }` → `{ url, jwt }`.
- **Guidance over Matrix** — two carriers the iOS app reads from the timeline:
  - `m.image` events (operator uploads to `mxc://`, sends `m.room.message` msgtype `m.image`).
  - `SVHUD|<json>` text messages (fallback for guidance/drawing/map/clear when the
    SDK won't surface custom events): `SVHUD|{"kind":"guidance","text":"…","ts":…}`.
  - Custom `org.savevision.*` room events (guidance/drawing/image/map/clear) — for clients that read custom events.
- **1:1 WebRTC-over-Matrix (`SV1|`)**: the wearer posts an SDP offer as an `SV1|`
  message; an operator page answers (`setRemoteDescription` → `createAnswer` →
  `SV1|` answer + ICE candidates). See §6.

---

## 6. Placing a call (what it takes)
Two supported paths:
1. **Element Call / MatrixRTC (group, LiveKit)** — the wearer (Element X) and the
   operator both join the room's call; the operator views via `rtc-view.js`
   (in-app, multi-stream). Needs LiveKit reachable directly (grey-cloud the SFU host).
2. **Custom `SV1|` 1:1 WebRTC** — the wearer sends an `SV1|` offer into the room;
   a browser operator must **answer** it. That answerer = `operator-web/matrix/matrix-client.js`
   (Matrix login + room send/receive) + `operator.js`'s peer logic
   (`setRemoteDescription(offer)` → `createAnswer` → send `SV1|` answer → trickle
   candidates). Combine those two into one operator page to complete this path.

---

## Live demo flow
1. Wearer/caller `POST /api/cases` (mobile app) → case appears in the console (WS).
2. Wearer streams location → `POST /api/cases/:id/location` → console + glasses map update.
3. Operator sends guidance/photo → wearer HUD (`savevision.html`) renders it.
4. Live video over MatrixRTC; operator watches all streams in `medic.html`.
