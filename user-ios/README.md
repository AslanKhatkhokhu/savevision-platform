# SaveVision — user-ios

SwiftUI app for the glasses wearer. Captures POV and publishes it over WebRTC to
the operator; receives guidance over a data channel and shows it on the display.

## What's here (compiles today)

```
SaveVisionUser/
  SaveVisionUserApp.swift          app entry
  ContentView.swift                start/stop UI, room code, guidance display
  Streaming/
    SignalingClient.swift          WebSocket signaling (URLSession — no deps)
    VideoPublisher.swift           WebRTC seam: protocol + StubVideoPublisher
    StreamViewModel.swift          orchestration + SwiftUI state
```

The app runs against `StubVideoPublisher`, so the **full signaling flow and UI**
work now: tap Start, get a room code, the operator joins, guidance comes back.
Only the actual media stream is stubbed.

## To make it a real Xcode app

1. **Create an Xcode app target** (iOS App, SwiftUI) and add these files, or run
   `xcodegen` with your own project spec. (No `.xcodeproj` is committed so the
   repo stays diff-friendly.)
2. **Set the server URL** in `StreamViewModel.swift` (`serverURL`). On a device,
   use your Mac's LAN IP, e.g. `ws://192.168.1.20:8080`.

## To add live video (the WebRTC work)

1. Add the **WebRTC framework** (SwiftPM: `stasel/WebRTC`, or CocoaPods
   `GoogleWebRTC`).
2. Implement `WebRTCVideoPublisher: VideoPublisher` in `Streaming/`. Reference:
   VisionClaw `samples/CameraAccess/CameraAccess/WebRTC/WebRTCClient.swift`.
3. Swap the stub in `StreamViewModel`: `private var publisher: VideoPublisher = WebRTCVideoPublisher()`.

## To use the actual glasses camera

Add the [Meta Wearables DAT SDK](https://github.com/facebook/meta-wearables-dat-ios)
and feed its camera frames into the publisher's video source. Fall back to the
iPhone camera (`AVCaptureSession`) when no glasses are connected — handy for
testing without hardware.

See [../PROTOCOL.md](../PROTOCOL.md) for the wire contract.
