import CoreGraphics
import CoreVideo
import Foundation
import LiveKit
import MatrixRustSDK
import UIKit

@MainActor
enum MatrixRTCState: Equatable {
    case idle
    case announcing
    case requestingToken
    case connectingLiveKit
    case publishing
    case connected
    case failed(String)
}

/// Minimal MatrixRTC + LiveKit publisher for SaveVision.
///
/// This mirrors the Element Call / Element X join path on our MatrixRTC infra:
/// 1. create a delayed empty `org.matrix.msc3401.call.member` leave event,
/// 2. send the current `org.matrix.msc3401.call.member` state event,
/// 3. request a Matrix OpenID token,
/// 4. exchange it at the configured LiveKit focus `/sfu/get`,
/// 5. connect to LiveKit and publish glasses/iPhone video + microphone audio.
@MainActor
final class MatrixRTCSessionManager: ObservableObject {
    @Published private(set) var state: MatrixRTCState = .idle
    @Published private(set) var statusText = "MatrixRTC idle"
    /// The operator's return video (a remote LiveKit track), shown in the overlay.
    @Published private(set) var remoteVideoTrack: LiveKit.VideoTrack?
    /// Called (on the main actor) when the operator's audio track subscribes, so the
    /// owner can re-assert audio output routing (LiveKit reconfigures it then).
    var onRemoteAudioSubscribed: (() -> Void)?

    private let client: Client
    private let roomManager: MatrixRoomManager
    private let capture: StreamSessionManager
    private let urlSession: URLSession

    private var liveKitRoom: LiveKit.Room?
    private lazy var roomObserver: LiveKitRoomObserver = {
        let observer = LiveKitRoomObserver()
        observer.onRemoteVideoChanged = { [weak self] track in
            Task { @MainActor [weak self] in self?.remoteVideoTrack = track }
        }
        observer.onRemoteAudioSubscribed = { [weak self] in
            Task { @MainActor [weak self] in self?.onRemoteAudioSubscribed?() }
        }
        return observer
    }()
    private var videoTrack: LocalVideoTrack?
    private var videoCapturer: BufferCapturer?
    private var audioTrack: LocalAudioTrack?
    private var delayedLeaveID: String?
    private var keepAliveTask: Task<Void, Never>?
    private var didSendJoinMembership = false
    private var hasReceivedFirstLiveKitFrame = false

    private let delayedLeaveDelayMs = 18_000
    private let delayedLeaveRestartMs: UInt64 = 5_000_000_000
    private let membershipExpiryMs = 1000 * 60 * 60 * 4

    init(client: Client, roomManager: MatrixRoomManager, capture: StreamSessionManager, urlSession: URLSession = .shared) {
        self.client = client
        self.roomManager = roomManager
        self.capture = capture
        self.urlSession = urlSession
    }

    func start(useIPhoneCamera: Bool) async throws {
        switch state {
        case .idle, .failed:
            break
        default:
            return
        }

        do {
            try await startSession(useIPhoneCamera: useIPhoneCamera)
        } catch is CancellationError {
            // The task was cancelled (e.g. the view was torn down or start re-invoked).
            // That is not a real failure — clean up quietly, don't show an error.
            await stopAfterFailure()
            state = .idle
            statusText = "MatrixRTC idle"
        } catch {
            statusText = error.localizedDescription
            state = .failed(statusText)
            await stopAfterFailure()
            throw error
        }
    }

