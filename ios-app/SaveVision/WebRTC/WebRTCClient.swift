import Foundation
import WebRTC

protocol WebRTCClientDelegate: AnyObject {
    func webRTCClient(_ client: WebRTCClient, didChangeConnectionState state: RTCIceConnectionState)
    func webRTCClient(_ client: WebRTCClient, didGenerateCandidate candidate: RTCIceCandidate)
    func webRTCClient(_ client: WebRTCClient, didReceiveRemoteVideoTrack track: RTCVideoTrack)
}

/// Manages the `RTCPeerConnection`, local video/audio tracks, and SDP
/// negotiation. Local video is fed by a `CustomVideoCapturer` (glasses / iPhone
/// frames). Local audio uses WebRTC's native engine (mic capture + AEC +
/// playback) over the iOS audio session — so when the Ray-Ban glasses are the
/// active Bluetooth route, their mic is used automatically.
///
/// SaveVision's iOS app is always the WebRTC **offerer** (the wearer/publisher,
/// per ../PROTOCOL.md). The operator answers.
final class WebRTCClient: NSObject {
    weak var delegate: WebRTCClientDelegate?

    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var videoSource: RTCVideoSource!
    private var videoCapturer: CustomVideoCapturer!
    private var localVideoTrack: RTCVideoTrack?
    private var localAudioTrack: RTCAudioTrack?
    private var videoSender: RTCRtpSender?
    private(set) var remoteVideoTrack: RTCVideoTrack?

    /// Remote ICE candidates that arrived before the remote description was set.
    /// WebRTC rejects `add(candidate:)` with "the remote description was null"
    /// until `setRemoteDescription` lands, and rejected candidates are dropped —
    /// so we buffer them here and flush once the answer is applied.
    private var pendingRemoteCandidates: [RTCIceCandidate] = []
    private var hasRemoteDescription = false
    private let candidateLock = NSLock()

    override init() {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory
        )
        super.init()
    }

    func setup(iceServers: [RTCIceServer]) {
        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )

        peerConnection = factory.peerConnection(
            with: config, constraints: constraints, delegate: self
        )

        createMediaTracks()
    }

    private func createMediaTracks() {
        // Video — custom source fed by DAT SDK / iPhone frames.
        videoSource = factory.videoSource()
        videoCapturer = CustomVideoCapturer(delegate: videoSource)
        localVideoTrack = factory.videoTrack(with: videoSource, trackId: "video0")
        localVideoTrack?.isEnabled = true
        videoSender = peerConnection?.add(localVideoTrack!, streamIds: ["stream0"])

        // Audio — WebRTC native engine over the iOS audio session.
        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = factory.audioSource(with: audioConstraints)
        localAudioTrack = factory.audioTrack(with: audioSource, trackId: "audio0")
        localAudioTrack?.isEnabled = true
        peerConnection?.add(localAudioTrack!, streamIds: ["stream0"])

        applyMaxBitrate()
    }

    /// Cap outgoing video bitrate for thin links.
    private func applyMaxBitrate() {
        guard let sender = videoSender else { return }
        let params = sender.parameters
        for encoding in params.encodings {
            encoding.maxBitrateBps = NSNumber(value: WebRTCConfig.maxBitrateBps)
            encoding.maxFramerate = NSNumber(value: WebRTCConfig.maxFramerate)
        }
        sender.parameters = params
    }

    /// Push a video frame from the active camera source.
    func pushVideoFrame(_ image: UIImage) {
        videoCapturer?.pushFrame(image)
    }

    // MARK: - SDP negotiation

    func createOffer(completion: @escaping (RTCSessionDescription) -> Void) {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                // Receive the operator's return video (shown in the overlay).
                "OfferToReceiveVideo": "true"
            ],
            optionalConstraints: nil
        )
        peerConnection?.offer(for: constraints) { [weak self] sdp, error in
            guard let sdp else {
                NSLog("[WebRTC] Failed to create offer: %@", error?.localizedDescription ?? "unknown")
                return
            }
            self?.peerConnection?.setLocalDescription(sdp) { error in
                if let error {
                    NSLog("[WebRTC] Failed to set local description: %@", error.localizedDescription)
                } else {
                    completion(sdp)
                }
            }
        }
    }

    func set(remoteSdp: RTCSessionDescription, completion: @escaping (Error?) -> Void) {
        peerConnection?.setRemoteDescription(remoteSdp) { [weak self] error in
            if error == nil {
                NSLog("[WebRTC] Remote description set; flushing buffered ICE candidates")
                self?.flushPendingCandidates()
            }
            completion(error)
        }
    }

    func add(remoteCandidate: RTCIceCandidate, completion: @escaping (Error?) -> Void) {
        candidateLock.lock()
        if !hasRemoteDescription {
            pendingRemoteCandidates.append(remoteCandidate)
            candidateLock.unlock()
            // Not an error — the candidate is queued until the answer lands.
            completion(nil)
            return
        }
        candidateLock.unlock()
        peerConnection?.add(remoteCandidate, completionHandler: completion)
    }

    /// Mark the remote description as present and add any buffered candidates.
    private func flushPendingCandidates() {
        candidateLock.lock()
        hasRemoteDescription = true
        let pending = pendingRemoteCandidates
        pendingRemoteCandidates.removeAll()
        candidateLock.unlock()

        if !pending.isEmpty {
            NSLog("[WebRTC] Adding %d buffered ICE candidate(s)", pending.count)
        }
        for candidate in pending {
            peerConnection?.add(candidate) { error in
                if let error {
                    NSLog("[WebRTC] Failed to add buffered candidate: %@", error.localizedDescription)
                }
            }
        }
    }

    func muteAudio(_ mute: Bool) {
        localAudioTrack?.isEnabled = !mute
    }

    func close() {
        localVideoTrack?.isEnabled = false
        localAudioTrack?.isEnabled = false
        remoteVideoTrack = nil
        candidateLock.lock()
        pendingRemoteCandidates.removeAll()
        hasRemoteDescription = false
        candidateLock.unlock()
        peerConnection?.close()
        peerConnection = nil
        NSLog("[WebRTC] Peer connection closed")
    }

    deinit {
        RTCCleanupSSL()
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCClient: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        NSLog("[WebRTC] ICE connection state: %d", newState.rawValue)
        delegate?.webRTCClient(self, didChangeConnectionState: newState)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        delegate?.webRTCClient(self, didGenerateCandidate: candidate)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if let videoTrack = stream.videoTracks.first {
            remoteVideoTrack = videoTrack
            delegate?.webRTCClient(self, didReceiveRemoteVideoTrack: videoTrack)
        }
    }

    // Unified Plan surfaces inbound media here (the `didAdd stream:` Plan-B
    // callback doesn't always fire) — this is how we get the operator's video.
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        guard let videoTrack = rtpReceiver.track as? RTCVideoTrack else { return }
        remoteVideoTrack = videoTrack
        delegate?.webRTCClient(self, didReceiveRemoteVideoTrack: videoTrack)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
