import Combine
import Foundation
import SwiftUI

/// Owns the HUD/virtual-overlay state shown to the wearer. Incoming operator
/// chat and SaveVision HUD payloads are normalized here, then rendered both in
/// the app and through the display bridge when a real Ray-Ban Display API is
/// available.
@MainActor
final class DisplayOverlayManager: ObservableObject {
    @Published private(set) var items: [DisplayOverlayItem] = []
    @Published private(set) var latest: DisplayOverlayItem?
    /// Latest item of each kind, so the call screen can show text, image, and
    /// location/map as separate simultaneous overlays.
    @Published private(set) var latestText: DisplayOverlayItem?
    @Published private(set) var latestImage: DisplayOverlayItem?
    @Published private(set) var latestMap: DisplayOverlayItem?
    @Published private(set) var displayStatus: String

    private let renderer: DisplayOverlayRendering
    private let maxHistory = 30

    /// Auto-dismiss timers per slot (so each overlay appears then disappears).
    private var dismissTasks: [String: Task<Void, Never>] = [:]
    /// Track which item ids (and whether they had an image) we've already shown,
    /// so re-delivered timeline snapshots don't resurrect a dismissed overlay.
    private var presented: [String: Bool] = [:]

    init(renderer: DisplayOverlayRendering) {
        self.renderer = renderer
        self.displayStatus = renderer.statusText
    }

    /// True when a real Ray-Ban Display is driving the overlay. When false, the
    /// phone screen is the primary overlay surface (req: fall back to phone).
    var isGlassesDisplayActive: Bool { renderer.isDisplayAvailable }

    convenience init() {
        self.init(renderer: VirtualOnlyDisplayRenderer())
    }

    func ingest(chatMessage message: ChatMessage) {
        guard message.isRenderableOnHUD else { return }
        present(DisplayOverlayItem(chatMessage: message))
    }

    func ingest(payload: SaveVisionHUDPayload, id: String = UUID().uuidString) {
        let timestamp = payload.ts.map { Date(timeIntervalSince1970: $0 / 1000.0) } ?? Date()
        let kind = payload.kind.lowercased()

        if kind == "clear" {
            clear()
            return
        }

        let item: DisplayOverlayItem
        switch kind {
        case "image":
            item = DisplayOverlayItem(
                id: id,
                kind: .image,
                title: "Reference image",
                body: payload.caption ?? payload.url ?? "Image from operator",
                imageData: payload.decodedImageData,
                remoteURL: payload.url,
                coordinate: nil,
                bearing: nil,
                timestamp: timestamp,
                sourceLabel: "operator",
                isUrgent: false
            )
        case "map", "location":
            let coordinate: GeoCoordinate?
            if let lat = payload.lat, let lng = payload.lng { coordinate = GeoCoordinate(latitude: lat, longitude: lng) }
            else { coordinate = nil }
            item = DisplayOverlayItem(
                id: id,
                kind: kind == "map" ? .map : .location,
                title: kind == "map" ? "Direction" : "Location",
                body: payload.label ?? coordinate?.shortText ?? "Location from operator",
                imageData: nil,
                remoteURL: nil,
                coordinate: coordinate,
                bearing: payload.bearing,
                timestamp: timestamp,
                sourceLabel: "operator",
                isUrgent: false
            )
        default:
            let text = payload.text ?? payload.label ?? payload.caption ?? "Operator guidance"
            item = DisplayOverlayItem(
                id: id,
                kind: .message,
                title: "Operator guidance",
                body: text,
                imageData: nil,
                remoteURL: nil,
                coordinate: nil,
                bearing: nil,
                timestamp: timestamp,
                sourceLabel: "operator",
                isUrgent: Self.isUrgent(text)
            )
        }
        present(item)
    }

    func clear() {
        dismissTasks.values.forEach { $0.cancel() }
        dismissTasks.removeAll()
        presented.removeAll()
        items.removeAll()
        latest = nil
        latestText = nil
        latestImage = nil
        latestMap = nil
        renderer.clear()
        displayStatus = renderer.statusText
    }

    private func present(_ item: DisplayOverlayItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
            if items.count > maxHistory { items.removeFirst(items.count - maxHistory) }
        }

        // Re-delivered timeline snapshots re-emit every message. Only (re)present an
        // item the first time we see it, or when its image finishes downloading —
        // otherwise a dismissed overlay would keep coming back.
        let hadImage = presented[item.id]
        let hasImage = item.imageData != nil
        let isNew = hadImage == nil
        let imageArrived = (hadImage == false && hasImage)
        presented[item.id] = hasImage
        guard isNew || imageArrived else { return }

