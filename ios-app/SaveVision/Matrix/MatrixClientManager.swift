import Foundation
import MatrixRustSDK

/// Owns the matrix-rust-sdk `Client`: builds it, logs in, persists/restores the
/// session, and starts the sync service. Everything that touches the Rust FFI
/// lives here (and in `MatrixRoomManager`) so the rest of the app stays
/// transport-clean.
///
/// ───────────────────────────────────────────────────────────────────────────
/// VERSION NOTE: this targets `matrix-rust-components-swift` 26.06.03. The FFI's
/// exact async signatures can shift between releases. Lines marked `VERIFY:`
/// should be checked against the generated interface that appears in Xcode after
/// SwiftPM resolves the package (⌘-click the symbol). They are written to the
/// 26.x API as best understood.
/// ───────────────────────────────────────────────────────────────────────────
@MainActor
final class MatrixClientManager: ObservableObject {
    @Published private(set) var state: MatrixConnectionState = .signedOut

    private(set) var client: Client?
    private var syncService: SyncService?

    /// Signed-in Matrix user id, when a client exists (for the diagnostics UI).
    var userID: String? { try? client?.userId() }

    private let fileManager = FileManager.default

    // MARK: Paths

    private var baseDirectory: URL {
        let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SaveVision", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private var sessionDataPath: URL { baseDirectory.appendingPathComponent("session", isDirectory: true) }
    private var sessionCachePath: URL { baseDirectory.appendingPathComponent("cache", isDirectory: true) }
    private var sessionFile: URL { baseDirectory.appendingPathComponent("session.json") }

    // MARK: - Restore on launch

    /// Attempt to restore a saved session. Returns true if signed in.
    @discardableResult
    func restoreIfPossible() async -> Bool {
        guard let stored = loadStoredSession() else { return false }
        state = .connecting
        do {
            let client = try await buildClient(homeserverURL: stored.homeserverUrl)
            try await client.restoreSession(session: stored.toSDKSession())
            self.client = client
            try await startSync()
            state = .ready
            return true
        } catch {
            NSLog("[Matrix] Restore failed: %@", error.localizedDescription)
            // A failed restore can leave a stale/mismatched crypto store behind;
            // wipe it so the next explicit login starts from a clean slate.
            wipeSessionStore()
            state = .signedOut
            return false
        }
    }

    // MARK: - Login

    func login(homeserverURL: String, username: String, password: String) async {
        state = .connecting
        // The rust-SDK crypto store is bound to a single account. A fresh login may
        // target a different user than the one whose store is on disk (e.g. after
        // switching accounts), which fails with "MismatchedAccount". Starting a new
        // login means starting a new session, so clear any prior store first.
        wipeSessionStore()
        do {
            let client = try await buildClient(homeserverURL: homeserverURL)
            // VERIFY: login(username:password:initialDeviceName:deviceId:)
            try await client.login(
                username: username,
                password: password,
                initialDeviceName: "SaveVision",
                deviceId: nil
            )
            self.client = client
            try persistSession(from: client)
            try await startSync()
            state = .ready
        } catch {
            NSLog("[Matrix] Login failed: %@", error.localizedDescription)
            state = .error(friendly(error))
        }
    }

    func logout() async {
        try? await client?.logout()
        syncService = nil
        client = nil
        // Remove the session JSON *and* the crypto/cache store, so the next login
        // (possibly a different account) doesn't collide with this one's store.
        wipeSessionStore()
        state = .signedOut
    }

    // MARK: - Client build + sync

    private func buildClient(homeserverURL: String) async throws -> Client {
        try fileManager.createDirectory(at: sessionDataPath, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sessionCachePath, withIntermediateDirectories: true)

        // `.serverNameOrHomeserverUrl` accepts a server name or a full URL.
        // `.slidingSyncVersionBuilder(.discoverNative)` is REQUIRED — without it
        // the sync service fails with "Sliding sync version is missing". It
        // queries the homeserver and uses native sliding sync (MSC4186) when
        // supported (modern Synapse). Use `.native` to force it.
        return try await ClientBuilder()
            .sessionPaths(dataPath: sessionDataPath.path, cachePath: sessionCachePath.path)
            .serverNameOrHomeserverUrl(serverNameOrUrl: homeserverURL)
            .slidingSyncVersionBuilder(versionBuilder: .discoverNative)
            .build()
    }

    private func startSync() async throws {
        guard let client else { return }
        state = .syncing
        let service = try await client.syncService().finish()
        await service.start()
        self.syncService = service
    }

    // MARK: - Session persistence

    private func persistSession(from client: Client) throws {
        // VERIFY: client.session() returns the FFI `Session` struct.
        let session = try client.session()
        let stored = StoredSession(session)
        let data = try JSONEncoder().encode(stored)
        try data.write(to: sessionFile, options: .completeFileProtection)
    }

    private func loadStoredSession() -> StoredSession? {
        guard let data = try? Data(contentsOf: sessionFile) else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    private func clearStoredSession() {
        try? fileManager.removeItem(at: sessionFile)
    }

    /// Remove the persisted session JSON *and* the on-disk crypto/cache stores.
    /// Required when switching accounts: the rust-SDK store is account-bound and
    /// reusing it for a different user throws `MismatchedAccount`.
    private func wipeSessionStore() {
        try? fileManager.removeItem(at: sessionFile)
        try? fileManager.removeItem(at: sessionDataPath)
        try? fileManager.removeItem(at: sessionCachePath)
    }

    private func friendly(_ error: Error) -> String {
        "Couldn't sign in. Check the homeserver URL and credentials.\n(\(error.localizedDescription))"
    }
}

// MARK: - Codable mirror of the FFI Session

/// The FFI `Session` struct isn't `Codable`, so we mirror its fields. If a field
/// name differs in your pinned SDK version, adjust here (and in the two
/// converters). `slidingSyncVersion` is reconstructed as `.native`, which is
/// correct for modern homeservers (Synapse with native sliding sync).
private struct StoredSession: Codable {
    let accessToken: String
    let refreshToken: String?
    let userId: String
    let deviceId: String
    let homeserverUrl: String
    let oauthData: String?

    init(_ session: Session) {
        self.accessToken = session.accessToken
        self.refreshToken = session.refreshToken
        self.userId = session.userId
        self.deviceId = session.deviceId
        self.homeserverUrl = session.homeserverUrl
        self.oauthData = session.oauthData
    }

    func toSDKSession() -> Session {
        Session(
            accessToken: accessToken,
            refreshToken: refreshToken,
            userId: userId,
            deviceId: deviceId,
            homeserverUrl: homeserverUrl,
            oauthData: oauthData,
            slidingSyncVersion: .native
        )
    }
}
