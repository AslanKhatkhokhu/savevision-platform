import SwiftUI

/// The in-app mirror of what we want on the glasses. It is intentionally sized
/// and styled like a HUD card so the wearer/operator can debug exactly what is
/// being presented.
struct DisplayOverlayView: View {
    @ObservedObject var overlay: DisplayOverlayManager
    /// Compact = the small, corner-hugging HUD card shown on glasses/phone during a
    /// call. Non-compact = the wider detailed card used in the Settings debug view.
    var compact = false

    /// Keep the compact card small so it doesn't blanket the live view.
    private var maxCardWidth: CGFloat? { compact ? 210 : nil }

    var body: some View {
        // Always show a card (the default idle card when empty) so the overlay is
        // present both with the glasses HUD and on the phone.
        Group {
            if let item = overlay.latest {
                OverlayItemCard(item: item, compact: compact)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                defaultCard
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: maxCardWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: overlay.latest?.id)
    }

    /// The default overlay shown before any operator content arrives.
    private var defaultCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "eyeglasses")
                .font(.footnote)
                .foregroundStyle(.cyan)
            Text(compact ? "Waiting for operator" : "Waiting for operator guidance")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.black.opacity(0.5), in: Capsule())
        .overlay(Capsule().stroke(Color.cyan.opacity(0.4), lineWidth: 1))
        .foregroundStyle(.white)
    }

}

/// A single overlay item rendered as a HUD card (operator text, image, or a
/// semi-transparent OpenStreetMap for locations). Reused for the generic latest
/// overlay and for the per-kind overlays composed during a call.
struct OverlayItemCard: View {
    let item: DisplayOverlayItem
    var compact = false
    /// Cap the embedded image/map height (used to keep the call image overlay small).
    var mediaMaxHeight: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 10) {
            HStack(spacing: 6) {
                Image(systemName: Self.icon(for: item.kind))
                    .font(compact ? .caption2 : .body)
                    .foregroundStyle(item.isUrgent ? .red : .cyan)
                Text(item.title)
                    .font(compact ? .caption2.bold() : .subheadline.bold())
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(item.timestamp, style: .time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let image = Self.image(from: item.imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: mediaMaxHeight ?? (compact ? 90 : 220))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if item.kind == .image {
                Label(item.remoteURL == nil ? "Image loading…" : "Image: \(item.remoteURL!)", systemImage: "photo")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            // Location / map items render as a semi-transparent OpenStreetMap view
            // so the wearer sees the place on a real map without fully blocking the
            // live point-of-view underneath.
            if (item.kind == .location || item.kind == .map), let coordinate = item.coordinate {
                OSMMapView(coordinate: coordinate, bearing: item.kind == .map ? item.bearing : nil)
                    .frame(height: mediaMaxHeight ?? (compact ? 90 : 220))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .opacity(0.4)
                    .overlay(alignment: .topTrailing) {
                        if item.kind == .map, let bearing = item.bearing {
                            Image(systemName: "location.north.fill")
                                .font(.system(size: compact ? 14 : 24))
                                .rotationEffect(.degrees(bearing))
                                .foregroundStyle(.green)
                                .padding(6)
                                .background(.black.opacity(0.5), in: Circle())
                                .padding(6)
                        }
                    }
            }

            if let coordinate = item.coordinate {
                Label(coordinate.shortText, systemImage: "mappin.and.ellipse")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.green)
            }

            if !item.body.isEmpty {
                Text(item.body)
                    .font(compact ? .caption.bold() : .title3.bold())
                    .foregroundStyle(item.isUrgent ? .red : .primary)
                    .lineLimit(compact ? 3 : 6)
            }
        }
        .padding(compact ? 9 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(item.isUrgent ? Color.red : Color.cyan.opacity(0.7), lineWidth: 1)
        )
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
    }

    static func icon(for kind: DisplayOverlayItem.Kind) -> String {
        switch kind {
        case .message: return "text.bubble.fill"
        case .image: return "photo.fill"
        case .location: return "location.fill"
        case .map: return "arrow.up.circle.fill"
        case .clear: return "xmark.circle"
        }
    }

    static func image(from data: Data?) -> UIImage? {
        guard let data else { return nil }
        return UIImage(data: data)
    }
}

struct DisplayOverlayDebugView: View {
    @ObservedObject var overlay: DisplayOverlayManager

    var body: some View {
        List {
            Section("Live preview") {
                // The real overlay card, exactly as the glasses/phone render it.
                // Updates live as operator chat/images/locations arrive in the room.
                DisplayOverlayView(overlay: overlay, compact: false)
                    .padding(.vertical, 4)
                    .listRowBackground(Color.black)
                Text("Post text, an image, or a location in the SaveVision room to see it appear here.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                Text(overlay.displayStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) { overlay.clear() } label: {
                    Label("Clear virtual overlay", systemImage: "xmark.circle")
                }
                .disabled(overlay.items.isEmpty)
            }

            Section("Virtual overlay history") {
                if overlay.items.isEmpty {
                    ContentUnavailableView("No overlay items yet", systemImage: "eyeglasses", description: Text("Inbound operator chat, images, locations, and SVHUD payloads will appear here."))
                } else {
                    ForEach(overlay.items.reversed()) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(item.title, systemImage: icon(for: item.kind))
                                Spacer()
                                Text(item.timestamp, style: .time)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if let image = image(from: item.imageData) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 160)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            Text(item.body)
                                .font(.callout)
                            if let coordinate = item.coordinate {
                                Text(coordinate.shortText)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if let remoteURL = item.remoteURL {
                                Text(remoteURL)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .navigationTitle("Virtual overlay")
    }

    private func icon(for kind: DisplayOverlayItem.Kind) -> String {
        switch kind {
        case .message: return "text.bubble.fill"
        case .image: return "photo.fill"
        case .location: return "location.fill"
        case .map: return "arrow.up.circle.fill"
        case .clear: return "xmark.circle"
        }
    }

    private func image(from data: Data?) -> UIImage? {
        guard let data else { return nil }
        return UIImage(data: data)
    }
}
