# SaveVision backend API

`operator-web/server.js` exposes the local/backend API used by the wearer app and
operator console. It stores prototype data in `operator-web/data.json` so cases,
locations, events, tasks, and guidance survive server restarts without adding a
DB dependency yet.

Base URL in local dev: `http://localhost:8080`.

## Health and ICE

```http
GET /api/health
GET /api/ice
```

`/api/ice` returns `{ "iceServers": [...] }` for WebRTC.

## Case lifecycle

```http
POST   /api/cases
GET    /api/cases?status=open
GET    /api/cases/:caseId
PATCH  /api/cases/:caseId
POST   /api/cases/:caseId/claim
POST   /api/cases/:caseId/close
DELETE /api/cases/:caseId
```

Create a case from the wearer app:

```json
POST /api/cases
{
  "category": "medical",
  "source": "glasses",
  "status": "waiting",
  "sev": "urg",
  "injury": "unspecified emergency",
  "initialLocation": {
    "lat": 50.4501,
    "lng": 30.5234,
    "accuracyM": 12,
    "ts": 1760000000000
  },
  "deviceStatus": {
    "batteryPct": 78,
    "network": "cellular"
  }
}
```

Response includes the server IDs the app should keep:

```json
{
  "id": "C-10",
  "caseStatus": "open",
  "roomCode": "K7P9Q2",
  "matrixRoomId": null,
  "iceServers": [{ "urls": "stun:stun.l.google.com:19302" }]
}
```

Notes:

- `caseStatus` is the lifecycle status: `open`, `claimed`, `closed`, or
  `cancelled`.
- `status` is still available for clinical/operator text like `waiting`,
  `tourniquet applied`, etc., to keep the console cards readable.
- For the WebRTC dev harness, after creating a case the app can open the
  signaling WebSocket and send `{ "type": "create", "caseId": "C-10" }` to
  reuse the returned `roomCode`.

## Location

```http
POST /api/cases/:caseId/location
POST /api/cases/:caseId/location/batch
GET  /api/cases/:caseId/location/latest
GET  /api/cases/:caseId/location/history?since=1760000000000&limit=500
```

Location payload:

```json
{
  "lat": 50.4501,
  "lng": 30.5234,
  "accuracyM": 12,
  "heading": 80,
  "speedMps": 1.4,
  "source": "device",
  "ts": 1760000000000
}
```

Every location update also emits a `location.updated` event over WebSocket.

## Events and guidance history

```http
POST /api/cases/:caseId/events
GET  /api/cases/:caseId/events?after=1760000000000
POST /api/cases/:caseId/guidance
GET  /api/cases/:caseId/guidance
```

Generic event:

```json
POST /api/cases/C-10/events
{
  "type": "device.status",
  "actor": "wearer",
  "payload": { "batteryPct": 72, "network": "cellular" }
}
```

Guidance event uses the same payload shapes as `PROTOCOL.md`:

```json
POST /api/cases/C-10/guidance
{ "kind": "guidance", "text": "Apply firm direct pressure now" }
```

Supported `kind` values: `guidance`, `drawing`, `clear`, `image`, `map`.

## Tasks

```http
GET   /api/tasks?caseId=C-10
POST  /api/tasks
PATCH /api/tasks/:taskId
```

## Real-time WebSocket

Connect:

```text
ws://localhost:8080/api/ws
```

Subscribe to all cases:

```json
{ "type": "subscribe_cases" }
```

Subscribe to one case snapshot + updates:

```json
{ "type": "subscribe_case", "caseId": "C-10" }
```

Server messages include:

```json
{ "type": "cases.snapshot", "cases": [] }
{ "type": "case.created", "caseId": "C-10", "case": {} }
{ "type": "case.updated", "caseId": "C-10", "case": {} }
{ "type": "location.updated", "caseId": "C-10", "location": {} }
{ "type": "guidance.created", "caseId": "C-10", "event": {}, "guidance": {} }
{ "type": "case.event", "caseId": "C-10", "event": {} }
```

The existing operations console also uses a legacy `{ "type": "subscribe_sync" }`
subscription; keep it until the UI fully moves to the newer message names.
