import Foundation

/// Runtime configuration for SaveVision.
///
/// Real values are NOT committed: they live in the gitignored
/// `SaveVision/Secrets.xcconfig`, are injected into Info.plist as build settings
/// (`$(SAVEVISION_*)`), and read back here at launch. Without a Secrets.xcconfig
/// the placeholder fallbacks below are used. Copy `Secrets.example.xcconfig` →
/// `Secrets.xcconfig` and fill it in (see README).
struct AppConfig {

    // MARK: Matrix homeserver

    /// Full homeserver base URL, e.g. "https://matrix.your-domain".
    let homeserverURL: String

    /// The operator (doctor) MXID, e.g. "@operator:your-domain".
    let operatorUserID: String

    /// Pinned operator room id. If non-empty it takes precedence over resolving
    /// a DM by `operatorUserID`.
    let operatorRoomID: String

    // MARK: WebRTC / TURN

    let stunServers: [String] = [
        "stun:stun.l.google.com:19302",
        "stun:stun1.l.google.com:19302"
    ]

    /// coturn host (e.g. "turn.your-domain") + its static-auth-secret.
    /// When both are set, `WebRTCConfig` mints time-limited TURN credentials
    /// (coturn REST / `use-auth-secret`). Essential for thin/field networks.
    let turnHost: String
    let turnSecret: String

    let maxVideoBitrateBps: Int = 1_500_000

    // MARK: Error reporting (Sentry → self-hosted Bugsink "rustrak")

    /// Sentry/Bugsink ingest DSN, e.g. "https://<key>@ingest.rustrak.example.io/<project>".
    /// Empty disables Sentry. The SDK reports crashes + captured errors here so
    /// they're diagnosable via ojiichan's Bugsink backend.
    let sentryDSN: String

    /// Sentry environment tag (development / staging / production).
    let sentryEnvironment: String

    // MARK: SaveVision wire contract (see ../PROTOCOL.md, ../MATRIX.md)

    /// Event-type / marker prefix for SaveVision payloads carried over Matrix.
    let eventPrefix: String = "org.savevision"

    // MARK: Load from Info.plist (injected from Secrets.xcconfig)

    init() {
        let info = Bundle.main.object(forInfoDictionaryKey: "SaveVisionConfig") as? [String: String] ?? [:]
        func value(_ key: String) -> String? {
            guard let v = info[key], !v.isEmpty else { return nil }
            return v
        }

        let host = value("HomeserverHost") ?? "matrix.YOUR-DOMAIN"
        self.homeserverURL = "https://\(host)"

        // Default connection target. To call a *different* user at runtime (e.g. a
        // test account), use the Settings → Connection target chooser, which sets
        // OperatorOverride and takes precedence over these in all builds.
        self.operatorUserID = value("OperatorUserID") ?? "@operator:YOUR-DOMAIN"
        self.operatorRoomID = value("OperatorRoomID") ?? ""
        self.turnHost = value("TurnHost") ?? ""
        self.turnSecret = value("TurnSecret") ?? ""
        // DSN is stored scheme-less in xcconfig ('//' starts a comment there);
        // re-add https:// here.
        if let raw = value("SentryDSN") {
            self.sentryDSN = raw.hasPrefix("http") ? raw : "https://\(raw)"
        } else {
            self.sentryDSN = ""
        }
        #if DEBUG
        self.sentryEnvironment = value("SentryEnvironment") ?? "development"
        #else
        self.sentryEnvironment = value("SentryEnvironment") ?? "production"
        #endif
    }

    static let shared = AppConfig()

    var isConfigured: Bool { !homeserverURL.contains("YOUR-DOMAIN") }
}

/// Runtime override for the connection-target Matrix user, set from Settings.
///
/// When present, the app connects to this Matrix user (resolving/creating a
/// fresh 1:1 DM) instead of `AppConfig.operatorUserID` — letting you repoint the
/// target at any identity (e.g. `@budelius:matrix.example.org`) at runtime,
/// without editing Secrets.xcconfig or rebuilding. Persisted in `UserDefaults`;
/// cleared by passing an empty value. Available in all builds.
/// Whether the app drives the Ray-Ban **Display** (HUD) capability. Disabling it
/// keeps the DAT device session for the camera stream only — useful on glasses
/// where the display capability isn't wanted or interferes. Persisted in
/// UserDefaults; defaults to ON. Toggled from Settings.
enum DisplaySettings {
    static let key = "savevision.display.enabled"

    static var enabled: Bool {
        // Absent key ⇒ default ON (preserve prior behaviour).
        UserDefaults.standard.object(forKey: key) == nil
            ? true
            : UserDefaults.standard.bool(forKey: key)
    }
}

enum OperatorOverride {
    private static let key = "savevision.operator.targetUserID"

    static var userID: String? {
        get {
            let v = UserDefaults.standard.string(forKey: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (v?.isEmpty == false) ? v : nil
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                UserDefaults.standard.set(trimmed, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
