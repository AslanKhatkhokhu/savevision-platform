import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var model: AppModel

    @State private var homeserver = AppConfig.shared.homeserverURL
    @State private var username = ""
    @State private var password = ""
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("SaveVision")
                        .font(.largeTitle.bold())
                    Text("Sign in to your Matrix homeserver to reach the operator.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Homeserver") {
                    TextField("https://matrix.your-domain", text: $homeserver)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                Section("Account") {
                    TextField("username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("password", text: $password)
                }

                if case let .error(message) = model.clientManager.state {
                    Section {
                        Text(message).foregroundStyle(.red).font(.footnote)
                    }
                }

                Section {
                    Button {
                        Task {
                            isWorking = true
                            await model.login(homeserverURL: homeserver,
                                              username: username,
                                              password: password)
                            isWorking = false
                        }
                    } label: {
                        if isWorking {
                            ProgressView()
                        } else {
                            Text("Sign in").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isWorking || username.isEmpty || password.isEmpty || homeserver.isEmpty)
                }
            }
        }
    }
}
