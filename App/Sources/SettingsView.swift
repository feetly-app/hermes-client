import HermesChat
import SwiftUI

/// Connection settings: instance URL, optional sidecar, model and API key. Shown alone on first launch, and as a sheet from
/// the conversation list, where `canCancel` adds a Cancel button.
struct SettingsView: View {
    let appState: AppState
    let canCancel: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var baseURL: String
    @State private var model: String
    @State private var provider: String
    @State private var sidecarURL: String
    @State private var apiKey: String
    @State private var errorMessage: String?
    @State private var isTesting = false
    @State private var testReport: ConnectionTestReport?

    init(appState: AppState, canCancel: Bool = false) {
        self.appState = appState
        self.canCancel = canCancel
        _baseURL = State(initialValue: appState.settings?.baseURLString ?? "")
        _model = State(initialValue: appState.settings?.model ?? ModelChoice.instanceDefault.model)
        _provider = State(initialValue: appState.settings?.provider ?? "")
        _sidecarURL = State(initialValue: appState.settings?.sidecarURLString ?? "")
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
                    TextField("/sidecar (optional)", text: $sidecarURL)
                        .urlEntry()
                        .autocorrectionDisabled()
                } header: {
                    Text("Sidecar")
                } footer: {
                    Text("Optional. Where hermes-sidecar is served: a path on the instance URL (for example /sidecar) or a full URL. It uses the same API key. Leave empty if you don't run it.")
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
                    if let testReport {
                        if let message = testReport.hermesMessage {
                            TestResultLabel(message: message, succeeded: testReport.hermes.isSuccess)
                        }
                        if let message = testReport.sidecarMessage {
                            TestResultLabel(message: message, succeeded: testReport.sidecar?.isSuccess == true)
                        }
                    }
                } footer: {
                    Text("Checks Hermes with the URL and key typed above, and the sidecar when one is filled in. Nothing is saved.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                if canCancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
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
        testReport = nil
        Task {
            let report = await ConnectionTester.run(
                baseURLString: baseURL, apiKey: apiKey, sidecarURLString: sidecarURL)
            isTesting = false
            if !report.isCancelled {
                testReport = report
            }
        }
    }

    private func save() {
        let trimmedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSidecar = sidecarURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = ConnectionSettings(
            baseURLString: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: trimmedProvider.isEmpty ? nil : trimmedProvider,
            sidecarURLString: trimmedSidecar.isEmpty ? nil : trimmedSidecar
        )
        guard settings.isValid else {
            errorMessage = settings.hasSidecar && settings.sidecarURL == nil
                && ConnectionSettings.parseBaseURL(settings.baseURLString) != nil
                ? "Enter the sidecar as a path (for example /sidecar) or an http or https URL, or leave it empty."
                : "Enter an http or https URL and a model name."
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

/// One line of the connection test: a green check when the service answered, a red cross otherwise.
private struct TestResultLabel: View {
    let message: String
    let succeeded: Bool

    var body: some View {
        Label(message, systemImage: succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(succeeded ? .green : .red)
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
