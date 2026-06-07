import SwiftUI

/// Minimal 1:1 chat with the operator. Signaling envelopes are already filtered
/// out by `MatrixRoomManager`, so only human messages show here.
struct ChatView: View {
    @ObservedObject var room: MatrixRoomManager
    @EnvironmentObject private var model: AppModel
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            overlayDebugStrip
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(room.messages) { message in
                            bubble(message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: room.messages.count) { _, _ in
                    if let last = room.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()
            composer
        }
        .navigationTitle("Operator")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.isMine { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 8) {
                attachmentView(message.attachment)
                if !message.body.isEmpty {
                    Text(message.body)
                }
            }
            .padding(10)
            .background(message.isMine ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: .infinity, alignment: message.isMine ? .trailing : .leading)
            if !message.isMine { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private func attachmentView(_ attachment: ChatAttachment?) -> some View {
        switch attachment {
        case .image(_, let mediaURL, let data):
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Label(mediaURL == nil ? "Image loading…" : "Image attachment", systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .location(_, _, let geoURI, let coordinate):
            VStack(alignment: .leading, spacing: 4) {
                Label("Location", systemImage: "mappin.and.ellipse")
                    .font(.caption.bold())
                Text(coordinate?.shortText ?? geoURI)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case nil:
            EmptyView()
        }
    }

    private var overlayDebugStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Virtual glasses overlay", systemImage: "eyeglasses")
                    .font(.caption.bold())
                Spacer()
                NavigationLink("Debug") {
                    DisplayOverlayDebugView(overlay: model.overlayManager)
                }
                .font(.caption)
            }
            DisplayOverlayView(overlay: model.overlayManager, compact: true)
                .frame(maxHeight: 190)
            Text(model.overlayManager.displayStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            Button {
                room.sendText(draft)
                draft = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(8)
    }
}
