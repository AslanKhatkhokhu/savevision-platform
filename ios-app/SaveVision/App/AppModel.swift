import Combine
import CoreLocation
import MWDATCore
import SwiftUI

/// Top-level app state. Owns the Matrix client, the glasses managers, and — once
/// signed in — the per-session room/signaling/call objects.
@MainActor
final class AppModel: ObservableObject {
    let clientManager = MatrixClientManager()
    let wearablesManager: WearablesManager
    let streamManager: StreamSessionManager
    let overlayManager: DisplayOverlayManager
    let locationManager = LocationManager()

    @Published var roomManager: MatrixRoomManager?
    @Published var matrixRTCSession: MatrixRTCSessionManager?
    @Published var callController: CallController?
    @Published var didBootstrap = false

    private let wearables: WearablesInterface
    private var signaling: MatrixSignaling?
    private var cancellables = Set<AnyCancellable>()

    init(wearables: WearablesInterface) {
        self.wearables = wearables
        self.wearablesManager = WearablesManager(wearables: wearables)
        self.streamManager = StreamSessionManager(wearables: wearables)
        self.overlayManager = DisplayOverlayManager(renderer: streamManager)

        // Forward nested managers' changes so views observing AppModel re-render
        // on connection-state, pairing, and capture transitions.
        forward(clientManager.objectWillChange)
        forward(wearablesManager.objectWillChange)
        forward(streamManager.objectWillChange)
        forward(overlayManager.objectWillChange)
        forward(locationManager.objectWillChange)

        // Share each new GPS fix with the operator (only while a call is live).
        locationManager.onUpdate = { [weak self] location in self?.shareLocation(location) }
    }

    private func forward(_ publisher: ObservableObjectPublisher) {
        publisher
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Called once on launch — try to restore a saved Matrix session.
    func bootstrap() async {
        await clientManager.restoreIfPossible()
        if clientManager.state == .ready { await setupSession() }
        didBootstrap = true
    }

    func login(homeserverURL: String, username: String, password: String) async {
        await clientManager.login(homeserverURL: homeserverURL, username: username, password: password)
        if clientManager.state == .ready { await setupSession() }
    }

    func logout() async {
        callController?.endCall()
        await clientManager.logout()
        roomManager = nil
        matrixRTCSession = nil
        callController = nil
        signaling = nil
        overlayManager.clear()
    }

    private func setupSession() async {
        guard let client = clientManager.client else { return }
        let room = MatrixRoomManager(client: client)
        let signaling = MatrixSignaling(room: room)
        let matrixRTC = MatrixRTCSessionManager(client: client, roomManager: room, capture: streamManager)
        let call = CallController(signaling: signaling, capture: streamManager, matrixRTC: matrixRTC)
        room.onChatMessage = { [weak self] message in self?.overlayManager.ingest(chatMessage: message) }
        room.onHUDPayload = { [weak self] payload in self?.overlayManager.ingest(payload: payload) }

        self.roomManager = room
        self.matrixRTCSession = matrixRTC
        self.signaling = signaling
        self.callController = call

        forward(room.objectWillChange)
        forward(matrixRTC.objectWillChange)
        forward(call.objectWillChange)

        // Start/stop location sharing with the call lifecycle.
        call.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .connected:
                    self.locationManager.start()
                    if let location = self.locationManager.current { self.shareLocation(location) }
                case .ended, .idle, .failed:
                    self.locationManager.stop()
                case .connecting:
                    self.locationManager.start() // warm up GPS so we have a fix by connect
                }
            }
            .store(in: &cancellables)

        await room.openOperatorRoom()
    }

    /// Send the wearer's position to the operator over the Matrix room. Sent only
    /// while a call is connected; formatted to be both human-readable in the
    /// operator console and machine-parseable (`geo:` + map link).
    private func shareLocation(_ location: CLLocation) {
        guard callController?.state == .connected, let room = roomManager else { return }
        let lat = location.coordinate.latitude
        let lng = location.coordinate.longitude
        let accuracy = max(0, Int(location.horizontalAccuracy))
        let body = String(
            format: "📍 Wearer location: %.5f, %.5f (±%dm)\ngeo:%.6f,%.6f\nhttps://www.openstreetmap.org/?mlat=%.5f&mlon=%.5f#map=18/%.5f/%.5f",
            lat, lng, accuracy, lat, lng, lat, lng, lat, lng
        )
        room.sendText(body)
    }

    /// Reconnect to a different Matrix user (pass empty to clear the override and
    /// return to the configured operator). Re-resolves the session
    /// room/signaling/call against the new target so you can repoint the
    /// connection at any identity at runtime — no Secrets.xcconfig edit or
    /// rebuild needed. Set from Settings.
    func reconnectToTarget(_ userID: String) async {
        OperatorOverride.userID = userID
        callController?.endCall()
        guard clientManager.state == .ready else { return }
        await setupSession()
    }
}
