import MWDATCore
import Sentry
import SwiftUI

#if canImport(MWDATMockDevice)
import MWDATMockDevice
#endif

/// Owns the Meta Wearables DAT SDK device lifecycle: registration (pairing via
/// the Meta AI app) and the stream of connected devices. Adapted from
/// stoz3n-vision-agent's `WearablesViewModel`.
@MainActor
final class WearablesManager: ObservableObject {
    @Published var devices: [DeviceIdentifier] = []
    @Published var hasMockDevice: Bool = false
    @Published var registrationState: RegistrationState
    @Published var showError: Bool = false
    @Published var errorMessage: String = ""

    var isRegistered: Bool { registrationState == .registered }
    var hasDevice: Bool { !devices.isEmpty || hasMockDevice }

    let wearables: WearablesInterface

    private var registrationTask: Task<Void, Never>?
    private var deviceStreamTask: Task<Void, Never>?

    init(wearables: WearablesInterface) {
        self.wearables = wearables
        self.devices = wearables.devices
        self.registrationState = wearables.registrationState

        deviceStreamTask = Task { [weak self] in
            guard let self else { return }
            for await devices in wearables.devicesStream() {
                self.devices = devices
                #if canImport(MWDATMockDevice)
                self.hasMockDevice = !MockDeviceKit.shared.pairedDevices.isEmpty
                #endif
            }
        }

        registrationTask = Task { [weak self] in
            guard let self else { return }
            for await state in wearables.registrationStateStream() {
                self.registrationState = state
            }
        }
    }

    deinit {
        registrationTask?.cancel()
        deviceStreamTask?.cancel()
    }

    /// Begin pairing — deep-links into the Meta AI app for the user to approve.
    func connectGlasses() {
        guard registrationState != .registering else { return }
        Task { @MainActor in
            do {
                try await wearables.startRegistration()
            } catch let error as RegistrationError {
                report(error, description: error.description)
            } catch {
                report(error, description: error.localizedDescription)
            }
        }
    }

    func disconnectGlasses() {
        Task { @MainActor in
            do {
                try await wearables.startUnregistration()
            } catch let error as UnregistrationError {
                show(error.description)
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    private func show(_ message: String) {
        errorMessage = message
        showError = true
    }

    /// Show the error to the user AND report it to Sentry/rustrak with context,
    /// so glasses-pairing failures are diagnosable off-device.
    private func report(_ error: Error, description: String) {
        show(description)
        SentrySDK.capture(error: error) { scope in
            scope.setTag(value: "glasses_pairing", key: "phase")
            scope.setContext(value: [
                "registrationState": String(describing: self.registrationState),
                "deviceCount": self.devices.count,
                "description": description
            ], key: "wearables")
        }
    }

    func dismissError() { showError = false }
}
