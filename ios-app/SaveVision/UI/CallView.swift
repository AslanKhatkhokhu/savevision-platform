import LiveKit
import SwiftUI

/// Full-screen in-call UI: live POV preview (what the operator is seeing) plus
/// mute and hang-up controls. Starts the call on appear, ends it on dismiss.
struct CallView: View {
    @ObservedObject var call: CallController
    @ObservedObject var capture: StreamSessionManager
    @ObservedObject var overlay: DisplayOverlayManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Live point-of-view preview (what the operator sees).
            if let frame = capture.previewFrame {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text(capture.source == .glasses ? "Waiting for glasses video…" : "Starting camera…")
                        .foregroundStyle(.white)
                }
            }

            // Status + controls.
            VStack(spacing: 12) {
                statusBadge
                Spacer()
                textOverlay   // overlay 3: operator text guidance
                controls
            }
            .padding()
        }
        // overlay 1: operator video (top-left PiP)
        .overlay(alignment: .topLeading) {
            operatorVideo.padding(.top, 56).padding(.leading, 12)
        }
        // overlay 2: operator image / location (small, on the right)
        .overlay(alignment: .topTrailing) {
            rightMedia.padding(.top, 56).padding(.trailing, 12)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: overlay.latestText?.id)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: overlay.latestImage?.id)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: overlay.latestMap?.id)
        .task { await call.startCall() }
        .onChange(of: call.state) { _, newValue in
            if newValue == .ended { dismiss() }
        }
    }

    // MARK: Overlay 1 — operator video

    /// The operator's return video. Prefers the production MatrixRTC/LiveKit track;
    /// falls back to the SV1 WebRTC track. Shown as a small top-left PiP.
    @ViewBuilder
    private var operatorVideo: some View {
        if let lkTrack = call.operatorLiveKitVideo {
            operatorVideoCard { SwiftUIVideoView(lkTrack, layoutMode: .fill) }
        } else if let rtcTrack = call.operatorWebRTCVideo {
            operatorVideoCard { RTCVideoView(videoTrack: rtcTrack) }
        }
    }

    private func operatorVideoCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: 150, height: 100)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .topLeading) {
                Label("Operator", systemImage: "person.fill.viewfinder")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(.white)
                    .padding(6)
            }
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.cyan.opacity(0.6), lineWidth: 1))
            .transition(.move(edge: .leading).combined(with: .opacity))
    }

    // MARK: Overlay 2 — operator image / location (small, right)

    @ViewBuilder
    private var rightMedia: some View {
        VStack(spacing: 8) {
            if let image = overlay.latestImage {
                OverlayItemCard(item: image, compact: true, mediaMaxHeight: 80)
                    .frame(width: 140)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if let map = overlay.latestMap {
                OverlayItemCard(item: map, compact: false, mediaMaxHeight: 200)
                    .frame(width: 240)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    // MARK: Overlay 3 — operator text guidance

    @ViewBuilder
    private var textOverlay: some View {
        if let text = overlay.latestText {
            OverlayItemCard(item: text, compact: true)
                .frame(maxWidth: 300)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var statusBadge: some View {
        Text(statusText)
            .font(.caption.bold())
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(.white)
    }

    private var statusText: String {
        switch call.state {
        case .idle: return "Idle"
        case .connecting: return "Connecting to operator…"
        case .connected: return "● Live — operator is watching"
        case .failed(let message): return "Failed: \(message)"
        case .ended: return "Call ended"
        }
    }

    private var controls: some View {
        HStack(spacing: 32) {
            Button {
                call.toggleMute()
            } label: {
                controlIcon(call.isMuted ? "mic.slash.fill" : "mic.fill",
                            tint: call.isMuted ? .red : .white)
            }

            Button {
                call.toggleAudioRoute()
            } label: {
                VStack(spacing: 4) {
                    controlIcon(call.audioRoute.icon, tint: .white)
                    Text(call.audioRoute.label)
                        .font(.caption2)
                        .foregroundStyle(.white)
                }
            }
            .accessibilityLabel("Operator audio output: \(call.audioRoute.label)")

            Button {
                call.endCall()
            } label: {
                controlIcon("phone.down.fill", tint: .white, background: .red)
            }
        }
        .padding(.bottom, 24)
    }

    private func controlIcon(_ name: String, tint: Color, background: Color = .white.opacity(0.2)) -> some View {
        Image(systemName: name)
            .font(.title2)
            .foregroundStyle(tint)
            .frame(width: 64, height: 64)
            .background(background, in: Circle())
    }
}
