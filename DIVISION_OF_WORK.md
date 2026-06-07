# Division of work

Three workstreams joined by [PROTOCOL.md](PROTOCOL.md) (payloads) and
[MATRIX.md](MATRIX.md) (transport). Build/test each on its own.

## Owner A — `user-ios/` (wearer app)

- SwiftUI app, signaling client, stream orchestration **(done — scaffolded)**
- **TODO:** integrate **matrix-rust-sdk**; join the encrypted room
- **TODO:** publish the **VisionClaw**/glasses camera track into the MatrixRTC call
- **TODO:** render `org.savevision.*` events on the HUD — text, drawings
  (normalised strokes), images, map. Renderer reference: `operator-web/public/glasses-sim.js`
- **TODO:** integrate Meta Wearables DAT SDK (iPhone-camera fallback for testing)

## Owner B — `operator-web/` (doctor interface)

- Doctor UI: POV view, drawing canvas, image + map + text senders, glasses
  simulator **(done — runnable, one-way doctor→wearer)**
- **TODO:** retarget transport to **matrix-js-sdk** + Element Call (replace the
  WebSocket/data-channel `send()` — UI stays); see MATRIX.md integration points
- **TODO:** doctor auth against the homeserver; on-call queue / multi-session

## Owner C / colleague — Matrix homeserver

- Provide homeserver base URL + Element Call URL ([MATRIX.md](MATRIX.md) config)
- Wearer↔doctor **pairing** (appservice/bot or on-call room)
- Power levels: only operators may send `org.savevision.*`

## Shared (change together, via PR review)

- [PROTOCOL.md](PROTOCOL.md) — payload shapes (used by A and B identically)
- [MATRIX.md](MATRIX.md) — event types, room model

## Suggested git flow

- `main` protected; feature branches `ios/*`, `web/*`, `matrix/*`
- A protocol/transport change requires review from affected owners
