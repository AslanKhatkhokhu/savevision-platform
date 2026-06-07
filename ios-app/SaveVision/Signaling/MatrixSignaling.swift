import Foundation

/// Adapts `MatrixRoomManager` to the transport-agnostic `SignalingTransport`
/// protocol, so `CallController` depends only on the protocol — not on Matrix.
///
/// Swapping to native MatrixRTC custom events (Phase 2) means replacing only
/// this file plus the two send/receive methods in `MatrixRoomManager`.
@MainActor
final class MatrixSignaling: SignalingTransport {
    var onMessage: ((SignalingMessage) -> Void)?

    private let room: MatrixRoomManager

    init(room: MatrixRoomManager) {
        self.room = room
        room.onSignaling = { [weak self] message in
            self?.onMessage?(message)
        }
    }

    func send(_ message: SignalingMessage) {
        room.sendSignaling(message)
    }
}
