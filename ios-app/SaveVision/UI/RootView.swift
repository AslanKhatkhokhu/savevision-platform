import SwiftUI

/// Routes between login and the signed-in home screen based on the Matrix
/// connection state. AppModel forwards its nested client manager's changes, so
/// observing AppModel alone is enough to re-render on state transitions.
struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch model.clientManager.state {
        case .signedOut, .error:
            LoginView()
        case .connecting:
            ProgressView("Connecting…").controlSize(.large)
        case .syncing:
            ProgressView("Syncing…").controlSize(.large)
        case .ready:
            HomeView()
        }
    }
}
