# SaveVision — iOS app (`io.example.savevision`)

The **wearer** app. Streams the wearer's point-of-view video + voice from **Meta
Ray-Ban glasses** to a remote **operator** over **Matrix**, gives them a simple
text chat with that operator, and mirrors operator guidance onto Ray-Ban Display
when a display-capable device/session is available.

This app fuses two existing codebases:

- **[`stoz3n-vision-agent`](../../stoz3n-vision-agent)** — the glasses capture +
  native WebRTC pipeline (Meta Wearables DAT SDK → `CustomVideoCapturer` →
  `RTCPeerConnection`). Reused here as the `Glasses/` + `WebRTC/` layers.
- **[`element-x-ios`](../../element-x-ios)** — *not* reused as code (it is
  AGPL-3.0). Instead SaveVision talks to the same Matrix stack Element X uses via
  the underlying **`matrix-rust-components-swift`** binary package (Apache-2.0).

> **Phase 1:** Login → 1:1 operator chat → one-way POV+voice call.
> Operator chat text/images/locations are mirrored into an in-app
> **virtual glasses overlay** for transparency/debugging and submitted to native
> Ray-Ban Display through Meta DAT `MWDATDisplay` 0.7+.

---

## Architecture in one diagram

```
 Meta Ray-Ban ──video──▶ StreamSessionManager ──UIImage frames──▶ WebRTCClient
   glasses     (DAT SDK)                                          (native, offerer)
                                                                       │
 iPhone mic ──audio──▶ iOS audio session ──▶ WebRTC native audio ──────┤
 (or glasses BT route)                                                  │
                                                                  POV video + voice
                                                                       │  (DTLS-SRTP)
                                                                       ▼
        SDP offer / answer / ICE  ◀──────────  MatrixSignaling
        carried as "SV1|" messages            (over the Matrix room)
                                                                       │
                                                                       ▼
                                                                   operator
                                                              (operator-web, answerer)
```

**Why native WebRTC + Matrix signaling, not Element Call?** Element Call runs in
a `WKWebView` and captures the camera itself via the browser — there is no way to
feed a native *glasses* track into it. So media uses the proven native pipeline
from `stoz3n-vision-agent`; only the **signaling** (SDP/ICE) rides Matrix, as
specially-marked room messages that round-trip through both `matrix-rust-sdk`
(this app) and `matrix-js-sdk` (operator-web). See
[`ARCHITECTURE.md`](ARCHITECTURE.md) for the full rationale and the Phase-2
migration path to native MatrixRTC/LiveKit.

---

## Project layout

```
ios-app/
  project.yml                 xcodegen spec (deps + bundle id)
  SaveVision/
    App/        SaveVisionApp · AppModel · Config
    Matrix/     MatrixClientManager · MatrixRoomManager · MatrixModels
    Signaling/  SignalingMessage (contract) · MatrixSignaling (transport)
    Glasses/    WearablesManager · StreamSessionManager · IPhoneCameraManager · VideoDecoder
    DisplayOverlay/  HUD models · manager · virtual overlay view
    WebRTC/     WebRTCClient · CustomVideoCapturer · WebRTCConfig · RTCVideoView
    Call/       CallController (offerer; ties capture + webrtc + signaling)
    UI/         RootView · LoginView · HomeView · ChatView · CallView
    Info.plist
```

---

## Build it

The `.xcodeproj` is **generated**, not committed.

```bash
brew install xcodegen          # once
cd ios-app
xcodegen generate              # creates SaveVision.xcodeproj from project.yml
open SaveVision.xcodeproj
```

Before generating, create your secrets file (it holds the Team ID + Meta
credentials, is gitignored, and survives `xcodegen generate`):

```bash
cp SaveVision/Secrets.example.xcconfig SaveVision/Secrets.xcconfig
```

Fill in `Secrets.xcconfig`:
- `DEVELOPMENT_TEAM` — your Apple Team ID (drives code signing **and** the MWDAT
  `TeamID` in Info.plist). Do **not** set this in `project.yml` or it overrides
  the xcconfig.
- `MWDAT_APP_ID` / `MWDAT_CLIENT_TOKEN` — from the Meta dev portal (see below).
  `Info.plist` reads them via `$(MWDAT_APP_ID)` / `$(MWDAT_CLIENT_TOKEN)`.

Then in Xcode:

