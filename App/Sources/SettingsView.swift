import HermesChat
import SwiftUI

/// Connection settings: instance URL, model and API key. Shown on first launch and from the chat screen.
struct SettingsView: View {
    let appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var baseURL: String
    @State private var model: String
    @State private var provider: String
    @State private var apiKey: String
    @State private var errorMessage: String?
    @State private var isTesting = false
    @State private var testOutcome: ConnectionTestOutcome?

    init(appState: AppState) {
        self.appState = appState
        _baseURL = State(initialValue: appState.settings?.baseURLString ?? "")
        _model = State(initialValue: appState.settings?.model ?? ModelChoice.instanceDefault.model)
        _provider = State(initialValue: appState.settings?.provider ?? "")
        _apiKey = State(initialValue: appState.apiKey ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://hermes.example.test", text: $baseURL)
                        .urlEntry()
                        .autocorrectionDisabled()
                } header: {
                    Text("Instance")
                } footer: {
                    Text("The base URL of your Hermes instance.")
                }

                Section {
                    TextField("Model name", text: $model)
                        .noAutocapitalization()
                        .autocorrectionDisabled()
                    TextField("Provider (optional)", text: $provider)
                        .noAutocapitalization()
                        .autocorrectionDisabled()
                } header: {
                    Text("Model")
                } footer: {
                    Text("Every new conversation runs on this model. Keep hermes-agent to use the instance's configured model; add a provider (for example anthropic) to use a provider model.")
                }

                Section {
                    SecureField("API key", text: $apiKey)
                        .noAutocapitalization()
                        .autocorrectionDisabled()
                } header: {
                    Text("API key")
                } footer: {
                    Text("Stored on this device. The key gives shell access to the server: never share it.")
                }

                Section {
                    Button("Test connection", action: testConnection)
                        .disabled(isTesting)
                    if isTesting {
                        ProgressView()
                    }
                    if let testOutcome, let message = testOutcome.message {
                        Text(message).foregroundStyle(testOutcome == .succeeded ? .green : .red)
                    }
                } footer: {
                    Text("Checks the URL and key typed above. Nothing is saved.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Runs the check with the values on screen, which may not be saved yet.
    private func testConnection() {
        isTesting = true
        testOutcome = nil
        Task {
            let outcome = await ConnectionTester.run(baseURLString: baseURL, apiKey: apiKey)
            isTesting = false
            if outcome != .cancelled {
                testOutcome = outcome
            }
        }
    }

    private func save() {
        let trimmedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = ConnectionSettings(
            baseURLString: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: trimmedProvider.isEmpty ? nil : trimmedProvider
        )
        guard settings.isValid else {
            errorMessage = "Enter an http or https URL and a model name."
            return
        }
        do {
            try appState.save(
                settings: settings,
                apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            dismiss()
        } catch {
            errorMessage = "The API key could not be saved on this device."
        }
    }
}

/// Text entry tweaks that only exist on iOS; no-ops on macOS.
private extension View {
    func urlEntry() -> some View {
        #if os(iOS)
        keyboardType(.URL).textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    func noAutocapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}
