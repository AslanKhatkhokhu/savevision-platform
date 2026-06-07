import CoreImage
import CoreMedia
import CoreVideo
import MWDATCamera
import MWDATCore
import MWDATDisplay
import Sentry
import SwiftUI
import VideoToolbox

enum CaptureStatus {
    case stopped
    case waiting
    case streaming
}

enum CaptureSource {
    case glasses
    case iPhone
}

enum CaptureError: LocalizedError {
    case cameraUnavailable(String)
    var errorDescription: String? {
        switch self { case .cameraUnavailable(let message): return message }
    }
}

/// Thread-safe holder for the connected device's `Compatibility` and display
/// capability, written from the device-selector filter (which runs off the main
/// actor) and read on the main actor.
final class CompatibilityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Compatibility = .undefined
    private var storedSupportsDisplay = false
    var value: Compatibility {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    var supportsDisplay: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storedSupportsDisplay }
        set { lock.lock(); storedSupportsDisplay = newValue; lock.unlock() }
    }
}

/// Captures live video frames from the Meta Ray-Ban glasses (DAT SDK) — or the
/// iPhone camera as a fallback — and forwards each frame as a `UIImage` via
/// `onFrame`. The same DAT device session is also used for the Ray-Ban Display
/// HUD capability, so video and display can coexist on one glasses session.
@MainActor
final class StreamSessionManager: ObservableObject {
    @Published var previewFrame: UIImage?
    @Published var hasReceivedFirstFrame = false
    @Published var status: CaptureStatus = .stopped
    @Published var source: CaptureSource = .glasses
    /// Whether a glasses device is *actively connected* (not merely paired) and
    /// therefore eligible for a camera session. Driven by the DAT SDK's
    /// `activeDeviceStream()` — the same signal the reference apps use.
    @Published var hasActiveDevice = false
    /// Whether the connected glasses actually have a Ray-Ban *Display* (HUD). When
    /// false, the app falls back to using the phone screen as the overlay surface.
    @Published var hasDisplayCapableDevice = false
    @Published var showError = false
    @Published var errorMessage = ""
    @Published private(set) var displayStatusText = "Ray-Ban Display renderer ready"

    /// Frame sink — set by `CallController`. Called for every captured frame.
    var onFrame: ((UIImage) -> Void)?

    var isCapturing: Bool { status != .stopped }

    private let wearables: WearablesInterface
    /// Long-lived selector used only to observe device availability (independent
    /// of the per-session selector created in `ensureDeviceSession`).
    private let activeDeviceSelector: AutoDeviceSelector
    private var activeDeviceTask: Task<Void, Never>?
    private var deviceSelector: (any DeviceSelector)?
    private var deviceSession: DeviceSession?
    private var stream: MWDATCamera.Stream?
    private var display: MWDATDisplay.Display?

    private var sessionStateListenerToken: (any AnyListenerToken)?
    private var sessionErrorListenerToken: (any AnyListenerToken)?
    private var streamStateListenerToken: (any AnyListenerToken)?
    private var videoFrameListenerToken: (any AnyListenerToken)?
    private var streamErrorListenerToken: (any AnyListenerToken)?
    private var displayStateListenerToken: (any AnyListenerToken)?

    private var iPhoneCamera: IPhoneCameraManager?

    /// Set while we deliberately tear a session down (source switch / hang-up) so a
    /// stray `.sessionAlreadyStopped` from our own `stop()` isn't mistaken for the
    /// session dying out from under us and doesn't trigger an auto-restart.
    private var isTearingDown = false
    /// Set while we are already rebuilding a dead session, so nested session errors
    /// emitted during teardown/rebuild don't kick off a second concurrent restart.
    private var isRecovering = false
    /// True once real operator content has been pushed to the display, so we only
    /// show the idle "waiting" card before the first item arrives.
    private var hasRenderedOverlayItem = false

    // Background decode path (iOS suspends GPU rendering in the background).
    private let cpuCIContext = CIContext(options: [.useSoftwareRenderer: true])
    private let videoDecoder = VideoDecoder()

