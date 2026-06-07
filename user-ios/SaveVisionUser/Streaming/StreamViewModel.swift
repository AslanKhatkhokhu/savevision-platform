// StreamViewModel.swift
// Orchestrates signaling + the video publisher and drives the SwiftUI state.
// This is the glue both halves of the team build against — it depends only on
// the SignalingClient and VideoPublisher contracts, not their internals.

import Foundation
import Combine

@MainActor
final class StreamViewModel: ObservableObject {

    enum State {
        case idle
        case connecting
        case live(roomCode: String)
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var latestGuidance: String?

    // TODO: point this at your deployed operator-web server (wss://…).
    // For local testing on a device, use your Mac's LAN IP, e.g. ws://192.168.1.20:8080
    private let serverURL = URL(string: "ws://localhost:8080")!

    private var signaling: SignalingClient?
    private var publisher: VideoPublisher = StubVideoPublisher()
    private var roomCode: String?

    func start() {
        state = .connecting
        publisher.delegate = self

        let client = SignalingClient(url: serverURL)
        client.delegate = self
        client.connect()
        client.createRoom()
        signaling = client
    }

    func stop() {
        publisher.stop()
        signaling?.disconnect()
        signaling = nil
        roomCode = nil
        state = .idle
    }

    fileprivate func fetchIceAndStart() {
        // operator-web exposes /api/ice; for brevity the stub ignores it.
        publisher.configure(iceServers: [["urls": "stun:stun.l.google.com:19302"]])
        publisher.start()
    }
}

extension StreamViewModel: SignalingClientDelegate {
    nonisolated func signaling(_ client: SignalingClient, didReceive event: SignalingEvent) {
        Task { @MainActor in
            switch event {
            case .roomCreated(let room), .roomRejoined(let room):
                roomCode = room
                state = .live(roomCode: room)
            case .peerJoined:
                // Operator is in the room — begin the WebRTC offer.
                fetchIceAndStart()
            case .answer(let sdp):
                publisher.acceptAnswer(sdp: sdp)
            case .candidate(let c):
                publisher.addRemoteCandidate(c)
            case .peerLeft:
                latestGuidance = nil
            case .error(let message):
                state = .error(message)
            }
        }
    }
}

extension StreamViewModel: VideoPublisherDelegate {
    nonisolated func publisher(_ p: VideoPublisher, didCreateOffer sdp: String) {
        Task { @MainActor in signaling?.sendOffer(sdp: sdp) }
    }
    nonisolated func publisher(_ p: VideoPublisher, didGather candidate: [String: Any]) {
        Task { @MainActor in signaling?.sendCandidate(candidate) }
    }
    nonisolated func publisher(_ p: VideoPublisher, didReceiveGuidance text: String) {
        Task { @MainActor in latestGuidance = text /* TODO: also render on glasses display */ }
    }
}
