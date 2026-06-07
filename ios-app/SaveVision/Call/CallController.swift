import AVFoundation
import Combine
import Foundation
import LiveKit
import WebRTC

enum CallState: Equatable {
    case idle
    case connecting   // capturing + offer sent, waiting for the operator
    case connected    // ICE connected — operator is seeing the POV
    case failed(String)
    case ended
}

/// Where the operator's voice is played during a call.
enum AudioRoute: Equatable {
    /// Ray-Ban glasses speakers over Bluetooth (hands-free). Falls back to the
    /// loudspeaker when no Bluetooth audio device is actually connected.
    case glasses
    /// The iPhone's built-in loudspeaker.
    case phoneSpeaker

    var label: String { self == .glasses ? "Glasses" : "Speaker" }
    var icon: String { self == .glasses ? "eyeglasses" : "speaker.wave.2.fill" }
}

/// Orchestrates a one-way POV call. Production calls use MatrixRTC + LiveKit
/// (the Element Call / Element X path). The old direct WebRTC + SV1 Matrix text
/// signaling remains as a fallback if no MatrixRTC session is injected.
@MainActor
final class CallController: NSObject, ObservableObject {
    @Published private(set) var state: CallState = .idle
    @Published var isMuted = false
    /// Operator audio defaults to the phone loudspeaker — it's reliably audible.
    /// (Routing to the glasses depends on them being a working Bluetooth audio
    /// device, which isn't guaranteed.) The wearer can switch to glasses from the
    /// call screen.
    @Published private(set) var audioRoute: AudioRoute = .phoneSpeaker
    /// The operator's return video on the SV1 WebRTC fallback path. On the
    /// production MatrixRTC path, read `operatorLiveKitVideo` instead.
    @Published private(set) var operatorWebRTCVideo: RTCVideoTrack?

    /// The operator's return video on the production MatrixRTC/LiveKit path.
    var operatorLiveKitVideo: LiveKit.VideoTrack? { matrixRTC?.remoteVideoTrack }

    private let signaling: SignalingTransport
    private let capture: StreamSessionManager
    private let matrixRTC: MatrixRTCSessionManager?
    private var webRTC: WebRTCClient?
    private var cancellables = Set<AnyCancellable>()

    /// Use the iPhone camera instead of the glasses (testing without hardware).
    var useIPhoneCamera = false

    init(signaling: SignalingTransport, capture: StreamSessionManager, matrixRTC: MatrixRTCSessionManager? = nil) {
        self.signaling = signaling
        self.capture = capture
        self.matrixRTC = matrixRTC
        super.init()
        self.signaling.onMessage = { [weak self] message in
            Task { @MainActor [weak self] in self?.handle(message) }
        }
        // Re-publish MatrixRTC changes (e.g. the operator video track arriving) so
        // views observing this controller refresh the overlay.
        matrixRTC?.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // LiveKit reconfigures the audio session when the operator's voice subscribes;
        // re-assert our chosen route so this controller stays the single source of truth.
        matrixRTC?.onRemoteAudioSubscribed = { [weak self] in
            guard let self else { return }
            self.applyAudioRoute(self.audioRoute)
        }
    }

    // MARK: - Lifecycle

    func startCall() async {
        guard state == .idle || state == .ended else { return }
        state = .connecting

        applyAudioRoute(audioRoute)

        if let matrixRTC {
            do {
                try await matrixRTC.start(useIPhoneCamera: useIPhoneCamera)
                state = .connected
                // LiveKit reconfigures the audio session on connect — re-assert our
                // chosen output (glasses by default) once it's up.
                applyAudioRoute(audioRoute)
            } catch {
                state = .failed(error.localizedDescription)
                deactivateAudioSession()
            }
            return
        }

        let client = WebRTCClient()
        client.delegate = self
        client.setup(iceServers: WebRTCConfig.iceServers())
        self.webRTC = client

        // Route every captured frame into the WebRTC video track.
        capture.onFrame = { [weak client] image in
            client?.pushVideoFrame(image)
        }

        if useIPhoneCamera {
            await capture.startIPhone()
        } else {
            await capture.startGlasses()
        }

        // Offerer: create the offer and send it to the operator.
        client.createOffer { [weak self] sdp in
            self?.signaling.send(.offer(sdp: sdp.sdp))
        }
    }

    func endCall() {
        guard state != .idle else { return }
        if matrixRTC == nil { signaling.send(.hangup) }
        teardown()
        state = .ended
    }

