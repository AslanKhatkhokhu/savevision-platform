// SignalingClient.swift
// WebSocket signaling against the SaveVision operator-web server.
// Dependency-light: uses URLSessionWebSocketTask (no external pods), so this
// file compiles as-is. It speaks the exact protocol in ../../PROTOCOL.md.

import Foundation

/// Messages received from the signaling server.
enum SignalingEvent {
    case roomCreated(room: String)
    case roomRejoined(room: String)
    case peerJoined
    case peerLeft
    case answer(sdp: String)
    case candidate([String: Any])
    case error(String)
}

protocol SignalingClientDelegate: AnyObject {
    func signaling(_ client: SignalingClient, didReceive event: SignalingEvent)
}

final class SignalingClient {
    weak var delegate: SignalingClientDelegate?

    private let url: URL
    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default)

    /// - Parameter url: e.g. wss://your-server.example.com
    init(url: URL) { self.url = url }

    func connect() {
        task = session.webSocketTask(with: url)
        task?.resume()
        receiveLoop()
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    // MARK: - Outgoing (see PROTOCOL.md)

    func createRoom() { send(["type": "create"]) }
    func rejoin(room: String) { send(["type": "rejoin", "room": room]) }
    func sendOffer(sdp: String) { send(["type": "offer", "sdp": sdp]) }
    func sendCandidate(_ candidate: [String: Any]) {
        send(["type": "candidate", "candidate": candidate])
    }

    private func send(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { error in
            if let error { print("[Signaling] send error: \(error)") }
        }
    }

    // MARK: - Incoming

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.delegate?.signaling(self, didReceive: .error(error.localizedDescription))
            case .success(let message):
                if case let .string(text) = message { self.handle(text) }
                self.receiveLoop()
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        let event: SignalingEvent?
        switch type {
        case "room_created":  event = .roomCreated(room: obj["room"] as? String ?? "")
        case "room_rejoined": event = .roomRejoined(room: obj["room"] as? String ?? "")
        case "peer_joined":   event = .peerJoined
        case "peer_left":     event = .peerLeft
        case "answer":        event = .answer(sdp: obj["sdp"] as? String ?? "")
        case "candidate":     event = .candidate(obj["candidate"] as? [String: Any] ?? [:])
        case "error":         event = .error(obj["message"] as? String ?? "Unknown error")
        default:              event = nil
        }
        if let event { delegate?.signaling(self, didReceive: event) }
    }
}
