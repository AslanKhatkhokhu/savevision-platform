import Foundation

/// A single chat line shown in the operator chat. Signaling envelopes are
/// filtered out before they ever become a `ChatMessage`.
struct ChatMessage: Identifiable, Equatable {
    let id: String          // event id (or a local uuid for unsent echoes)
    let body: String
    let senderID: String
    let isMine: Bool
    let timestamp: Date
    let attachment: ChatAttachment?

    init(id: String, body: String, senderID: String, isMine: Bool, timestamp: Date, attachment: ChatAttachment? = nil) {
        self.id = id
        self.body = body
        self.senderID = senderID
        self.isMine = isMine
        self.timestamp = timestamp
        self.attachment = attachment
    }
}

/// High-level connection state surfaced to the UI.
enum MatrixConnectionState: Equatable {
    case signedOut
    case connecting
    case syncing
    case ready
    case error(String)
}