    func toggleMute() {
        isMuted.toggle()
        webRTC?.muteAudio(isMuted)
        if let matrixRTC {
            Task { await matrixRTC.setMuted(isMuted) }
        }
    }

    private func teardown() {
        if let matrixRTC {
            Task { await matrixRTC.stop() }
        } else {
            capture.onFrame = nil
            Task { await capture.stop() }
        }
        webRTC?.close()
        webRTC = nil
        operatorWebRTCVideo = nil
        deactivateAudioSession()
    }

    // MARK: - Inbound signaling

    private func handle(_ message: SignalingMessage) {
        guard let webRTC else { return }
        switch message {
        case .answer(let sdp):
            let desc = RTCSessionDescription(type: .answer, sdp: sdp)
            webRTC.set(remoteSdp: desc) { error in
                if let error { NSLog("[Call] setRemoteDescription failed: %@", error.localizedDescription) }
            }
        case .candidate(let sdp, let mid, let index):
            let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: index, sdpMid: mid)
            webRTC.add(remoteCandidate: candidate) { error in
                if let error { NSLog("[Call] addCandidate failed: %@", error.localizedDescription) }
            }
        case .hangup:
            teardown()
            state = .ended
        case .offer:
            // The wearer is always the offerer; ignore inbound offers.
            break
        }
    }

    // MARK: - Audio routing

    /// Flip operator audio between the glasses and the phone speaker, live, during a
    /// call. Mirrored in the call UI as the speaker/glasses button.
    func toggleAudioRoute() {
        audioRoute = (audioRoute == .glasses) ? .phoneSpeaker : .glasses
        applyAudioRoute(audioRoute)
    }

    private func applyAudioRoute(_ route: AudioRoute) {
        let session = AVAudioSession.sharedInstance()

        // On the MatrixRTC/LiveKit path, LiveKit owns the category and activation.
        // Calling setCategory/setActive here fights LiveKit and throws — which used to
        // swallow the output override below, leaving the operator's voice on the silent
        // earpiece (the "can't hear audio" regression). So only own the category on the
        // SV1 WebRTC path; on LiveKit, just steer the output port.
        if matrixRTC == nil {
            do {
                let options: AVAudioSession.CategoryOptions = route == .phoneSpeaker
                    ? [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
                    : [.allowBluetoothHFP, .allowBluetoothA2DP]
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
                try session.setActive(true)
            } catch {
                NSLog("[Call] Audio category error: %@", error.localizedDescription)
            }
        }

        // Output routing — applies on both transports.
        do {
            switch route {
            case .glasses:
                // Prefer the Bluetooth (glasses) route; if no BT audio device is
                // actually connected, use the loudspeaker — the earpiece is far too
                // quiet for a hands-free wearer (and inaudible when not held to the ear).
                try session.overrideOutputAudioPort(.none)
                if !hasBluetoothOutput(session) {
                    try session.overrideOutputAudioPort(.speaker)
                }
            case .phoneSpeaker:
                try session.overrideOutputAudioPort(.speaker)
            }
        } catch {
            NSLog("[Call] Audio route override (%@) error: %@", route.label, error.localizedDescription)
        }

        NSLog("[Call] Audio route → %@ (outputs: %@)", route.label,
              session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ","))
    }

    private func hasBluetoothOutput(_ session: AVAudioSession) -> Bool {
        session.currentRoute.outputs.contains { output in
            switch output.portType {
            case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE: return true
            default: return false
            }
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - WebRTCClientDelegate

extension CallController: WebRTCClientDelegate {
    nonisolated func webRTCClient(_ client: WebRTCClient, didChangeConnectionState state: RTCIceConnectionState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch state {
            case .connected, .completed:
                if self.state != .connected { self.state = .connected }
            case .failed:
                self.state = .failed("Connection failed")
            case .disconnected, .closed:
                if self.state == .connected { self.state = .ended }
            default:
                break
            }
        }
    }

    nonisolated func webRTCClient(_ client: WebRTCClient, didGenerateCandidate candidate: RTCIceCandidate) {
        Task { @MainActor [weak self] in
            self?.signaling.send(
                .candidate(
                    sdp: candidate.sdp,
                    sdpMid: candidate.sdpMid ?? "",
                    sdpMLineIndex: candidate.sdpMLineIndex
                )
            )
        }
    }

    nonisolated func webRTCClient(_ client: WebRTCClient, didReceiveRemoteVideoTrack track: RTCVideoTrack) {
        // The operator returned video — surface it for the overlay.
        Task { @MainActor [weak self] in self?.operatorWebRTCVideo = track }
    }
}
