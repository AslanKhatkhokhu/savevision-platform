# SaveVision iOS — architecture & decisions

## The problem this scaffold solves

Stream **Meta Ray-Ban glasses** video + voice from the wearer's iPhone, over
**Matrix**, into a call with a remote operator — plus a thin text chat. No full
Matrix client; just login, one room, and a call.

## The decisive constraint

Element X (and any "MatrixRTC" call today) uses **Element Call**, a web app
loaded in a `WKWebView`. That web layer captures the camera itself via the
browser's `getUserMedia()`. **You cannot inject a native glasses camera track
into it.** Meanwhile `stoz3n-vision-agent` already has the exact native pipeline
we need: DAT SDK → `UIImage` frames → `RTCVideoSource` → `RTCPeerConnection`.

So the chosen split (confirmed with the product owner):

- **Media** = native WebRTC (reuse the vision-agent pipeline). 1:1 wearer→operator,
  DTLS-SRTP encrypted.
- **Signaling** = Matrix room events. SDP offer/answer + ICE candidates ride the
  encrypted Matrix room as marker-tagged messages.
- **Chat** = ordinary Matrix `m.room.message`s in the same room.

This reuses the most proven code, ships a working call fastest, and keeps the
door open to native MatrixRTC later (see Phase 2).

## Layers

| Layer | Files | Depends on |
|---|---|---|
| Glasses capture | `Glasses/*` | Meta DAT SDK |
| WebRTC media | `WebRTC/*` | `stasel/WebRTC` |
| Signaling contract | `Signaling/SignalingMessage.swift` | nothing (pure Swift) |
| Matrix transport | `Matrix/*`, `Signaling/MatrixSignaling.swift` | `matrix-rust-components-swift` |
| Call orchestration | `Call/CallController.swift` | the two protocols above |
| UI | `UI/*`, `App/*` | everything, via `AppModel` |

The seam is `SignalingTransport` (`Signaling/SignalingMessage.swift`).
`CallController` knows only that protocol; it never imports Matrix. Swapping the
transport (e.g. to native MatrixRTC custom events) touches only
`MatrixSignaling` + two methods in `MatrixRoomManager`.

## Call flow (offerer = wearer)

```
user taps "Call operator"
  → CallController.startCall()
      configure AVAudioSession (.playAndRecord/.voiceChat, allowBluetooth)
      WebRTCClient.setup(iceServers)          // STUN/TURN from Config
      capture.onFrame = webrtc.pushVideoFrame
      capture.startGlasses()  (or startIPhone)
      webrtc.createOffer → signaling.send(.offer)            ──▶ Matrix room
  operator answers                                            ◀── Matrix room
      signaling.onMessage(.answer) → webrtc.setRemoteDescription
  both trickle ICE: .candidate ⇄ Matrix room
  ICE connected → state = .connected (operator sees the POV)
  hang up → signaling.send(.hangup) + teardown
```

## Signaling wire format

A signaling message is a normal room message whose body is `SV1|` + JSON:

```
SV1|{"kind":"offer","sdp":"v=0...","ts":1733500000000}
SV1|{"kind":"candidate","candidate":"candidate:...","sdpMid":"0","sdpMLineIndex":0,"ts":...}
SV1|{"kind":"answer","sdp":"v=0...","ts":...}
SV1|{"kind":"hangup","ts":...}
```

`MatrixRoomManager` routes any `SV1|` body to the signaling handler and hides it
from the chat; everything else becomes a `ChatMessage`. The operator-web side
sends/parses the identical envelope (or can use `org.savevision.call.*` custom
events — the contract is ours to set, but `SV1|` messages are guaranteed to
round-trip through both `matrix-rust-sdk` and `matrix-js-sdk` timelines).

Why marker-messages instead of native custom event types? The high-level Rust
SDK timeline FFI reliably surfaces `m.room.message` on receive; arbitrary custom
event types are not dependably delivered through it. Marker-messages avoid that
limitation entirely for Phase 1.

## Audio

WebRTC's native audio engine captures the mic and does echo cancellation over
the iOS audio session. With the glasses connected as a Bluetooth audio device,
iOS routes their mic/speaker automatically. Piping the DAT SDK's *own* glasses
audio track into WebRTC is a Phase-2 refinement (a custom `RTCAudioSource`).

## Security / privacy posture

- Media is DTLS-SRTP encrypted peer-to-peer.
- Signaling + chat ride the (E2E-encrypted) Matrix room.
- One-way by design: the wearer only **publishes**; the offer requests no inbound
  video (`OfferToReceiveVideo:false`). The operator's guidance (Phase 2) comes
  back as room events, never as media the wearer must manage.
- Note: marker-message signaling is E2E-encrypted *if the room is encrypted*
  (it is, when created here). SDPs contain IPs/fingerprints — keep the room
  encrypted.

## HUD overlay / display status

The app now normalizes inbound operator chat into `DisplayOverlayItem`s:

- Matrix text/notice/emote → HUD message banner.
- Matrix image/gallery → HUD image card, with Matrix thumbnail download.
- Matrix location (`m.location`) → HUD location card with parsed `geo:` coords.
- Plain-message fallback `SVHUD|{...}` → SaveVision guidance/image/map/clear
  payloads using the same shapes as `../PROTOCOL.md`.

Those items render in the iPhone UI as a **virtual Ray-Ban overlay** (chat debug
strip, call overlay, and a full debug history screen). The same items are also
submitted to `MWDATDisplay` through `StreamSessionManager` when a display-capable
Ray-Ban Display session is available. The renderer seam remains
`DisplayOverlayRendering`, so the UI and Matrix parsing are independent from the
native display transport.

## Phase 2 / later

1. **Glasses-mic audio** into WebRTC via a custom audio source.
2. **Optional: native MatrixRTC/LiveKit.** If full Element-client interop is
   wanted, publish the glasses track to the LiveKit SFU that Element Call uses
   (LiveKit iOS SDK + the MatrixRTC token flow). Replaces the P2P media path;
   the `SignalingTransport` seam means the call-control code barely changes.
```