1. Signing should already pick up the Team from `Secrets.xcconfig`. (No need to
   set it in the target UI — that's the point of keeping it in the xcconfig.)
2. Fill in `SaveVision/App/Config.swift` — `homeserverURL`, `operatorUserID`
   (or pin `operatorRoomID`).
3. Build to a **physical iPhone** (the DAT SDK + glasses need real hardware; the
   simulator can only exercise the mock device + the iPhone-camera fallback).

> **Dependencies fetched by SwiftPM** (see `project.yml`):
> `matrix-rust-components-swift` 26.06.03 · `stasel/WebRTC` 148 ·
> `meta-wearables-dat-ios` 0.7.0 (includes `MWDATDisplay`).

### Known caveat — the Matrix layer

`Matrix/MatrixClientManager.swift` and `Matrix/MatrixRoomManager.swift` are
written against **`matrix-rust-components-swift` 26.06.03**. The Rust FFI's exact
async signatures shift between releases. Spots that may need a one-line tweak
against your pinned version are marked `// VERIFY:` — after SwiftPM resolves the
package, ⌘-click the symbol in Xcode to confirm the signature. Everything else
(glasses, WebRTC, signaling contract, UI) is plain Swift/SDK API and is solid.

---

## Meta dev portal — what to do

The glasses are reached through the **Meta Wearables Device Access Toolkit
(DAT)**. You must register an app with Meta and request access; the SDK then
deep-links into the **Meta AI** app on the phone for the user to approve pairing.

1. **Join the program.** Go to
   <https://developers.meta.com/wearables> (Wearables Device Access Toolkit) and
   request developer access. The DAT SDK is in developer preview — you may need
   to apply and be approved before camera streaming is enabled for your app.

2. **Create the app.** In the **Meta for Developers** dashboard
   (<https://developers.facebook.com/apps>) → **Create App**. Pick the app type
   that exposes the **Wearables / Device Access** product (follow the DAT docs at
   <https://wearables.developer.meta.com/docs>). Give it a name (e.g.
   "SaveVision").

3. **Add the Wearables / Device Access product** to the app and enable the
   **camera**, **display** (Ray-Ban Display / DAM app model), and microphone (if
   available) capabilities/permissions your use case needs.

4. **Register the iOS platform / app link.**
   - **Bundle ID:** `io.example.savevision`
   - **App link / redirect URL scheme:** `savevision://`
     This MUST match `MWDAT.AppLinkURLScheme` and the `CFBundleURLSchemes` entry
     in `Info.plist`. It's how the Meta AI app returns to SaveVision after the
     user approves access.
   - **Apple Team ID:** your Apple developer Team ID (also goes in
     `DEVELOPMENT_TEAM`).

5. **Grab the credentials** Meta issues for the app and put them in
   `SaveVision/Secrets.xcconfig` (gitignored — copied from
   `Secrets.example.xcconfig`):
   - **App ID** → `MWDAT_APP_ID`
   - **Client Token** → `MWDAT_CLIENT_TOKEN`
   `Info.plist` picks these up automatically. Do not paste them into
   `Info.plist` directly (that would commit the token).

6. **Add test users / testers.** While in development, add the Meta accounts that
   will pair glasses as **testers/roles** on the app, or the pairing approval in
   Meta AI will be rejected. The phone must have the **Meta AI** app installed,
   signed into a tester account, with the Ray-Ban glasses already paired to that
   account.

7. **(Later) App Review.** To ship beyond testers, submit the Wearables/Device
   Access permissions for Meta's review with your use-case description and a demo.

> **Reference values** that live in `stoz3n-vision-agent` (its own Meta app:
> `MetaAppID 887576564350409`) are examples only — create your **own** app so the
> `io.example.savevision` bundle id and `savevision://` scheme are registered.

---

## What works vs. what's stubbed

| Piece | Status |
|---|---|
| Glasses capture (DAT SDK) + iPhone fallback | Real code (adapted from a working app) |
| Native WebRTC publish (video + audio), offerer role | Real code |
| Matrix login / session restore / sync | Real code — `// VERIFY` the FFI signatures for your SDK version |
| Operator DM room + text chat | Real code — same caveat |
| SDP/ICE signaling over Matrix (`SV1|` messages) | Real code |
| Operator side answering the call | Lives in **`../operator-web`** — must retarget its WebRTC signaling to the same Matrix `SV1|` contract |
| Glasses-mic audio via DAT into WebRTC | **Not** done — voice uses the iOS audio session (glasses as BT route). Phase 2. |
| Operator→wearer HUD overlay | Text/image/location Matrix chat renders in the in-app virtual overlay and is sent to Ray-Ban Display via `MWDATDisplay` when a display-capable device/session is available; `SVHUD\|{...}` fallback supported. |

### Virtual overlay debug

Inbound operator chat is mirrored to:

- the **Chat** screen debug strip,
- the **Call** screen overlay on top of the POV preview,
- **Glasses → Virtual display overlay** for history and clearing.

To send a raw HUD payload through Matrix as a normal text message:

```text
SVHUD|{"kind":"guidance","text":"Apply firm pressure now"}
SVHUD|{"kind":"map","label":"Move to the collection point","bearing":90}
```

## The operator side

The matching answerer is [`../operator-web`](../operator-web). It already does
WebRTC; to talk to this app it needs to (a) sign in to the same homeserver with
`matrix-js-sdk`, (b) open the same room, and (c) send/receive the SDP/ICE as
`SV1|`-prefixed messages (or the agreed `org.savevision.call.*` events). See
[`../MATRIX.md`](../MATRIX.md).
