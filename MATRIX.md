# SaveVision on Matrix — secure transport

SaveVision carries **everything over [Matrix](https://matrix.org)**: the live
video/audio call *and* the doctor's one-way guidance. Matrix is an open,
decentralised, end-to-end-encrypted protocol — self-hosted, so there is **no
third-party cloud** in the path. That matches the project's security rule:
E2E always, no third party.

> Your colleague already runs an open-source Matrix homeserver. SaveVision
> **plugs into it** — we don't reinvent comms. Drop the homeserver base URL into
> the configs below and the apps become Matrix clients.

## Why Matrix here

- **E2E encryption by default** (Olm/Megolm) on every room — POV and guidance are encrypted between the wearer's device and the doctor's browser.
- **Self-hostable** (Synapse / Dendrite / Conduit-conduwuit) — full data sovereignty, deployable on-prem or in-country.
- **Identity, rooms, federation, access control** come for free — no custom auth/signaling server to secure.
- **Real-time A/V** via **MatrixRTC** (MSC3401) / **Element Call** (LiveKit SFU), with E2E-encrypted media.
- **Arbitrary structured events** carry the doctor's drawings / images / map.

## Mapping

| SaveVision piece | On Matrix |
|---|---|
| One emergency session | one **encrypted Matrix room** (wearer + assigned doctor) |
| Video + audio call | **MatrixRTC / Element Call** session in that room |
| Glasses → app POV capture | **VisionClaw** feeds the camera track into the call |
| Doctor → wearer text / drawing / image / map | **custom E2E room events** (`org.savevision.*`) |
| Example image / frozen frame | uploaded as `mxc://…`, referenced in the event |
| Operator web interface | a **matrix-js-sdk** web client (this `operator-web`, retargeted) |
| Wearer app | **matrix-rust-sdk** (cross-platform; powers Element X / iOS / Android) |

## One-way guidance = custom events

Only the doctor sends application data. Each payload from
[PROTOCOL.md](PROTOCOL.md) becomes a room event the wearer's client renders:

```jsonc
// event type: org.savevision.drawing  (sent into the encrypted room by the doctor)
{ "kind": "drawing",
  "strokes": [{ "color": "#00e0ff", "points": [{"x":0.4,"y":0.5}] }] }
```

Event types: `org.savevision.guidance`, `.drawing`, `.image`, `.map`, `.clear`.
The wearer's app subscribes to room timeline events of these types and draws
them on the HUD. It never *sends* these — enforced by room power levels
(operators get send rights for `org.savevision.*`; wearers do not).

## Integration points (per component)

**operator-web → Matrix web client**
- Add `matrix-js-sdk`; sign in / use an application-service token against the colleague's homeserver.
- Replace the WebSocket signaling with: create/join the room, start an Element Call widget for A/V, and `client.sendEvent(roomId, "org.savevision.drawing", payload)` for guidance.
- The drawing/image/map/text UI in `public/` stays — only the `send()` transport changes.

**user-ios → matrix-rust-sdk**
- Embed `matrix-rust-sdk`; join the room; render incoming `org.savevision.*` timeline events on the display.
- Publish the VisionClaw/glasses camera track into the MatrixRTC call.

**Homeserver (colleague's repo)**
- Provide: base URL, a registration/login path for devices, and a room-creation flow (e.g. an application service that pairs a wearer "call for help" with an on-call doctor).
- Configure power levels so only operators can send `org.savevision.*`.

## Config (placeholder)

```jsonc
// config.json — fill from your colleague's homeserver
{
  "homeserverUrl": "https://matrix.YOUR-DOMAIN",
  "elementCallUrl": "https://call.YOUR-DOMAIN",
  "savevisionEventPrefix": "org.savevision"
}
```

## What I need from you to wire it

- The **homeserver base URL** and the **repo** your colleague uses (Synapse/Dendrite/Conduit?).
- Whether A/V should use **Element Call (MatrixRTC/LiveKit)** or legacy 1:1 `m.call.*`.
- How a wearer gets **paired to a doctor** (open bot/appservice, or a fixed on-call room?).

Until that's available, `operator-web` + `glasses-sim.html` run the **identical
payloads** over a local WebRTC harness so the product is fully demoable today.
