# Showing image/video on the Display screen + streaming the POV — research

How to put an image or video on the Ray-Ban **Display** built-in screen, and how
the POV streaming works in this project. Sources: Meta Wearables docs + the
official display/performance guidelines (mirrored in `.claude/references/`).

## The screen, in one paragraph
The Display is a **600×600dp additive waveguide** WebView at **60fps**, mobile-
grade CPU, **<128 MB** memory budget. It renders via **DOM (HTML/CSS)**,
**Canvas 2D**, or **WebGL**. **Black `#000000` = fully transparent** (real world
shows through) — use it for the page background; use dark grays (`#0a0a0f`–
`#1C1E21`) for cards so they're visible. Safe content area **584×584** (8dp
margins). Input is **captouch + Neural Band** (no touch/cursor).

## 1) Show an IMAGE on the screen
- It's a standard WebView, so a normal **`<img>`** works (DOM rendering is supported).
- Keep it light: inline small assets (<2 KB) as data URIs, **<10 network requests** on load, **<500 KB** JS. Host the app over **HTTPS**.
- High contrast (bright on transparent black); respect the 584×584 safe area.
- **In this project:** the operator sends an `org.savevision.image` event (a URL or data URL); the glasses web app renders it in an `<img>` inset — exactly what `glasses-sim.js` does today. AI-proposed/approved images arrive the same way.

## 2) Show / play VIDEO on the screen
- Meta lists **video playback and media streaming** as supported display capabilities, so an HTML **`<video>`** element renders on the screen (DOM), or draw frames via Canvas/WebGL.
- Constraints to respect: **mute to autoplay** (browser autoplay policy blocks sound), keep **resolution/bitrate modest** (small additive display + battery + <128 MB), avoid continuous heavy loops, target 60fps.
- **In this project:** a doctor can push a short instructional clip as a media event; the wearer's app plays it in `<video muted autoplay playsinline>`. (For a *live* operator video feed onto the glasses, use the call — see §3.)

## 3) Stream the POV (glasses camera → operator) — how it works here
Two different directions — don't confuse them:
- **Outgoing (wearer POV → operator):** the glasses **camera** is accessed via the **Meta Wearables Device Access Toolkit** (camera capability) on the companion app. In this project the captured POV is published over **WebRTC / MatrixRTC (Element Call)** into the case's Matrix room; the operator watches it. VisionClaw does the glasses-camera capture on iOS.
- **Incoming (operator → wearer screen):** the **Display web app** renders what the operator sends — text, image, video, drawings, map — received as `org.savevision.*` Matrix thread events. The screen shows *received guidance*, not the outgoing camera.

```
 glasses camera ──(Device Access Toolkit)──► iOS app (VisionClaw)
        │ POV track
        ▼  WebRTC / MatrixRTC (Element Call), E2E
   Matrix room  ◄──────────────────────────────►  operator (watches POV)
        ▲  org.savevision.* thread events (text/image/video/drawing/map)
        │
   Display web app renders them on the 600×600 screen
```

## Constraints / preview caveats
- **Developer preview**: the app must be **HTTPS-hosted**, added to the glasses via the **Meta AI app** (Devices → Display glasses → App connections → Web apps), or a QR deep link. Broad publishing is still limited.
- **No autoplay with sound**; **mute** video to autoplay.
- **Perf budget**: <500 KB JS, <10 requests, <128 MB, 60fps; design for intermittent Wi-Fi (Service Worker cache, audio-only/offline fallback).
- **Input**: D-pad/Neural Band only — build for arrows + select/cancel.

## Practical for SaveVision
- The wearer HUD we built (`glasses-sim.js`) is already the right shape — banner + `<img>` inset + map + drawings. To run it on real Display glasses: serve it over HTTPS, add the `mrbd-web-app-capable` meta tag (already in `glasses-webapp/`), keep to 600×600 + the perf budget, and add it via the Meta AI app.
- For the live POV, the iOS/VisionClaw side publishes the camera into the Matrix room's Element Call (see `MATRIX_CONNECTION.md`).

Sources: [Build for display glasses](https://developers.meta.com/blog/build-for-display-glasses/) · [Web Apps docs](https://wearables.developer.meta.com/docs/develop/webapps) · official display/performance guidelines (`.claude/references/`).
