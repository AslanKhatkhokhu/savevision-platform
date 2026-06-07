import SwiftUI

/// All configuration and diagnostics, moved off the main screen. Lets the wearer
/// repoint the connection target, pair glasses, open the operator chat, inspect
/// DAT/display state, and sign out.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var targetUserID = OperatorOverride.userID ?? ""
    @AppStorage(DisplaySettings.key) private var displayEnabled = true

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                glassesSection
                accountSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Connection / operator target

    @ViewBuilder private var connectionSection: some View {
        Section {
            if let room = model.roomManager {
                NavigationLink {
                    ChatView(room: room)
                } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Chat with operator")
                            Text(room.isReady ? "Connected" : "Opening room…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                    }
                }
                .disabled(!room.isReady)
            } else {
                ProgressView("Connecting to operator…")
            }
        } header: {
            Text("Operator")
        }

        Section {
            TextField("@user:homeserver", text: $targetUserID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.callout.monospaced())

            HStack {
                Button("Connect") {
                    Task { await model.reconnectToTarget(targetUserID) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(targetUserID.trimmingCharacters(in: .whitespaces).isEmpty)

                Spacer()

                Button("Reset to default", role: .destructive) {
                    targetUserID = ""
                    Task { await model.reconnectToTarget("") }
                }
            }

            if let active = OperatorOverride.userID {
                Text("Target → \(active)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            } else {
                Text("Calling the configured operator (\(AppConfig.shared.operatorUserID)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Connection target")
        } footer: {
            Text("Repoint the call at any Matrix user. A fresh 1:1 DM is opened with that account; the pinned operator room is ignored while an override is set.")
        }
    }

    // MARK: Glasses

    @ViewBuilder private var glassesSection: some View {
        Section("Glasses") {
            HStack {
                Image(systemName: "eyeglasses")
                    .foregroundStyle(model.wearablesManager.hasDevice ? .green : .secondary)
                VStack(alignment: .leading) {
                    Text(glassesStatusText)
                    Text(model.wearablesManager.isRegistered ? "Paired with Meta account" : "Not paired")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !model.wearablesManager.isRegistered {
                    Button("Pair") { model.wearablesManager.connectGlasses() }
                        .buttonStyle(.bordered)
                }
            }

            Toggle(isOn: $displayEnabled) {
                Label {
                    VStack(alignment: .leading) {
                        Text("Ray-Ban Display (HUD)")
                        Text(displayEnabled
                             ? "Operator guidance renders on the lens"
                             : "Off — camera stream only, no HUD")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "display")
                }
            }

            NavigationLink {
                DisplayOverlayDebugView(overlay: model.overlayManager)
            } label: {
                Label {
                    VStack(alignment: .leading) {
                        Text("Virtual display overlay")
                        Text(model.overlayManager.latest?.body ?? "Mirrors HUD messages/images/locations")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } icon: {
                    Image(systemName: "rectangle.inset.filled.and.person.filled")
                }
            }

            // Diagnostic readout (DAT registration state + visible devices).
            Text("DAT: \(String(describing: model.wearablesManager.registrationState)) · devices: \(model.wearablesManager.devices.count)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text(model.overlayManager.displayStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var glassesStatusText: String {
        if model.wearablesManager.hasDevice { return "Glasses connected" }
        if model.wearablesManager.isRegistered { return "Paired — glasses offline" }
        return "No glasses"
    }

    // MARK: Account

    @ViewBuilder private var accountSection: some View {
        Section {
            Button("Sign out", role: .destructive) {
                Task {
                    await model.logout()
                    dismiss()
                }
            }
        }
    }
}