    init(wearables: WearablesInterface) {
        self.wearables = wearables
        // The selector's filter sees each candidate `Device` (the only place the
        // SDK exposes `compatibility`). Record it — so a failed camera attach can
        // explain itself — while passing every device through unchanged.
        let recorder = CompatibilityRecorder()
        self.activeDeviceSelector = AutoDeviceSelector(wearables: wearables, filter: { device in
            recorder.value = device.compatibility()
            recorder.supportsDisplay = device.supportsDisplay()
            return true
        })
        self.compatibilityRecorder = recorder
        setupVideoDecoder()
        observeActiveDevice()
    }

    private let compatibilityRecorder: CompatibilityRecorder

    /// Track whether a device is actively connected (vs merely paired) so the UI
    /// can tell the truth and so glasses capture only starts when it can succeed.
    private func observeActiveDevice() {
        activeDeviceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await device in self.activeDeviceSelector.activeDeviceStream() {
                let present = (device != nil)
                if present != self.hasActiveDevice {
                    NSLog("[Capture] active device: %@", present ? "present" : "none")
                }
                self.hasActiveDevice = present
                // `activeDeviceStream()` only yields a device id; display capability
                // is recorded by the selector filter (which sees the full `Device`).
                let canDisplay = present && self.compatibilityRecorder.supportsDisplay
                if canDisplay != self.hasDisplayCapableDevice {
                    NSLog("[Capture] device display capability: %@", canDisplay ? "yes" : "no")
                }
                self.hasDisplayCapableDevice = canDisplay
                // Greet a freshly connected Ray-Ban Display with the idle card so the
                // wearer sees the overlay is live before any operator content arrives.
                if canDisplay, DisplaySettings.enabled, !self.hasRenderedOverlayItem {
                    Task { @MainActor [weak self] in await self?.clearRayBanDisplay() }
                }
            }
        }
    }

    deinit {
        activeDeviceTask?.cancel()
        let tokens: [any AnyListenerToken] = [
            sessionStateListenerToken,
            sessionErrorListenerToken,
            streamStateListenerToken,
            videoFrameListenerToken,
            streamErrorListenerToken,
            displayStateListenerToken,
        ].compactMap { $0 }
        Task { for token in tokens { await token.cancel() } }
    }

    // MARK: - Glasses capture

    /// Start the glasses camera feed.
    ///
    /// - Parameter forceNewSession: discard any cached DAT session first and build a
    ///   fresh one. Set when switching back to glasses from the phone camera — a
    ///   leftover session may have been stopped by the SDK and a stopped DAT session
    ///   can't be restarted, only replaced.
    func startGlasses(forceNewSession: Bool = false) async {
        source = .glasses
        // Re-arm auto-recovery: a prior intentional stop() may have left us in
        // tear-down mode; a deliberate (re)start means we want the feed back.
        isTearingDown = false
        NSLog("[Capture] startGlasses() requested (activeDevice: %@, forceNew: %@)",
              activeDeviceSelector.activeDevice != nil ? "present" : "none",
              forceNewSession ? "yes" : "no")
        if forceNewSession { discardSession() }

        do {
            try await startGlassesAttempt()
        } catch let error as DeviceSessionError where error == .sessionAlreadyStopped || error == .sessionAlreadyExists {
            // The cached session is dead or duplicated — neither can be revived.
            // Drop it and try once more with a brand-new session before surfacing
            // anything to the wearer.
            NSLog("[Capture] %@ — recreating session and retrying", String(describing: error))
            discardSession()
            do { try await startGlassesAttempt() }
            catch { reportStartFailure(error) }
        } catch {
            reportStartFailure(error)
        }
    }

    /// One attempt at bringing up the glasses camera. Throws so the caller can
    /// distinguish a recoverable dead-session error from a terminal one.
    private func startGlassesAttempt() async throws {
        let permission = Permission.camera
        let status = try await wearables.checkPermissionStatus(permission)
        if status != .granted {
            let requested = try await wearables.requestPermission(permission)
            guard requested == .granted else {
                throw CaptureError.cameraUnavailable("Glasses camera permission denied.")
            }
        }

        let session = try ensureDeviceSession(requiresDisplay: false)
        // The camera Stream is a *capability* on the session. addStream returns
        // nil (→ our capabilityNotFound) when attached to an idle session, so the
        // session must be started BEFORE the capability is added.
        try startSessionIfNeeded(session)
        // `session.start()` is async: state goes .idle/.starting → .started over the
        // next moment. Attaching the camera before it's actually `.started` makes
        // addStream return nil ("Camera unavailable") — the cause of the first-try
        // failure that succeeds on retry. Wait for `.started` first.
        try await waitForSessionStarted(session)
        NSLog("[Capture] session started (state: %@) — attaching camera stream", String(describing: session.state))
        let stream = try await ensureStream(on: session)
        await stream.start()
        NSLog("[Capture] glasses stream.start() issued (session state: %@)", String(describing: session.state))
    }

    private func reportStartFailure(_ error: Error) {
        switch error {
        case let error as PermissionError: show("Permission error: \(error.description)")
        case let error as CaptureError: show(error.localizedDescription)
        case let error as DeviceSessionError: show("Glasses session error: \(error.localizedDescription)")
        default: show("Glasses stream error: \(error.localizedDescription)")
        }
    }

    // MARK: - iPhone fallback

    func startIPhone() async {
        source = .iPhone
        // We're leaving glasses behind — ignore any late session errors from a
        // glasses session being torn down rather than auto-restarting it.
        isTearingDown = true
        guard await IPhoneCameraManager.requestPermission() else {
            show("Camera permission denied. Grant access in Settings.")
            return
        }
        let camera = IPhoneCameraManager()
        camera.onFrameCaptured = { [weak self] image in
            Task { @MainActor [weak self] in self?.handleFrame(image) }
        }
        camera.start()
        iPhoneCamera = camera
        status = .streaming
        NSLog("[Capture] iPhone camera started")
    }

    func stop() async {
        // This is a deliberate teardown — suppress auto-restart on the
        // `.sessionAlreadyStopped` our own `stop()` may emit.
        isTearingDown = true
        switch source {
        case .iPhone:
            iPhoneCamera?.stop()
            iPhoneCamera = nil
            previewFrame = nil
            hasReceivedFirstFrame = false
            status = .stopped
        case .glasses:
            await stream?.stop()
            if let session = deviceSession { try? session.removeCapability(MWDATCamera.Stream.self) }
            stream = nil
            clearStreamListenerTokens()
            previewFrame = nil
            hasReceivedFirstFrame = false
            status = .stopped
            stopSessionIfIdle()
        }
    }

    // MARK: - DAT session / stream

    private func ensureDeviceSession(requiresDisplay: Bool) throws -> DeviceSession {
        // A DAT session that has stopped cannot be restarted — start() throws
        // `.sessionAlreadyStopped`. Drop a dead cached session so we build a fresh
        // one instead of handing back a corpse.
        if let existing = deviceSession, existing.state == .stopped || existing.state == .stopping {
            NSLog("[Capture] discarding dead device session (state: %@)", String(describing: existing.state))
            discardSession()
        }
        if let deviceSession { return deviceSession }

        // 0.7.0's createSession throws .noEligibleDevice immediately if its selector
        // has no eligible device at that instant. Creating a *fresh* AutoDeviceSelector
        // here races the long-lived one (which has already resolved the connected
        // glasses) and loses — the cause of "No eligible device available" even when a
        // device is connected. So pin the camera session to the device the long-lived
        // selector already resolved.
        let selector: any DeviceSelector
        if requiresDisplay {
            let s = AutoDeviceSelector(wearables: wearables, filter: { $0.supportsDisplay() })
            deviceSelector = s
            selector = s
        } else if let active = activeDeviceSelector.activeDevice {
            NSLog("[Capture] creating camera session pinned to active device")
            selector = SpecificDeviceSelector(device: active)
        } else {
            NSLog("[Capture] no active device resolved yet — reusing the long-lived selector")
            selector = activeDeviceSelector
        }
        let session = try wearables.createSession(deviceSelector: selector)
        deviceSession = session
        attachSessionListeners(session)
        return session
    }

    private func startSessionIfNeeded(_ session: DeviceSession) throws {
        switch session.state {
        case .started, .starting, .paused:
            return
        case .idle, .stopped, .stopping:
            try session.start()
        }
    }

    /// Wait for the DAT session to actually reach `.started` after `start()` (which
    /// only kicks off an async transition). Without this, `addStream` is attached to
    /// a still-`.starting` session and returns nil ("Camera unavailable") on the
    /// first attempt. Polls because the SDK doesn't expose an awaitable "ready".
    private func waitForSessionStarted(_ session: DeviceSession, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch session.state {
            case .started:
                return
            case .stopped, .stopping:
                // Died while starting — let the caller rebuild a fresh session.
                throw DeviceSessionError.sessionAlreadyStopped
            case .idle, .starting, .paused:
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }
        NSLog("[Capture] session did not reach .started within %.0fs (state: %@) — attempting stream anyway",
              timeout, String(describing: session.state))
    }

    private func stopSessionIfIdle() {
        guard stream == nil, display == nil, let session = deviceSession else { return }
        session.stop()
        deviceSession = nil
        deviceSelector = nil
        clearSessionListenerTokens()
    }

    /// Drop the cached DAT session and every capability attached to it. A stopped
    /// DAT session cannot be restarted (`start()` → `.sessionAlreadyStopped`), so the
    /// only recovery is to build a brand-new session on the next start. Use this
    /// whenever the session is dead or we're switching back to glasses fresh.
    private func discardSession() {
        deviceSession?.stop() // non-throwing; a no-op if the session already stopped
        deviceSession = nil
        deviceSelector = nil
        stream = nil
        display = nil
        clearStreamListenerTokens()
        clearDisplayListenerToken()
        clearSessionListenerTokens()
    }

    private func ensureStream(on session: DeviceSession) async throws -> MWDATCamera.Stream {
        if let stream { return stream }
        let config = StreamConfiguration(
            videoCodec: MWDATCamera.VideoCodec.raw,
            resolution: StreamingResolution.low,
            frameRate: 24
        )
        // The camera capability can briefly lag behind the session reaching
        // `.started`, so addStream returns nil for a moment. Retry a few times before
        // declaring the camera unavailable — this is what made the first attempt fail
        // and a manual retry succeed.
        var created: MWDATCamera.Stream?
        for attempt in 0..<6 {
            if let s = try session.addStream(config: config) {
                created = s
                break
            }
            NSLog("[Capture] addStream returned nil (attempt %d/6) — retrying", attempt + 1)
            try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
        }
        guard let stream = created else {
            // addStream returns nil when the camera capability can't attach. Surface
            // the *real* reason (the device's DAT compatibility) instead of a
            // misleading "capability not found", and report it to Bugsink/ojiichan.
            let compat = compatibilityRecorder.value
            let detail: String
            switch compat {
            case .deviceUpdateRequired:
                detail = "the glasses need a software update (open the Meta AI app → device → update)"
            case .sdkUpdateRequired:
                detail = "these glasses need a newer DAT SDK than this app bundles"
            case .compatible:
                detail = "the glasses report compatible but didn't expose a camera stream — they may not support DAT camera streaming (Display-only)"
            case .undefined:
                detail = "the glasses didn't report a camera capability (they may be Display-only, or not fully connected)"
            @unknown default:
                detail = "camera streaming is unavailable on these glasses"
            }
            NSLog("[Capture] addStream returned nil — compatibility=%@", String(describing: compat))
            SentrySDK.capture(message: "Glasses camera addStream unavailable") { scope in
                scope.setTag(value: "glasses_camera", key: "phase")
                scope.setContext(value: ["compatibility": String(describing: compat)], key: "wearables")
            }
            throw CaptureError.cameraUnavailable("Camera unavailable: \(detail).")
        }
        self.stream = stream
        attachStreamListeners(stream)
        return stream
    }

    private func attachSessionListeners(_ session: DeviceSession) {
        sessionStateListenerToken = session.statePublisher.listen { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if state == .stopped, self.status != .stopped { self.status = .waiting }
            }
        }
        sessionErrorListenerToken = session.errorPublisher.listen { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Don't fight an intentional teardown or a restart already in flight.
                if self.isTearingDown || self.isRecovering { return }
                // The session died out from under us. A stopped DAT session can't be
                // restarted, so rebuild a fresh one rather than stranding the wearer
                // on "Session has already been stopped. Tap to retry".
                if error == .sessionAlreadyStopped, self.source == .glasses {
                    NSLog("[Capture] session reported already-stopped — auto-recreating session")
                    self.isRecovering = true
                    self.discardSession()
                    await self.startGlasses(forceNewSession: true)
                    self.isRecovering = false
                    return
                }
                self.show("Glasses session error: \(error.localizedDescription)")
            }
        }
    }

    private func attachStreamListeners(_ stream: MWDATCamera.Stream) {
        clearStreamListenerTokens()

        streamStateListenerToken = stream.statePublisher.listen { [weak self] state in
            Task { @MainActor [weak self] in self?.updateStatus(from: state) }
        }

        videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] videoFrame in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let inBackground = UIApplication.shared.applicationState == .background
                if !inBackground {
                    if let image = videoFrame.makeUIImage() {
                        self.handleFrame(image)
                    } else {
                        // Frame arrived but couldn't be turned into a UIImage — this
                        // is the silent failure that leaves the preview stuck on
                        // "Waiting for glasses video…". Surface it.
                        NSLog("[Capture] glasses frame received but makeUIImage() returned nil")
                    }
                } else {
                    // Background: decode compressed frames on the CPU.
                    let sampleBuffer = videoFrame.sampleBuffer
                    if CMSampleBufferGetDataBuffer(sampleBuffer) != nil {
                        try? self.videoDecoder.decode(sampleBuffer)
                    } else if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                        let rect = CGRect(
                            x: 0, y: 0,
                            width: CVPixelBufferGetWidth(pixelBuffer),
                            height: CVPixelBufferGetHeight(pixelBuffer)
                        )
                        if let cgImage = self.cpuCIContext.createCGImage(ciImage, from: rect) {
                            self.handleFrame(UIImage(cgImage: cgImage))
                        }
                    }
                }
            }
        }

        streamErrorListenerToken = stream.errorPublisher.listen { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.status == .stopped {
                    if case .deviceNotConnected = error { return }
                    if case .deviceNotFound = error { return }
                }
                self.show(self.format(error))
            }
        }

        updateStatus(from: stream.state)
    }

    private func clearSessionListenerTokens() {
        let tokens = [sessionStateListenerToken, sessionErrorListenerToken].compactMap { $0 }
        Task { for token in tokens { await token.cancel() } }
        sessionStateListenerToken = nil
        sessionErrorListenerToken = nil
    }

    private func clearStreamListenerTokens() {
        let tokens = [streamStateListenerToken, videoFrameListenerToken, streamErrorListenerToken].compactMap { $0 }
        Task { for token in tokens { await token.cancel() } }
        streamStateListenerToken = nil
        videoFrameListenerToken = nil
        streamErrorListenerToken = nil
    }

    private func clearDisplayListenerToken() {
        if let token = displayStateListenerToken {
            Task { await token.cancel() }
        }
        displayStateListenerToken = nil
    }

    // MARK: - Frame handling

    private func handleFrame(_ image: UIImage) {
        previewFrame = image
        if !hasReceivedFirstFrame {
            hasReceivedFirstFrame = true
            NSLog("[Capture] First %@ frame received (%.0f×%.0f)",
                  source == .glasses ? "glasses" : "iPhone", image.size.width, image.size.height)
        }
        onFrame?(image)
    }

    private func setupVideoDecoder() {
        videoDecoder.setFrameCallback { [weak self] decoded in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let ciImage = CIImage(cvPixelBuffer: decoded.pixelBuffer)
                let rect = CGRect(
                    x: 0, y: 0,
                    width: CVPixelBufferGetWidth(decoded.pixelBuffer),
                    height: CVPixelBufferGetHeight(decoded.pixelBuffer)
                )
                if let cgImage = self.cpuCIContext.createCGImage(ciImage, from: rect) {
                    self.onFrame?(UIImage(cgImage: cgImage))
                }
            }
        }
    }

    private func updateStatus(from state: MWDATCamera.StreamState) {
        NSLog("[Capture] glasses stream state: %@", String(describing: state))
        switch state {
        case .stopped:
            previewFrame = nil
            status = .stopped
        case .waitingForDevice, .starting, .stopping, .paused:
            status = .waiting
        case .streaming:
            status = .streaming
        }
    }

    private func show(_ message: String) {
        NSLog("[Capture] error: %@", message)
        errorMessage = message
        showError = true
    }

    func dismissError() { showError = false; errorMessage = "" }

    private func format(_ error: MWDATCamera.StreamError) -> String {
        switch error {
        case .internalError: return "An internal error occurred. Please try again."
        case .deviceNotFound: return "Glasses not found. Ensure they are connected."
        case .deviceNotConnected: return "Glasses not connected. Check the connection."
        case .timeout: return "The operation timed out. Please try again."
        case .videoStreamingError: return "Video streaming failed."
        case .permissionDenied: return "Camera permission denied. Grant it in Settings."
        case .hingesClosed: return "The glasses hinges are closed. Open them and try again."
        case .thermalCritical: return "Glasses are hot; streaming may be limited."
        case .thermalEmergency: return "Glasses overheated and stopped streaming."
        case .peakPowerShutdown: return "Glasses stopped streaming due to peak-power protection."
        case .batteryCritical: return "Glasses battery is critically low."
        @unknown default: return "An unknown streaming error occurred."
        }
    }
}

