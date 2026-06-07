import SwiftUI

/// Capture source for the outgoing POV stream.
enum CaptureChoice: String, CaseIterable, Identifiable {
    case glasses
    case phone
    var id: String { rawValue }

    var label: String { self == .glasses ? "Smart glasses" : "Phone camera" }
    var icon: String { self == .glasses ? "eyeglasses" : "iphone" }
}

/// Main screen: a single, focused "call the operational centre" surface. Pick a
/// capture source, see glasses/display status at a glance, and place the call.
/// Everything configurable (operator target, pairing, chat, diagnostics, sign
/// out) lives behind the gear → `SettingsView`.
struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showCall = false
    @State private var showSettings = false
    @State private var showLiveMap = false
    @State private var source: CaptureChoice = .glasses

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                    sourcePicker
                        .padding(.top, 20)
                    previewCard
                        .padding(.top, 14)
                    statusCard
                        .padding(.top, 10)
                    matrixCard
                        .padding(.top, 10)

                    // Operator overlay content (text/image/map) belongs on the call
                    // screen and the glasses HUD — not the home screen.

                    Spacer(minLength: 12)
                    callButton
                    Spacer(minLength: 12)

                    footer
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showLiveMap = true } label: {
                        Image(systemName: "map.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Live map")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .sheet(isPresented: $showLiveMap) {
                LiveMapView()
            }
            .fullScreenCover(isPresented: $showCall) {
                if let call = model.callController {
                    CallView(call: call, capture: model.streamManager, overlay: model.overlayManager)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(model)
            }
            // Show the live feed immediately — don't make the wearer place a call
            // just to confirm the glasses are streaming.
            .task { await startPreview() }
            .onChange(of: source) { _, _ in
                Task { await startPreview() }
            }
            // Glasses can connect a moment after launch — start the feed the
            // instant a device becomes active, instead of failing once on appear.
            .onChange(of: model.streamManager.hasActiveDevice) { _, active in
                if active { Task { await startPreview() } }
            }
            .onChange(of: showCall) { _, presenting in
                guard !presenting else { return }
                // The call tears capture down on hang-up; let that async stop
                // settle, then bring the home preview back.
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await startPreview()
                }
            }
            // Surface Meta DAT registration errors (previously swallowed).
            .alert("Glasses pairing", isPresented: Binding(
                get: { model.wearablesManager.showError },
                set: { if !$0 { model.wearablesManager.dismissError() } }
            )) {
                Button("OK") { model.wearablesManager.dismissError() }
            } message: {
                Text(model.wearablesManager.errorMessage)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 6) {
            (Text("Save").foregroundStyle(.white) + Text("Vision").foregroundStyle(Color.svAccent))
                .font(.largeTitle.bold())
            Text("Reach a medic who sees through your glasses")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    // MARK: Capture source

    private var sourcePicker: some View {
        Picker("Capture source", selection: $source) {
            ForEach(CaptureChoice.allCases) { choice in
                Label(choice.label, systemImage: choice.icon).tag(choice)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: Live preview

    /// The local camera feed (glasses via DAT SDK, or the iPhone). This is purely
    /// local — it does not depend on the operator, WebRTC, or any SDP answer — so
    /// it shows the moment the first frame arrives.
    private var previewCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06))

            if let frame = model.streamManager.previewFrame {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                VStack {
                    HStack {
                        Spacer()
                        Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption2.bold())
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.red, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Spacer()
                }
                .padding(10)
            } else if model.streamManager.showError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text(model.streamManager.errorMessage)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text("Tap to retry")
                        .font(.caption2.bold())
                        .foregroundStyle(Color.svAccent)
                }
                .padding(.horizontal, 16)
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text(source == .glasses ? "Waiting for glasses video…" : "Starting camera…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Tap to retry")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture {
            Task {
                model.streamManager.dismissError()
                await startPreview()
            }
        }
    }

    // MARK: Ray-Ban Display status

    private var statusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "eyeglasses")
                .font(.title3)
                .foregroundStyle(statusDotColor == .green ? Color.svAccent : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ray-Ban Display")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(statusDotColor == .green ? Color.svAccent : .secondary)
            }
            Spacer()
            Circle()
                .fill(statusDotColor)
                .frame(width: 10, height: 10)
        }
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    private var statusDetail: String {
        if source == .phone { return "Phone camera selected" }
        // "Connected" means a device is *actively* available for a camera session,
        // not merely paired — otherwise we'd claim ready while the SDK reports
        // "No eligible device available".
        if model.streamManager.hasActiveDevice { return "Connected · ready" }
        if model.wearablesManager.isRegistered { return "Paired · glasses not connected" }
        return "Not paired — open Settings"
    }

    private var statusDotColor: Color {
        if source == .phone { return .secondary }
        if model.streamManager.hasActiveDevice { return .green }
        if model.wearablesManager.isRegistered { return .orange }
        return .secondary
    }

    // MARK: Matrix server status

    /// Whether the app reached the Matrix homeserver and opened the operator room.
    /// Reaching this screen at all means the client is signed in and syncing; this
    /// card adds the live room/signaling readiness on top of that.
    private var matrixCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title3)
                .foregroundStyle(matrixDotColor == .green ? Color.svAccent : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Matrix server")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(matrixDetail)
                    .font(.caption)
                    .foregroundStyle(matrixDotColor == .red ? .red : .secondary)
            }
            Spacer()
            Circle()
                .fill(matrixDotColor)
                .frame(width: 10, height: 10)
        }
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    private var matrixHost: String {
        URL(string: AppConfig.shared.homeserverURL)?.host ?? AppConfig.shared.homeserverURL
    }

    private var matrixDetail: String {
        if let error = model.roomManager?.errorMessage { return error }
        let who = model.clientManager.userID ?? "signed in"
        if model.roomManager?.isReady == true {
            return "\(matrixHost) · operator room ready\n\(who)"
        }
        return "\(matrixHost) · opening operator room…\n\(who)"
    }

    private var matrixDotColor: Color {
        if model.roomManager?.errorMessage != nil { return .red }
        return model.roomManager?.isReady == true ? .green : .orange
    }

    // MARK: Call

    private var callButton: some View {
        Button {
            model.callController?.useIPhoneCamera = (source == .phone)
            showCall = true
        } label: {
            VStack(spacing: 4) {
                Text("CALL")
                    .font(.system(size: 34, weight: .heavy))
                Text("operational centre")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(.white)
            .frame(width: 200, height: 200)
            .background(
                RadialGradient(
                    colors: [Color(red: 1.0, green: 0.42, blue: 0.42), Color(red: 0.90, green: 0.20, blue: 0.22)],
                    center: .center, startRadius: 8, endRadius: 140
                ),
                in: Circle()
            )
            .shadow(color: Color.red.opacity(0.35), radius: 24, y: 8)
            .opacity(canCall ? 1 : 0.4)
        }
        .disabled(!canCall)
        .accessibilityLabel("Call operational centre")
    }

    /// The wearer can place the call as soon as the operator room is open. Glasses
    /// video links during the call ("Waiting for glasses video…"), so we don't
    /// gate the call on hardware being online.
    private var canCall: Bool { model.roomManager?.isReady == true }

    // MARK: Footer

    private var footer: some View {
        Text(footerText)
            .font(.footnote)
            .foregroundStyle(footerIsError ? .red : .secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
    }

    private var footerIsError: Bool { model.roomManager?.errorMessage != nil }

    private var footerText: String {
        if let error = model.roomManager?.errorMessage { return error }
        if canCall {
            return "One tap connects you to triage. Your live view links automatically once a medic answers."
        }
        return "Connecting to the operator room…"
    }

    // MARK: Preview lifecycle

    /// Start (or restart) the local preview for the selected source. Skips while a
    /// call is on screen — `CallController` owns capture during the call.
    private func startPreview() async {
        guard !showCall else { return }
        let capture = model.streamManager
        switch source {
        case .glasses:
            // Only attempt the camera when a device is actually connected — calling
            // startGlasses() with no active device just throws "No eligible device
            // available". The .onChange(hasActiveDevice) below auto-starts the
            // moment the glasses truly connect.
            guard capture.hasActiveDevice else {
                NSLog("[Capture] startPreview skipped — no active glasses device yet")
                return
            }
            // Switching back from the phone camera can leave a stale (SDK-stopped)
            // glasses session cached — a stopped DAT session can't be restarted, so
            // force a fresh one when we're coming off the phone.
            let switchingFromPhone = (capture.source == .iPhone)
            if switchingFromPhone, capture.isCapturing { await capture.stop() }
            await capture.startGlasses(forceNewSession: switchingFromPhone)
        case .phone:
            if capture.source == .glasses, capture.isCapturing { await capture.stop() }
            await capture.startIPhone()
        }
    }
}

extension Color {
    /// SaveVision brand accent (mint/green).
    static let svAccent = Color(red: 0.20, green: 0.84, blue: 0.66)
}