    private func startSession(useIPhoneCamera: Bool) async throws {
        guard let roomID = roomManager.roomID else {
            throw MatrixRTCError.roomNotReady
        }

        let session = try client.session()
        let userID = session.userId
        let deviceID = session.deviceId
        let homeserverURL = URL(string: session.homeserverUrl) ?? URL(string: AppConfig.shared.homeserverURL)!
        let stateKey = makeMembershipStateKey(userID: userID, deviceID: deviceID)

        state = .announcing
        statusText = "Announcing MatrixRTC membership"

        let transport = try await discoverLiveKitTransport(homeserverURL: homeserverURL, accessToken: session.accessToken, matrixServerName: matrixServerName(from: userID))
        delayedLeaveID = try? await sendDelayedLeave(homeserverURL: homeserverURL, accessToken: session.accessToken, roomID: roomID, stateKey: stateKey)
        if let delayedLeaveID { startKeepAlive(homeserverURL: homeserverURL, accessToken: session.accessToken, delayID: delayedLeaveID) }

        try await sendMembership(
            homeserverURL: homeserverURL,
            accessToken: session.accessToken,
            roomID: roomID,
            stateKey: stateKey,
            content: makeMembershipContent(userID: userID, deviceID: deviceID, transport: transport)
        )
        didSendJoinMembership = true

        state = .requestingToken
        statusText = "Requesting Matrix OpenID token"
        let openID = try await client.requestOpenidToken()
        let sfu = try await requestSFUToken(
            serviceURL: transport.livekitServiceURL,
            roomID: roomID,
            openID: openID,
            deviceID: deviceID,
            homeserverURL: homeserverURL,
            delayID: delayedLeaveID
        )

        state = .connectingLiveKit
        statusText = "Connecting to LiveKit"
        let lkRoom = LiveKit.Room()
        lkRoom.add(delegate: roomObserver)
        liveKitRoom = lkRoom
        try await lkRoom.connect(url: sfu.url, token: sfu.jwt)

        state = .publishing
        statusText = "Publishing glasses stream"
        try await publishLocalMedia(room: lkRoom, useIPhoneCamera: useIPhoneCamera)

        // NOTE: audio output routing is owned solely by CallController.applyAudioRoute
        // (the single audio-routing path), which runs after this returns. Don't
        // override the output port here or the two fight over the route.

        state = .connected
        statusText = "MatrixRTC connected"
    }

    func stop() async {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        capture.onFrame = nil
        hasReceivedFirstLiveKitFrame = false

        await liveKitRoom?.disconnect()
        liveKitRoom = nil
        remoteVideoTrack = nil
        videoTrack = nil
        videoCapturer = nil
        audioTrack = nil
        await capture.stop()

        await sendLeaveNowIfNeeded()
        delayedLeaveID = nil
        didSendJoinMembership = false
        state = .idle
        statusText = "MatrixRTC idle"
    }

    private func stopAfterFailure() async {
        let failureText = statusText
        keepAliveTask?.cancel()
        keepAliveTask = nil
        capture.onFrame = nil
        hasReceivedFirstLiveKitFrame = false
        await liveKitRoom?.disconnect()
        liveKitRoom = nil
        remoteVideoTrack = nil
        videoTrack = nil
        videoCapturer = nil
        audioTrack = nil
        await capture.stop()
        await sendLeaveNowIfNeeded()
        delayedLeaveID = nil
        didSendJoinMembership = false
        statusText = failureText
    }

    private func sendLeaveNowIfNeeded() async {
        guard didSendJoinMembership,
              let session = try? client.session(),
              let roomID = roomManager.roomID,
              let homeserverURL = URL(string: session.homeserverUrl) ?? URL(string: AppConfig.shared.homeserverURL) else { return }

        if let delayedLeaveID {
            do {
                try await sendScheduledLeaveNow(homeserverURL: homeserverURL, accessToken: session.accessToken, delayID: delayedLeaveID)
                return
            } catch {
                NSLog("[MatrixRTC] sending scheduled leave failed, falling back to immediate leave: %@", error.localizedDescription)
            }
        }

        let stateKey = makeMembershipStateKey(userID: session.userId, deviceID: session.deviceId)
        try? await sendMembership(homeserverURL: homeserverURL, accessToken: session.accessToken, roomID: roomID, stateKey: stateKey, content: [:])
    }

    func setMuted(_ muted: Bool) async {
        do {
            if muted { try await audioTrack?.mute() }
            else { try await audioTrack?.unmute() }
        } catch {
            NSLog("[MatrixRTC] Failed to update mute state: %@", error.localizedDescription)
        }
    }

    // MARK: - Matrix membership

    private func makeMembershipStateKey(userID: String, deviceID: String) -> String {
        // Element's legacy MatrixRTC state key for the room-wide m.call slot:
        // _{userId}_{deviceId}_m.call
        "_\(userID)_\(deviceID)_m.call"
    }

