import MWDATCore
import Sentry
import SwiftUI

@main
struct SaveVisionApp: App {
    @StateObject private var model: AppModel

    init() {
        // Start Sentry FIRST so crashes + the Wearables.configure() failure below
        // are reported to the self-hosted Bugsink ("rustrak"). DSN comes from the
        // gitignored Secrets.xcconfig; empty DSN disables reporting.
        let dsn = AppConfig.shared.sentryDSN
        if !dsn.isEmpty {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
            SentrySDK.start { options in
                options.dsn = dsn
                options.environment = AppConfig.shared.sentryEnvironment
                options.releaseName = "savevision@\(version)+\(build)"
                options.enableAutoSessionTracking = true
                options.attachStacktrace = true
                #if DEBUG
                options.debug = true
                #endif
            }
        }

        // Configure the Meta Wearables DAT SDK from the MWDAT dict in Info.plist
        // (ClientToken / MetaAppID / TeamID). Must happen before using Wearables.
        do {
            try Wearables.configure()
        } catch {
            NSLog("[SaveVision] Failed to configure Wearables SDK: \(error)")
            SentrySDK.capture(error: error)
        }
        _model = StateObject(wrappedValue: AppModel(wearables: Wearables.shared))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task {
                    if !model.didBootstrap { await model.bootstrap() }
                }
                .onOpenURL { url in
                    Task {
                        do {
                            _ = try await Wearables.shared.handleUrl(url)
                        } catch {
                            NSLog("[SaveVision] Wearables SDK failed to handle URL \(url): \(error)")
                            SentrySDK.capture(error: error)
                        }
                    }
                }
        }
    }
}