// MARK: - Ray-Ban Display renderer

extension StreamSessionManager: DisplayOverlayRendering {
    var statusText: String { displayStatusText }

    /// A real Ray-Ban Display HUD is connected and enabled. When false, the app
    /// uses the phone screen as the overlay surface instead.
    var isDisplayAvailable: Bool { DisplaySettings.enabled && hasDisplayCapableDevice }

    func render(_ item: DisplayOverlayItem) {
        hasRenderedOverlayItem = true
        guard DisplaySettings.enabled else {
            displayStatusText = "Ray-Ban Display disabled in Settings"
            return
        }
        Task { @MainActor in await sendToRayBanDisplay(item) }
    }

    func clear() {
        hasRenderedOverlayItem = false
        guard DisplaySettings.enabled else { return }
        Task { @MainActor in await clearRayBanDisplay() }
    }

    private func ensureDisplay() async throws -> MWDATDisplay.Display {
        let session = try ensureDeviceSession(requiresDisplay: true)
        let display: MWDATDisplay.Display
        if let existing = self.display {
            display = existing
        } else {
            let added = try session.addDisplay()
            self.display = added
            display = added
            displayStateListenerToken = added.statePublisher.listen { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.displayStatusText = "Ray-Ban Display: \(String(describing: state))"
                }
            }
        }
        try startSessionIfNeeded(session)
        if display.state != .started && display.state != .starting { await display.start() }
        return display
    }

    private func sendToRayBanDisplay(_ item: DisplayOverlayItem) async {
        do {
            let display = try await ensureDisplay()
            try await display.send(makeDisplayView(for: item))
            displayStatusText = "Ray-Ban Display updated"
        } catch let error as DeviceSessionError {
            displayStatusText = "Ray-Ban Display unavailable: \(error.localizedDescription)"
            NSLog("[HUD] Display session error: %@", error.localizedDescription)
        } catch {
            displayStatusText = "Ray-Ban Display send failed: \(error.localizedDescription)"
            NSLog("[HUD] Display send failed: %@", error.localizedDescription)
        }
    }

    private func clearRayBanDisplay() async {
        do {
            let display = try await ensureDisplay()
            try await display.send(
                MWDATDisplay.FlexBox(direction: .column, spacing: 10, alignment: .center, crossAlignment: .center) {
                    MWDATDisplay.Icon(name: .smartGlasses)
                    MWDATDisplay.Text("SaveVision", style: .heading)
                    MWDATDisplay.Text("Waiting for operator guidance", style: .body, color: .secondary)
                }
                .padding(18)
                .background(.card)
            )
            displayStatusText = "Ray-Ban Display cleared"
        } catch {
            displayStatusText = "Ray-Ban Display clear failed: \(error.localizedDescription)"
        }
    }

    private func makeDisplayView(for item: DisplayOverlayItem) -> MWDATDisplay.FlexBox {
        // Text guidance: keep the tiny lens uncluttered — just an operator icon and
        // the message itself (no title/timestamp/coordinate lines).
        if item.kind == .message {
            return MWDATDisplay.FlexBox(direction: .column, spacing: 10, alignment: .center, crossAlignment: .center) {
                MWDATDisplay.Icon(name: item.isUrgent ? .exclamationTriangle : .speechBubble)
                MWDATDisplay.Text(item.body.isEmpty ? " " : item.body, style: .heading)
            }
            .padding(18)
            .background(.card)
        }

        let imageURI = imageURI(for: item)
        let icon = iconName(for: item)
        let heading = item.isUrgent ? "URGENT" : item.title
        let body = item.body.isEmpty ? " " : item.body

        return MWDATDisplay.FlexBox(direction: .column, spacing: 12, alignment: .center, crossAlignment: .stretch) {
            MWDATDisplay.FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center) {
                MWDATDisplay.Icon(name: icon)
                MWDATDisplay.Text(heading, style: .meta, color: .secondary)
            }

            if let imageURI {
                // DAT 0.7.0's ImageSize only has .icon / .fill (no .medium). .fill
                // overflowed the lens, so use the smaller .icon preset.
                MWDATDisplay.Image(uri: imageURI, sizePreset: .icon, cornerRadius: .medium)
            }

            if let coordinate = item.coordinate {
                MWDATDisplay.Text(coordinate.shortText, style: .body, color: .secondary)
            }

            if item.kind == .map, let bearing = item.bearing {
                MWDATDisplay.Text("Bearing \(Int(bearing))°", style: .body, color: .secondary)
            }

            MWDATDisplay.Text(body, style: .heading)
        }
        .padding(18)
        .background(.card)
    }

    private func iconName(for item: DisplayOverlayItem) -> MWDATDisplay.IconName {
        if item.isUrgent { return .exclamationTriangle }
        switch item.kind {
        case .message: return .speechBubble
        case .image: return .mountainSquare
        case .location: return .compassNorthUpRed
        case .map: return .arrowRight
        case .clear: return .x
        }
    }

    private func imageURI(for item: DisplayOverlayItem) -> String? {
        if let data = item.imageData {
            let safe = item.id.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("savevision-hud-\(safe).jpg")
            do {
                try data.write(to: url, options: .atomic)
                return url.absoluteString
            } catch {
                NSLog("[HUD] Failed to persist display image: %@", error.localizedDescription)
            }
        }
        guard let remoteURL = item.remoteURL,
              remoteURL.hasPrefix("http://") || remoteURL.hasPrefix("https://") || remoteURL.hasPrefix("file://") else {
            return nil
        }
        return remoteURL
    }
}
