import Foundation

/// What the wearer should see on the Ray-Ban Display HUD and on the in-app
/// virtual overlay. This deliberately mirrors the payload shapes in PROTOCOL.md
/// while also accepting ordinary Matrix chat messages.
struct DisplayOverlayItem: Identifiable {
    enum Kind: String {
        case message
        case image
        case location
        case map
        case clear
    }

    let id: String
    let kind: Kind
    let title: String
    let body: String
    let imageData: Data?
    let remoteURL: String?
    let coordinate: GeoCoordinate?
    let bearing: Double?
    let timestamp: Date
    let sourceLabel: String
    let isUrgent: Bool
}

struct GeoCoordinate: Equatable, Hashable {
    let latitude: Double
    let longitude: Double

    var shortText: String {
        String(format: "%.5f, %.5f", latitude, longitude)
    }

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init?(geoURI: String) {
        // Matrix locations are usually `geo:lat,lng` with optional parameters,
        // e.g. `geo:49.2827,-123.1207;u=12`.
        guard geoURI.lowercased().hasPrefix("geo:") else { return nil }
        let value = String(geoURI.dropFirst(4))
        let coordinatePart = value.split(separator: ";", maxSplits: 1).first ?? Substring(value)
        let pieces = coordinatePart.split(separator: ",", maxSplits: 2).map(String.init)
        guard pieces.count >= 2,
              let lat = Double(pieces[0]),
              let lng = Double(pieces[1]) else { return nil }
        self.latitude = lat
        self.longitude = lng
    }
}

/// Attachment metadata for ordinary Matrix chat messages. The app treats inbound
/// chat as operator-approved HUD content, so text/image/location messages can be
/// mirrored to the virtual overlay and, when available, the real display bridge.
enum ChatAttachment: Equatable {
    case image(caption: String?, mediaURL: String?, thumbnailData: Data?)
    case location(body: String, description: String?, geoURI: String, coordinate: GeoCoordinate?)

    var displayText: String {
        switch self {
        case .image(let caption, let mediaURL, _):
            return caption ?? mediaURL ?? "Image"
        case .location(let body, let description, _, let coordinate):
            if let description, !description.isEmpty { return description }
            if let coordinate { return coordinate.shortText }
            return body
        }
    }
}

/// Plain-message fallback for HUD payloads. The high-level Matrix Rust timeline
/// reliably surfaces `m.room.message`; custom `org.savevision.*` event payloads
/// can be version-dependent. Operators can send `SVHUD|{...}` as a normal room
/// message and the wearer app will render it while hiding it from chat.
struct SaveVisionHUDPayload: Decodable {
    let kind: String
    let text: String?
    let caption: String?
    let dataUrl: String?
    let url: String?
    let label: String?
    let bearing: Double?
    let lat: Double?
    let lng: Double?
    let ts: Double?

    var decodedImageData: Data? {
        guard let dataUrl else { return nil }
        if dataUrl.hasPrefix("data:"), let comma = dataUrl.firstIndex(of: ",") {
            return Data(base64Encoded: String(dataUrl[dataUrl.index(after: comma)...]))
        }
        return Data(base64Encoded: dataUrl)
    }
}

enum SaveVisionHUDEnvelope {
    static let prefix = "SVHUD|"

    static func decode(_ body: String) -> SaveVisionHUDPayload? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { return nil }
        let json = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SaveVisionHUDPayload.self, from: data)
    }

    static func encode(_ payload: SaveVisionHUDPayload) -> String? {
        // Currently only decoding is needed by the wearer app.
        nil
    }
}

extension ChatMessage {
    var isRenderableOnHUD: Bool {
        guard !isMine else { return false }
        if case .image(_, _, nil)? = attachment { return true }
        return !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachment != nil
    }

    func withThumbnailData(_ data: Data) -> ChatMessage {
        guard case .image(let caption, let mediaURL, _)? = attachment else { return self }
        return ChatMessage(
            id: id,
            body: body,
            senderID: senderID,
            isMine: isMine,
            timestamp: timestamp,
            attachment: .image(caption: caption, mediaURL: mediaURL, thumbnailData: data)
        )
    }
}
