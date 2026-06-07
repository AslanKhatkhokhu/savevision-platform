import SwiftUI
import WebRTC

/// SwiftUI wrapper for `RTCMTLVideoView` (Metal WebRTC renderer). SaveVision is
/// one-way (wearer publishes), so this is mainly useful for debugging a remote
/// track if the operator ever returns video.
struct RTCVideoView: UIViewRepresentable {
    let videoTrack: RTCVideoTrack?

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        context.coordinator.currentTrack?.remove(uiView)
        if let track = videoTrack {
            track.add(uiView)
            context.coordinator.currentTrack = track
        } else {
            context.coordinator.currentTrack = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.currentTrack?.remove(uiView)
        coordinator.currentTrack = nil
    }

    final class Coordinator {
        var currentTrack: RTCVideoTrack?
    }
}
