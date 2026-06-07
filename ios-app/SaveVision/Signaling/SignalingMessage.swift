import Foundation

/// Transport-agnostic WebRTC signaling messages. These ride over Matrix room
/// events (see `MatrixSignaling`) in production, but the type is independent of
/// the transport so the call logic never touches Matrix directly.
///
/// SaveVision is one-way media (wearer → operator). The iOS app is the offerer:
/// it emits `.offer` + `.candidate`, and consumes `.answer` + `.candidate`.
enum SignalingMessage {
    case offer(sdp: String)
    case answer(sdp: String)
    case candidate(sdp: String, sdpMid: String, sdpMLineIndex: Int32)
    case hangup
}

/// Anything that can carry `SignalingMessage`s between the two peers.
protocol SignalingTransport: AnyObject {
    /// Fired when a signaling message arrives from the remote peer.
    var onMessage: ((SignalingMessage) -> Void)? { get set }
    func send(_ message: SignalingMessage)
}

// MARK: - JSON envelope

/// SaveVision signaling is serialized as a compact JSON envelope. Over Matrix it
/// is carried in a message body prefixed with `SV1|` so it round-trips reliably
/// through both matrix-rust-sdk (iOS) and matrix-js-sdk (operator-web) while
/// staying trivially distinguishable from real chat text.
enum SignalingEnvelope {
    static let marker = "SV1|"

    static func encode(_ message: SignalingMessage) -> String? {
        var dict: [String: Any] = ["ts": Int(Date().timeIntervalSince1970 * 1000)]
        switch message {
        case .offer(let sdp):
            dict["kind"] = "offer"; dict["sdp"] = sdp
        case .answer(let sdp):
            dict["kind"] = "answer"; dict["sdp"] = sdp
        case .candidate(let sdp, let mid, let index):
            dict["kind"] = "candidate"
            dict["candidate"] = sdp
            dict["sdpMid"] = mid
            dict["sdpMLineIndex"] = index
        case .hangup:
            dict["kind"] = "hangup"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return marker + json
    }

    /// Returns nil if `body` is ordinary chat text (no marker / unparseable).
    static func decode(_ body: String) -> SignalingMessage? {
        guard body.hasPrefix(marker) else { return nil }
        let json = String(body.dropFirst(marker.count))
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = dict["kind"] as? String else { return nil }

        switch kind {
        case "offer":
            guard let sdp = dict["sdp"] as? String else { return nil }
            return .offer(sdp: sdp)
        case "answer":
            guard let sdp = dict["sdp"] as? String else { return nil }
            return .answer(sdp: sdp)
        case "candidate":
            guard let sdp = dict["candidate"] as? String,
                  let mid = dict["sdpMid"] as? String,
                  let index = dict["sdpMLineIndex"] as? Int else { return nil }
            return .candidate(sdp: sdp, sdpMid: mid, sdpMLineIndex: Int32(index))
        case "hangup":
            return .hangup
        default:
            return nil
        }
    }

    /// True if `body` is a signaling envelope (so chat UI can hide it).
    static func isSignaling(_ body: String) -> Bool { body.hasPrefix(marker) }
}
