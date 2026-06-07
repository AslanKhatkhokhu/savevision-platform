// ContentView.swift
// Minimal user UI: start a session, show the room code to share with the
// operator, and surface the latest guidance pushed back from the operator.

import SwiftUI

struct ContentView: View {
    @StateObject private var session = StreamViewModel()

    var body: some View {
        VStack(spacing: 24) {
            Text("SaveVision")
                .font(.largeTitle).bold()
            Text("User")
                .foregroundStyle(.secondary)

            switch session.state {
            case .idle:
                Button("Start streaming") { session.start() }
                    .buttonStyle(.borderedProminent)

            case .connecting:
                ProgressView("Connecting…")

            case .live(let roomCode):
                VStack(spacing: 12) {
                    Text("Share this code with the operator")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(roomCode)
                        .font(.system(size: 44, weight: .heavy, design: .monospaced))
                        .tracking(6)
                    Label("Streaming", systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                    Button("Stop", role: .destructive) { session.stop() }
                }

            case .error(let message):
                VStack(spacing: 12) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Button("Retry") { session.start() }
                }
            }

            // Latest guidance from the operator (mirrors what shows on the glasses).
            if let guidance = session.latestGuidance {
                Divider()
                VStack(spacing: 6) {
                    Text("Operator guidance").font(.caption).foregroundStyle(.secondary)
                    Text(guidance).font(.title2).bold().multilineTextAlignment(.center)
                }
                .padding()
                .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding()
    }
}
