// VideoPublisher.swift
// The WebRTC seam for the user app.
//
// WHY A PROTOCOL: the actual peer connection needs the WebRTC framework
// (`import WebRTC`, added via SwiftPM/CocoaPods — see ../../README.md) plus the
// glasses camera frames from the Meta Wearables DAT SDK. Those are large native
// dependencies that can't live in a plain scaffold. So we define the contract
// here and provide a no-op stub that lets the rest of the app compile and run
// (showing room codes, guidance UI) before WebRTC is wired in.
//
// IMPLEMENT `WebRTCVideoPublisher` against the reference implementation in
// VisionClaw: samples/CameraAccess/CameraAccess/WebRTC/WebRTCClient.swift.

import Foundation

protocol VideoPublisherDelegate: AnyObject {
    /// Local SDP offer ready to be sent through signaling.
    func publisher(_ p: VideoPublisher, didCreateOffer sdp: String)
    /// A local ICE candidate to relay to the operator.
    func publisher(_ p: VideoPublisher, didGather candidate: [String: Any])
    /// Operator guidance received over the data channel (JSON: {kind,text,ts}).
    func publisher(_ p: VideoPublisher, didReceiveGuidance text: String)
}

protocol VideoPublisher: AnyObject {
    var delegate: VideoPublisherDelegate? { get set }
    func configure(iceServers: [[String: Any]])
    /// Begin capture + create the data channel + create an offer.
    func start()
    /// Apply the operator's SDP answer.
    func acceptAnswer(sdp: String)
    /// Add a remote ICE candidate.
    func addRemoteCandidate(_ candidate: [String: Any])
    func stop()
}

/// Stub so the app builds and the signaling flow can be exercised end-to-end
/// before the real WebRTC stack is added. Replace with `WebRTCVideoPublisher`.
final class StubVideoPublisher: VideoPublisher {
    weak var delegate: VideoPublisherDelegate?

    func configure(iceServers: [[String: Any]]) {}

    func start() {
        // A real implementation would create an RTCPeerConnection, attach the
        // glasses/iPhone video track + a "guidance" data channel, then emit the
        // offer below. Here we emit a placeholder so the wiring is visible.
        let placeholder = "v=0\r\n# stub offer — integrate WebRTC, see README\r\n"
        delegate?.publisher(self, didCreateOffer: placeholder)
    }

    func acceptAnswer(sdp: String) {}
    func addRemoteCandidate(_ candidate: [String: Any]) {}
    func stop() {}
}