    private func makeMembershipContent(userID: String, deviceID: String, transport: LiveKitTransport) -> [String: Any] {
        [
            "application": "m.call",
            "call_id": "",
            "scope": "m.room",
            "device_id": deviceID,
            "membershipID": "\(userID):\(deviceID)",
            "expires": membershipExpiryMs,
            "m.call.intent": "video",
            "focus_active": [
                "type": "livekit",
                "focus_selection": "oldest_membership"
            ],
            "foci_preferred": [
                [
                    "type": "livekit",
                    "livekit_service_url": transport.livekitServiceURL.absoluteString
                ]
            ]
        ]
    }

    private func sendDelayedLeave(homeserverURL: URL, accessToken: String, roomID: String, stateKey: String) async throws -> String {
        var components = URLComponents(url: matrixClientURL(homeserverURL, path: "/v3/rooms/\(path(roomID))/state/org.matrix.msc3401.call.member/\(path(stateKey))"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "org.matrix.msc4140.delay", value: String(delayedLeaveDelayMs))]
        let response: DelayedEventResponse = try await sendJSON(url: components.url!, method: "PUT", accessToken: accessToken, body: EmptyJSONObject())
        return response.delayID
    }

    private func sendMembership(homeserverURL: URL, accessToken: String, roomID: String, stateKey: String, content: [String: Any]) async throws {
        let url = matrixClientURL(homeserverURL, path: "/v3/rooms/\(path(roomID))/state/org.matrix.msc3401.call.member/\(path(stateKey))")
        try await sendJSONObject(url: url, method: "PUT", accessToken: accessToken, object: content)
    }

