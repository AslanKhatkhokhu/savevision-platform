import Foundation
import MatrixRustSDK

/// Manages the single 1:1 room with the operator: resolves/creates it, observes
/// the timeline (splitting ordinary chat from `SV1|` signaling envelopes), and
/// sends both text and signaling.
///
/// VERSION NOTE (matrix-rust-components-swift 26.06.03): the timeline FFI is the
/// most version-variable surface in this app. Lines marked `VERIFY:` should be
/// confirmed against the generated interface after SwiftPM resolves the package.
@MainActor
final class MatrixRoomManager: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isReady = false
    @Published var errorMessage: String?

    /// Forwarded to `MatrixSignaling`: fires for every inbound `SV1|` envelope.
    var onSignaling: ((SignalingMessage) -> Void)?

    /// Forwarded to the display overlay manager for ordinary inbound chat.
    var onChatMessage: ((ChatMessage) -> Void)?

    /// Forwarded to the display overlay manager for `SVHUD|{...}` fallback HUD
    /// payloads sent as ordinary Matrix messages.
    var onHUDPayload: ((SaveVisionHUDPayload) -> Void)?

    private let client: Client
    private var room: Room?
    private var timeline: Timeline?
    private var timelineHandle: TaskHandle?
    private var imageSourcesByEventID: [String: MediaSource] = [:]
    private var imageDataByEventID: [String: Data] = [:]
    private var imageDownloadsInFlight = Set<String>()

    init(client: Client) {
        self.client = client
    }

    var roomID: String? { room?.id() }

    // MARK: - Open the operator room

    func openOperatorRoom() async {
        do {
            let room = try await resolveRoom()
            self.room = room
            // VERIFY: room.timeline() async throws -> Timeline
            let timeline = try await room.timeline()
            self.timeline = timeline

            let listener = TimelineListenerProxy { [weak self] items in
                Task { @MainActor [weak self] in self?.ingest(items) }
            }
            // VERIFY: timeline.addListener(listener:) async -> TaskHandle
            self.timelineHandle = await timeline.addListener(listener: listener)
            isReady = true
        } catch {
            errorMessage = "Couldn't open the operator room: \(error.localizedDescription)"
        }
    }

    private func resolveRoom() async throws -> Room {
        let config = AppConfig.shared

        // Resolve the connection target. A runtime override
        // (`OperatorOverride.userID`, set from Settings) lets you connect to ANY
        // Matrix user instead of the configured operator — the pinned operator
        // room is ignored so a fresh 1:1 DM with that user is resolved/created.
        let targetUserID: String
        let pinnedRoomID: String
        let override = OperatorOverride.userID
        if let override, config.operatorRoomID.isEmpty {
            // Only honor a runtime override when NO operator room is pinned: resolve
            // a fresh 1:1 DM with that user (dev convenience for arbitrary targets).
            targetUserID = override
            pinnedRoomID = ""
            NSLog("[Room] Override → DM with %@ (no pinned room configured)", override)
        } else {
            // A fixed operator room IS configured — always use it so the wearer and
            // the operator console end up in the SAME room. A stale connection-target
            // override must not divert the call into a private DM the operator never
            // watches (that silently breaks SV1| calls).
            targetUserID = config.operatorUserID
            pinnedRoomID = config.operatorRoomID
            if let override {
                NSLog("[Room] Ignoring stale override %@ — using configured operator room", override)
            }
            NSLog("[Room] Using configured operator %@, room '%@'", targetUserID, pinnedRoomID)
        }

        // Can't open a 1:1 with yourself — createRoom would 403 ("already in the
        // room"). This happens when the signed-in account equals the target.
        if let me = try? client.userId(), me == targetUserID {
            throw SaveVisionError.cannotCallSelf(me)
        }

        // Sliding sync (`service.start()`) returns immediately and populates the
        // room list asynchronously, so right after launch `getRoom`/`getDmRoom`
        // return nil for rooms that DO exist. Poll briefly before falling through
        // to creating a new room — otherwise every launch spawns an empty DM the
        // operator was never in, and the call goes unanswered.

        // 1) Explicit room id wins — wait for sync to surface it.
        if !pinnedRoomID.isEmpty {
            if let room = try await waitForRoom(timeout: 15) { try client.getRoom(roomId: pinnedRoomID) } {
                NSLog("[Room] Using pinned room %@", room.id())
                return room
            }
            NSLog("[Room] Pinned room %@ not synced after wait; falling back to DM", pinnedRoomID)
        }

        // 2) Reuse an existing DM with the target — also sync-dependent.
        if let dm = try await waitForRoom(timeout: 10) { try client.getDmRoom(userId: targetUserID) } {
            NSLog("[Room] Using DM %@ with %@", dm.id(), targetUserID)
            return dm
        }

        // 3) Otherwise create an encrypted DM with the target.
        NSLog("[Room] Creating new DM with %@", targetUserID)
        let params = CreateRoomParameters(
            name: nil,
            topic: "SaveVision session",
            isEncrypted: true,
            isDirect: true,
            visibility: .private,
            preset: .trustedPrivateChat,
            invite: [targetUserID],
            avatar: nil,
            powerLevelContentOverride: nil,
            joinRuleOverride: nil,
            historyVisibilityOverride: nil,
            canonicalAlias: nil,
            isSpace: false
        )
        do {
            let roomID = try await client.createRoom(request: params)
            // Allow the new room to propagate through sync, then fetch it.
            if let room = try await waitForRoom(timeout: 15) { try client.getRoom(roomId: roomID) } {
                return room
            }
        } catch {
            // A DM with this user already exists, but sliding sync hadn't surfaced
            // it via getDmRoom yet — so createRoom 403s with M_FORBIDDEN
            // "… is already in the room." The room exists server-side; the create
            // attempt nudges sync, so poll a while longer for the existing DM
            // before giving up.
            NSLog("[Room] createRoom failed (%@); recovering existing DM with %@",
                  error.localizedDescription, targetUserID)
            if let dm = try await waitForRoom(timeout: 20) { try client.getDmRoom(userId: targetUserID) } {
                NSLog("[Room] Recovered existing DM after create conflict")
                return dm
            }
            throw error
        }
        throw SaveVisionError.roomUnavailable
    }

    /// Polls `lookup` (a sync-dependent room fetch) until it returns a room or
    /// `timeout` seconds elapse. Returns nil on timeout.
    private func waitForRoom(timeout seconds: Double, _ lookup: () throws -> Room?) async rethrows -> Room? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let room = try lookup() { return room }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return try lookup()
    }

    // MARK: - Sending

    func sendText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let timeline else { return }
        Task {
            do {
                // VERIFY: messageEventContentFromMarkdown(md:) + timeline.send(msg:)
                let content = messageEventContentFromMarkdown(md: trimmed)
                _ = try await timeline.send(msg: content)
            } catch {
                await MainActor.run { self.errorMessage = "Send failed: \(error.localizedDescription)" }
            }
        }
    }

    /// Send a signaling envelope as a plain message (carries the `SV1|` marker).
    func sendSignaling(_ message: SignalingMessage) {
        guard let body = SignalingEnvelope.encode(message), let timeline else { return }
        Task {
            do {
                let content = messageEventContentFromMarkdown(md: body)
                _ = try await timeline.send(msg: content)
            } catch {
                NSLog("[Matrix] Signaling send failed: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Receiving

    /// Event ids of signaling/HUD envelopes already dispatched, so re-derived
    /// timeline snapshots don't re-fire offer/answer/candidate or HUD payloads.
    private var processedSignalingIDs = Set<String>()
    private var processedHUDPayloadIDs = Set<String>()

    /// Rebuilds the visible chat from the full set of current timeline items and
    /// routes any *new* signaling/HUD envelopes to their handlers.
    private func ingest(_ items: [TimelineItem]) {
        var chat: [ChatMessage] = []
        for item in items {
            guard let parsed = parse(item) else { continue }
            if let signaling = SignalingEnvelope.decode(parsed.body) {
                guard !processedSignalingIDs.contains(parsed.id) else { continue }
                processedSignalingIDs.insert(parsed.id)
                onSignaling?(signaling)
            } else if parsed.body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(SaveVisionHUDEnvelope.prefix) {
                // Always hide HUD envelopes from chat — render them on the overlay
                // when decodable. (Previously a malformed payload leaked raw SVHUD|…
                // text into the chat transcript.)
                guard !processedHUDPayloadIDs.contains(parsed.id) else { continue }
                processedHUDPayloadIDs.insert(parsed.id)
                if let hudPayload = SaveVisionHUDEnvelope.decode(parsed.body) {
                    onHUDPayload?(hudPayload)
                } else {
                    NSLog("[Matrix] Dropping undecodable SVHUD payload: %@", parsed.body)
                }
            } else {
                chat.append(parsed)
            }
        }
        messages = chat
        scheduleThumbnailDownloads(for: chat)
        chat.forEach { onChatMessage?($0) }
    }

    /// Extract a `ChatMessage` from a timeline item, or nil if it isn't a message
    /// event SaveVision can show in chat / mirror to the HUD overlay.
    private func parse(_ item: TimelineItem) -> ChatMessage? {
        guard let event = item.asEvent() else { return nil }
        guard case let .msgLike(msgLike) = event.content else { return nil }
        guard case let .message(message) = msgLike.kind else { return nil }

        let eventID: String
        if case let .eventId(id) = event.eventOrTransactionId {
            eventID = id
        } else if case let .transactionId(id) = event.eventOrTransactionId {
            eventID = id
        } else {
            eventID = UUID().uuidString
        }

        let timestamp = Date(timeIntervalSince1970: Double(event.timestamp) / 1000.0)
        let parsed = parseMessageContent(message, eventID: eventID)

        return ChatMessage(
            id: eventID,
            body: parsed.body,
            senderID: event.sender,
            isMine: event.isOwn,
            timestamp: timestamp,
            attachment: parsed.attachment
        )
    }

    private func parseMessageContent(_ message: MessageContent, eventID: String) -> (body: String, attachment: ChatAttachment?) {
        switch message.msgType {
        case .text(let text):
            return (text.body, nil)
        case .notice(let notice):
            return (notice.body, nil)
        case .emote(let emote):
            return ("• " + emote.body, nil)
        case .image(let image):
            imageSourcesByEventID[eventID] = image.source
            let caption = image.caption ?? image.filename
            return (caption, .image(caption: caption, mediaURL: image.source.url(), thumbnailData: imageDataByEventID[eventID]))
        case .gallery(let gallery):
            if let first = firstImage(in: gallery) {
                imageSourcesByEventID[eventID] = first.source
                let caption = first.caption ?? first.filename
                return (caption, .image(caption: caption, mediaURL: first.source.url(), thumbnailData: imageDataByEventID[eventID]))
            }
            return (gallery.body, nil)
        case .location(let location):
            let coordinate = GeoCoordinate(geoURI: location.geoUri)
            let body = location.description ?? coordinate?.shortText ?? location.body
            return (body, .location(body: location.body, description: location.description, geoURI: location.geoUri, coordinate: coordinate))
        case .other(msgtype: _, body: let body):
            return (body, nil)
        default:
            return (message.body, nil)
        }
    }

    private func firstImage(in gallery: GalleryMessageContent) -> ImageMessageContent? {
        for item in gallery.itemtypes {
            if case .image(content: let content) = item { return content }
        }
        return nil
    }

    private func scheduleThumbnailDownloads(for chat: [ChatMessage]) {
        for message in chat {
            guard case .image(_, _, nil)? = message.attachment,
                  let source = imageSourcesByEventID[message.id],
                  imageDataByEventID[message.id] == nil,
                  !imageDownloadsInFlight.contains(message.id) else { continue }

            imageDownloadsInFlight.insert(message.id)
            let client = self.client
            Task { [weak self, source, eventID = message.id] in
                // Prefer a downscaled thumbnail; if the homeserver can't produce one
                // (common with authenticated media), fall back to the full image so it
                // still renders instead of leaving the overlay imageless.
                let data: Data
                do {
                    data = try await client.getMediaThumbnail(mediaSource: source, width: 640, height: 640)
                } catch {
                    NSLog("[Matrix] Thumbnail fetch failed (%@); trying full media", error.localizedDescription)
                    do {
                        data = try await client.getMediaContent(mediaSource: source)
                    } catch {
                        await MainActor.run { [weak self] in self?.imageDownloadsInFlight.remove(eventID) }
                        NSLog("[Matrix] Image fetch failed: %@", error.localizedDescription)
                        return
                    }
                }
                await MainActor.run {
                    guard let self else { return }
                    self.imageDataByEventID[eventID] = data
                    self.imageDownloadsInFlight.remove(eventID)
                    self.applyThumbnailData(data, to: eventID)
                }
            }
        }
    }

    private func applyThumbnailData(_ data: Data, to eventID: String) {
        guard let index = messages.firstIndex(where: { $0.id == eventID }) else { return }
        let updated = messages[index].withThumbnailData(data)
        messages[index] = updated
        onChatMessage?(updated)
    }

    deinit {
        timelineHandle?.cancel()
    }
}

enum SaveVisionError: LocalizedError {
    case roomUnavailable
    case cannotCallSelf(String)

    var errorDescription: String? {
        switch self {
        case .roomUnavailable:
            return "The operator room didn't sync in time. Check your connection and try again."
        case .cannotCallSelf(let me):
            return "Signed in as \(me), which is also the selected operator. Pick a different operator in Settings to place a call."
        }
    }
}

/// Bridges the FFI `TimelineListener` callback to a Swift closure. The SDK hands
/// us diffs; for SaveVision's low-traffic 1:1 room we re-derive the full item
/// list from each batch and let `ingest` rebuild state idempotently.
final class TimelineListenerProxy: TimelineListener {
    private let onItems: ([TimelineItem]) -> Void
    private var current: [TimelineItem] = []

    init(onItems: @escaping ([TimelineItem]) -> Void) {
        self.onItems = onItems
    }

    // `TimelineDiff` is an enum in the FFI — apply each case to `current`.
    func onUpdate(diff: [TimelineDiff]) {
        for d in diff {
            switch d {
            case .reset(let values):
                current = values
            case .append(let values):
                current.append(contentsOf: values)
            case .pushBack(let value):
                current.append(value)
            case .pushFront(let value):
                current.insert(value, at: 0)
            case .insert(let index, let value):
                let i = min(Int(index), current.count)
                current.insert(value, at: i)
            case .set(let index, let value):
                if Int(index) < current.count { current[Int(index)] = value }
            case .remove(let index):
                if Int(index) < current.count { current.remove(at: Int(index)) }
            case .truncate(let length):
                if Int(length) < current.count { current.removeLast(current.count - Int(length)) }
            case .popBack:
                if !current.isEmpty { current.removeLast() }
            case .popFront:
                if !current.isEmpty { current.removeFirst() }
            case .clear:
                current.removeAll()
            }
        }
        onItems(current)
    }
}
