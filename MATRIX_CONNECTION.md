# Connecting the iOS app (glasses + VisionClaw) ↔ operator tool, through Matrix

This is how the two halves actually connect. **One Matrix room per emergency
case; all guidance for that case lives in one Matrix thread.** Matrix on
matrix.org is **free** — connecting costs nothing (only an optional Claude
guidance call is paid).

```
  iOS app  (VisionClaw → glasses camera/POV)            Operator tool (web)
  matrix-rust-sdk                                        matrix-js-sdk
        │                                                      │
        │   joins case room on matrix.org (E2E encrypted)      │
        └───────────────────────►  ROOM  ◄─────────────────────┘
              ┌─────────────────────────────────────────────┐
              │ MatrixRTC / Element Call  → glasses POV video │  (operator watches)
              │ THREAD (root = org.savevision.case)           │
              │   ├─ org.savevision.guidance  (text)          │  operator → wearer
              │   ├─ org.savevision.drawing   (strokes)       │  (one-way; the
              │   ├─ org.savevision.image     (photo/AI)      │   wearer renders
              │   ├─ org.savevision.map / .livemap            │   these on the HUD/
              │   └─ org.savevision.clear                     │   Mac monitor)
              └─────────────────────────────────────────────┘
```

## Roles
- **iOS app** = VisionClaw captures the glasses POV and **publishes it into the
  room's MatrixRTC call**; it **renders** the `org.savevision.*` thread events on
  the display / Mac monitor. (No display glasses? POV still streams; guidance is
  shown on the Mac + spoken.)
- **Operator tool** = joins the same room, watches the POV (Element Call), and
  **sends guidance as threaded events** (text/drawing/image/map). Multiple
  operators can watch the same thread.

## Why threads
Each case = one room with a **root event** (`org.savevision.case`). Every piece
of guidance is a **threaded reply** (`m.relates_to: m.thread`) under that root.
That keeps a clean, ordered, per-case conversation — the "Matrix thread
functionality" the operator tool needs — and lets an operator scroll the whole
history of a case, or hand it off, without losing context.

## Operator side (this repo) — `operator-web/matrix/matrix-client.js`
```js
import { SaveVisionMatrix } from "./matrix/matrix-client.js";
const mx = await new SaveVisionMatrix({
  homeserverUrl: "https://matrix.org",
  accessToken: "syt_…",          // from Element → Settings → Help & About → Access Token
  userId: "@you:matrix.org",
}).start();

const { roomId, rootEventId } = await mx.openCase({ id:"C-1", name:"Yusuf K.", injury:"leg bleed", invite:["@wearer:matrix.org"] });
// watch POV:  <iframe src={mx.callWidgetUrl(roomId)} allow="camera;microphone">
// send guidance (threaded):
await mx.sendGuidance(roomId, rootEventId, "guidance", { text:"Apply tourniquet high & tight" });
await mx.sendGuidance(roomId, rootEventId, "drawing",  { strokes:[/*…*/] });
await mx.sendGuidance(roomId, rootEventId, "livemap",  { on:true, lat:48.2, lng:16.37 });
```
Wire `openCase` to a case row (POV/code feature), and the existing UI's send
buttons to `sendGuidance(...)` instead of the local WebRTC data channel. The
payload shapes are identical to [PROTOCOL.md](PROTOCOL.md), so the UI doesn't change.

## iOS side — VisionClaw + matrix-rust-sdk
1. Add **matrix-rust-sdk** to the iOS app (Element X uses it; cross-platform).
2. **Log in** to matrix.org; **join** the case room (invite from the operator, or
   a "call for help" appservice creates the room and invites both).
3. **VisionClaw** captures the glasses camera → publish that track into the
   room's **MatrixRTC** call (Element Call protocol).
4. **Subscribe** to the case thread; render `org.savevision.*` events on the
   display / Mac monitor (port `glasses-sim.js`'s renderer).
   - Reference: VisionClaw is at `../visionclaw` (its DAT/camera capture) — swap
     its Gemini transport for matrix-rust-sdk.

## To go live (what I need from you — all free)
1. **matrix.org access token** (from Element) — for the operator client to log in.
2. A **wearer test account** (`@wearer:matrix.org`) to invite.
3. Confirm A/V via **Element Call** (default) vs legacy `m.call.*`.

With the token I can: `npm i matrix-js-sdk`, wire `matrix-client.js` into the
operator UI, create a case room, and post a threaded guidance event end to end.