    private func startKeepAlive(homeserverURL: URL, accessToken: String, delayID: String) {
        keepAliveTask?.cancel()
        let restartInterval = delayedLeaveRestartMs
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: restartInterval)
                guard let self, !Task.isCancelled else { break }
                do {
                    try await self.restartDelayedLeave(homeserverURL: homeserverURL, accessToken: accessToken, delayID: delayID)
                } catch {
                    NSLog("[MatrixRTC] delayed leave restart failed: %@", error.localizedDescription)
                }
            }
        }
    }

    private func restartDelayedLeave(homeserverURL: URL, accessToken: String, delayID: String) async throws {
        let newStyle = matrixClientURL(homeserverURL, path: "/unstable/org.matrix.msc4140/delayed_events/\(path(delayID))/restart")
        do {
            try await sendJSONObject(url: newStyle, method: "POST", accessToken: accessToken, object: [:])
        } catch {
            let oldStyle = matrixClientURL(homeserverURL, path: "/unstable/org.matrix.msc4140/delayed_events/\(path(delayID))")
            try await sendJSONObject(url: oldStyle, method: "POST", accessToken: accessToken, object: ["action": "restart"])
        }
    }

    private func sendScheduledLeaveNow(homeserverURL: URL, accessToken: String, delayID: String) async throws {
        let newStyle = matrixClientURL(homeserverURL, path: "/unstable/org.matrix.msc4140/delayed_events/\(path(delayID))/send")
        do {
            try await sendJSONObject(url: newStyle, method: "POST", accessToken: accessToken, object: [:])
        } catch {
            let oldStyle = matrixClientURL(homeserverURL, path: "/unstable/org.matrix.msc4140/delayed_events/\(path(delayID))")
            try await sendJSONObject(url: oldStyle, method: "POST", accessToken: accessToken, object: ["action": "send"])
        }
    }

    // MARK: - SFU / LiveKit

    private func discoverLiveKitTransport(homeserverURL: URL, accessToken: String, matrixServerName: String) async throws -> LiveKitTransport {
        if let backend = try? await getBackendRTCTransport(homeserverURL: homeserverURL, accessToken: accessToken) {
            return backend
        }
        if let wellKnown = try? await getWellKnownRTCTransport(matrixServerName: matrixServerName) {
            return wellKnown
        }
        if matrixServerName == "matrix.example.org" || homeserverURL.host == "matrix.example.org" {
            return LiveKitTransport(livekitServiceURL: URL(string: "https://livekit.example.org")!)
        }
        throw MatrixRTCError.liveKitTransportUnavailable
    }

    private func getBackendRTCTransport(homeserverURL: URL, accessToken: String) async throws -> LiveKitTransport {
        let url = matrixClientURL(homeserverURL, path: "/unstable/org.matrix.msc4143/rtc/transports")
        let response: RTCTransportsResponse = try await sendJSON(url: url, method: "GET", accessToken: accessToken)
        guard let first = response.rtcTransports.first(where: { $0.type == "livekit" }) else {
            throw MatrixRTCError.liveKitTransportUnavailable
        }
        return first
    }

    private func getWellKnownRTCTransport(matrixServerName: String) async throws -> LiveKitTransport {
        let url = URL(string: "https://\(matrixServerName)/.well-known/matrix/client")!
        let (data, response) = try await urlSession.data(from: url)
        try validateHTTP(response, data: data)
        let wellKnown = try JSONDecoder().decode(WellKnownResponse.self, from: data)
        guard let first = wellKnown.rtcFoci.first(where: { $0.type == "livekit" }) else {
            throw MatrixRTCError.liveKitTransportUnavailable
        }
        return first
    }

    private func requestSFUToken(serviceURL: URL, roomID: String, openID: OpenIdToken, deviceID: String, homeserverURL: URL, delayID: String?) async throws -> SFUTokenResponse {
        let url = serviceURL.appendingPathComponent("sfu/get")
        var body: [String: Any] = [
            "room": roomID,
            "openid_token": [
                "access_token": openID.accessToken,
                "token_type": openID.tokenType,
                "matrix_server_name": openID.matrixServerName,
                "expires_in": openID.expiresInSeconds
            ],
            "device_id": deviceID
        ]
        if let delayID {
            body["delay_id"] = delayID
            body["delay_timeout"] = delayedLeaveDelayMs
            body["delay_cs_api_url"] = matrixClientURL(homeserverURL, path: "/unstable/org.matrix.msc4140").absoluteString
        }
        return try await sendJSON(url: url, method: "POST", accessToken: nil, object: body)
    }

    private func publishLocalMedia(room: LiveKit.Room, useIPhoneCamera: Bool) async throws {
        let videoTrack = LocalVideoTrack.createBufferTrack(name: "savevision-glasses", source: .camera)
        guard let capturer = videoTrack.capturer as? BufferCapturer else { throw MatrixRTCError.videoCapturerUnavailable }
        self.videoTrack = videoTrack
        self.videoCapturer = capturer

        capture.onFrame = { [weak self] image in
            Task { @MainActor [weak self] in self?.pushFrame(image) }
        }

        if useIPhoneCamera { await capture.startIPhone() }
        else { await capture.startGlasses() }

        try await waitForFirstFrame()
        try await room.localParticipant.publish(videoTrack: videoTrack)

        let audioTrack = LocalAudioTrack.createTrack(name: "savevision-microphone")
        self.audioTrack = audioTrack
        try await room.localParticipant.publish(audioTrack: audioTrack)
    }

    private func pushFrame(_ image: UIImage) {
        guard let pixelBuffer = image.makeBGRA32PixelBuffer() else { return }
        videoCapturer?.capture(pixelBuffer)
        if !hasReceivedFirstLiveKitFrame {
            hasReceivedFirstLiveKitFrame = true
        }
    }

    private func waitForFirstFrame() async throws {
        let deadline = Date().addingTimeInterval(5)
        while !hasReceivedFirstLiveKitFrame && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard hasReceivedFirstLiveKitFrame else { throw MatrixRTCError.firstFrameTimeout }
    }

    // MARK: - HTTP helpers

    private func matrixClientURL(_ homeserverURL: URL, path: String) -> URL {
        let base = homeserverURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: "\(base)/_matrix/client\(suffix)")!
    }

    private func path(_ segment: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    private func matrixServerName(from userID: String) -> String {
        userID.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? URL(string: AppConfig.shared.homeserverURL)?.host ?? "matrix.example.org"
    }

    private func sendJSONObject(url: URL, method: String, accessToken: String?, object: [String: Any]) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: object)
        let (data, response) = try await urlSession.data(for: request)
        try validateHTTP(response, data: data)
    }

    private func sendJSON<Response: Decodable>(url: URL, method: String, accessToken: String?) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await urlSession.data(for: request)
        try validateHTTP(response, data: data)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func sendJSON<Response: Decodable, Body: Encodable>(url: URL, method: String, accessToken: String?, body: Body) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await urlSession.data(for: request)
        try validateHTTP(response, data: data)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func sendJSON<Response: Decodable>(url: URL, method: String, accessToken: String?, object: [String: Any]) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: object)
        let (data, response) = try await urlSession.data(for: request)
        try validateHTTP(response, data: data)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func validateHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MatrixRTCError.http(status: http.statusCode, body: body)
        }
    }
}