        latest = item
        assignSlot(item)
        renderer.render(item)
        displayStatus = renderer.statusText
        scheduleDismiss(item)
    }

    /// Route the item to its per-kind slot (text / image / location-map).
    private func assignSlot(_ item: DisplayOverlayItem) {
        switch item.kind {
        case .message: latestText = item
        case .image: latestImage = item
        case .location, .map: latestMap = item
        case .clear: break
        }
    }

    private func slotKey(for kind: DisplayOverlayItem.Kind) -> String {
        switch kind {
        case .message: return "text"
        case .image: return "image"
        case .location, .map: return "map"
        case .clear: return "clear"
        }
    }

    private func displayDuration(for kind: DisplayOverlayItem.Kind) -> Double {
        switch kind {
        case .image: return 45
        case .location, .map: return 90   // maps linger for navigation
        case .message: return 30
        case .clear: return 0
        }
    }

    /// After a per-kind interval, animate the overlay out (clear its slot).
    private func scheduleDismiss(_ item: DisplayOverlayItem) {
        let key = slotKey(for: item.kind)
        dismissTasks[key]?.cancel()
        let seconds = displayDuration(for: item.kind)
        guard seconds > 0 else { return }
        dismissTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                switch item.kind {
                case .message: if self.latestText?.id == item.id { self.latestText = nil }
                case .image: if self.latestImage?.id == item.id { self.latestImage = nil }
                case .location, .map: if self.latestMap?.id == item.id { self.latestMap = nil }
                case .clear: break
                }
                if self.latest?.id == item.id { self.latest = nil }
            }
        }
    }

    nonisolated fileprivate static func isUrgent(_ text: String) -> Bool {
        text.range(of: #"\b(stop|unsafe|danger|take cover|do not)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

private extension DisplayOverlayItem {
    init(chatMessage message: ChatMessage) {
        let source = message.senderID.components(separatedBy: ":").first?.replacingOccurrences(of: "@", with: "")
        switch message.attachment {
        case .image(let caption, let mediaURL, let thumbnailData):
            self.init(
                id: message.id,
                kind: .image,
                title: "Image from operator",
                body: caption ?? message.body,
                imageData: thumbnailData,
                remoteURL: mediaURL,
                coordinate: nil,
                bearing: nil,
                timestamp: message.timestamp,
                sourceLabel: source ?? "operator",
                isUrgent: false
            )
        case .location(let body, let description, let geoURI, let coordinate):
            self.init(
                id: message.id,
                kind: .location,
                title: "Location from operator",
                body: description ?? coordinate?.shortText ?? body,
                imageData: nil,
                remoteURL: geoURI,
                coordinate: coordinate,
                bearing: nil,
                timestamp: message.timestamp,
                sourceLabel: source ?? "operator",
                isUrgent: false
            )
        case nil:
            self.init(
                id: message.id,
                kind: .message,
                title: "Message from operator",
                body: message.body,
                imageData: nil,
                remoteURL: nil,
                coordinate: nil,
                bearing: nil,
                timestamp: message.timestamp,
                sourceLabel: source ?? "operator",
                isUrgent: DisplayOverlayManager.isUrgent(message.body)
            )
        }
    }
}

@MainActor
protocol DisplayOverlayRendering: AnyObject {
    var statusText: String { get }
    /// Whether a real Ray-Ban Display HUD is connected and enabled. When false the
    /// app uses the phone screen as the primary overlay surface.
    var isDisplayAvailable: Bool { get }
    func render(_ item: DisplayOverlayItem)
    func clear()
}

/// Fallback renderer for tests or environments without a display-capable pair
/// of glasses. The production app injects `StreamSessionManager`, which uses
/// MWDATDisplay 0.7+ to send content to Ray-Ban Display.
final class VirtualOnlyDisplayRenderer: DisplayOverlayRendering {
    private(set) var statusText = "Virtual overlay active — no Ray-Ban Display renderer attached."

    /// No glasses display in this renderer — the phone screen is the overlay.
    let isDisplayAvailable = false

    func render(_ item: DisplayOverlayItem) {
        NSLog("[HUD] virtual render %@: %@", item.kind.rawValue, item.body)
    }

    func clear() {
        NSLog("[HUD] virtual clear")
    }
}