private struct EmptyJSONObject: Encodable {}

private struct DelayedEventResponse: Decodable {
    let delayID: String

    enum CodingKeys: String, CodingKey { case delayID = "delay_id" }
}

private struct RTCTransportsResponse: Decodable {
    let rtcTransports: [LiveKitTransport]

    enum CodingKeys: String, CodingKey { case rtcTransports = "rtc_transports" }
}

private struct WellKnownResponse: Decodable {
    let rtcFoci: [LiveKitTransport]

    enum CodingKeys: String, CodingKey { case rtcFoci = "org.matrix.msc4143.rtc_foci" }
}

private struct LiveKitTransport: Decodable {
    let type: String
    let livekitServiceURL: URL

    init(type: String = "livekit", livekitServiceURL: URL) {
        self.type = type
        self.livekitServiceURL = livekitServiceURL
    }

    enum CodingKeys: String, CodingKey {
        case type
        case livekitServiceURL = "livekit_service_url"
    }
}

private struct SFUTokenResponse: Decodable {
    let url: String
    let jwt: String
}

private enum MatrixRTCError: LocalizedError {
    case roomNotReady
    case liveKitTransportUnavailable
    case videoCapturerUnavailable
    case firstFrameTimeout
    case http(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .roomNotReady:
            return "Matrix room is not ready yet."
        case .liveKitTransportUnavailable:
            return "No LiveKit MatrixRTC focus was advertised by the homeserver."
        case .videoCapturerUnavailable:
            return "LiveKit buffer video capturer was unavailable."
        case .firstFrameTimeout:
            return "Timed out waiting for a video frame before publishing LiveKit media."
        case let .http(status, body):
            return "MatrixRTC HTTP \(status): \(body)"
        }
    }
}

private extension UIImage {
    func makeBGRA32PixelBuffer() -> CVPixelBuffer? {
        let width = max(1, Int(size.width * scale))
        let height = max(1, Int(size.height * scale))
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / size.width, y: -CGFloat(height) / size.height)
        UIGraphicsPushContext(context)
        draw(in: CGRect(origin: .zero, size: size))
        UIGraphicsPopContext()
        return buffer
    }
}

// MARK: - Remote video observer

/// Bridges LiveKit's `@objc RoomDelegate` (called off the main thread) to a
/// closure, surfacing the operator's remote video track. Kept as a separate
/// `NSObject` so the `@MainActor` session manager needn't adopt the @objc
/// protocol — mirrors the `TimelineListenerProxy` pattern used for Matrix.
final class LiveKitRoomObserver: NSObject, RoomDelegate, @unchecked Sendable {
    var onRemoteVideoChanged: (@Sendable (LiveKit.VideoTrack?) -> Void)?
    /// Fired when a remote audio track subscribes — LiveKit reconfigures the audio
    /// session then, so CallController re-asserts the chosen output route.
    var onRemoteAudioSubscribed: (@Sendable () -> Void)?

    func room(_ room: LiveKit.Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        if let track = publication.track as? VideoTrack { onRemoteVideoChanged?(track) }
        if publication.kind == .audio { onRemoteAudioSubscribed?() }
    }

    func room(_ room: LiveKit.Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        if publication.track is VideoTrack { onRemoteVideoChanged?(nil) }
    }

    func room(_ room: LiveKit.Room, participantDidDisconnect participant: RemoteParticipant) {
        onRemoteVideoChanged?(nil)
    }
}
