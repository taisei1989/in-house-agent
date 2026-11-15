import SwiftUI
import Security

enum CloudProvider: String, CaseIterable, Identifiable {
    case google, openai
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self { case .google: "Google"; case .openai: "OpenAI-compatible" }
    }
    var modelPreference: String {
        switch self { case .google: "cloudGoogleModel"; case .openai: "cloudOpenAIModel" }
    }
}

/// Credentials never enter UserDefaults, files, command-line arguments, or logs.
enum CloudConfiguration {
    static let keychainService = "com.taisei1989.inhouseagent.credentials"

    static func bootstrap(defaults: UserDefaults = .standard) throws -> [String: Any] {
        guard defaults.bool(forKey: "allowCloud") else {
            return ["backend": "litert", "allow_cloud": false]
        }
        guard let provider = CloudProvider(rawValue: defaults.string(forKey: "cloudProvider") ?? "google") else {
            throw CloudConfigurationError.invalidProvider
        }
        let model = (defaults.string(forKey: provider.modelPreference) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.count <= 256, !model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CloudConfigurationError.missingModel
        }
        var result: [String: Any] = ["backend": provider.rawValue, "allow_cloud": true, "model": model]
        if provider == .openai {
            result["base_url"] = try validatedBaseURL(defaults.string(forKey: "cloudBaseURL") ?? "https://api.openai.com/v1")
        }
        result["api_key"] = try readAPIKey(for: provider)
        return result
    }

    static func validatedBaseURL(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: trimmed), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.url != nil,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CloudConfigurationError.invalidURL
        }
        return trimmed
    }

    static func hasAPIKey(for provider: CloudProvider) throws -> Bool {
        var query = keyQuery(provider)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw CloudConfigurationError.keychain(status) }
        return true
    }

    static func saveAPIKey(_ value: String, for provider: CloudProvider) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 4096,
              !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CloudConfigurationError.invalidKey
        }
        let query = keyQuery(provider)
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw CloudConfigurationError.keychain(added) }
        } else if status != errSecSuccess { throw CloudConfigurationError.keychain(status) }
    }

    static func deleteAPIKey(for provider: CloudProvider) throws {
        let status = SecItemDelete(keyQuery(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudConfigurationError.keychain(status) }
    }

    private static func readAPIKey(for provider: CloudProvider) throws -> String {
        var query = keyQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw CloudConfigurationError.missingKey }
        guard status == errSecSuccess else { throw CloudConfigurationError.keychain(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw CloudConfigurationError.missingKey
        }
        return key
    }

    private static func keyQuery(_ provider: CloudProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: provider.rawValue]
    }
}

enum CloudConfigurationError: LocalizedError {
    case invalidProvider, missingModel, invalidURL, invalidKey, missingKey
    case keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalidProvider: String(localized: "Choose a supported cloud provider in Settings.")
        case .missingModel: String(localized: "Enter the cloud model name in Settings before starting the server.")
        case .invalidURL: String(localized: "Use an HTTPS base URL without credentials, query parameters, or a fragment.")
        case .invalidKey: String(localized: "Enter a nonempty API key without control characters.")
        case .missingKey: String(localized: "Save an API key for the selected provider in Settings.")
        case .keychain(let status): String(localized: "Keychain access failed (code \(status)). Check Keychain access and try again.")
        }
    }
}

struct CloudSettingsView: View {
    var onConfigurationChanged: () -> Void = {}
    @AppStorage("allowCloud") private var allowCloud = false
    @AppStorage("cloudProvider") private var provider = CloudProvider.google.rawValue
    @AppStorage("cloudGoogleModel") private var googleModel = ""
    @AppStorage("cloudOpenAIModel") private var openAIModel = ""
    @AppStorage("cloudBaseURL") private var baseURL = "https://api.openai.com/v1"
    @State private var keyDraft = ""
    @State private var keySaved = false
    @State private var error: String?
    @State private var deleteConfirmation = false

    private var selectedProvider: CloudProvider { CloudProvider(rawValue: provider) ?? .google }
    private var model: Binding<String> {
        selectedProvider == .google ? $googleModel : $openAIModel
    }

    var body: some View {
        Section("Cloud Models") {
            Toggle("Use a cloud model", isOn: $allowCloud).accessibilityIdentifier("settings.allowCloud")
            Text(allowCloud
                 ? String(localized: "When the server restarts, prompts and tool results will be sent to the selected provider. Local inference resumes when this option is off.")
                 : String(localized: "After restarting the server, prompts and tool results use only the local model."))
                .foregroundStyle(.secondary)
            if allowCloud {
                Picker("Provider", selection: $provider) {
                    ForEach(CloudProvider.allCases) { value in Text(value.title).tag(value.rawValue) }
                }.accessibilityIdentifier("settings.cloudProvider")
                TextField("Cloud model name", text: model).accessibilityIdentifier("settings.cloudModel")
                if selectedProvider == .openai {
                    TextField("HTTPS base URL", text: $baseURL).accessibilityIdentifier("settings.cloudBaseURL")
                    Text("Use the API base URL supplied by your provider, including its API version path.").foregroundStyle(.secondary)
                }
                LabeledContent("API key") {
                    Label(keySaved ? String(localized: "Saved in Keychain") : String(localized: "Not saved"), systemImage: keySaved ? "key.fill" : "key")
                        .accessibilityIdentifier("settings.cloudKeyStatus")
                }
                SecureField("New API key", text: $keyDraft).accessibilityIdentifier("settings.cloudAPIKey")
                HStack {
                    Button("Save API Key") { saveKey() }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("settings.saveCloudKey")
                    Button("Delete Saved Key", role: .destructive) { deleteConfirmation = true }
                        .disabled(!keySaved)
                }
                Text("The saved key is never displayed. Restart the server to apply cloud settings.").foregroundStyle(.secondary)
                if let error { Label(error, systemImage: "exclamationmark.triangle").textSelection(.enabled) }
            }
        }
        .onAppear { refreshKeyStatus() }
        .onChange(of: provider) { _, _ in keyDraft = ""; error = nil; refreshKeyStatus(); onConfigurationChanged() }
        .onChange(of: allowCloud) { _, enabled in
            if enabled { refreshKeyStatus() } else { keyDraft = ""; error = nil }
            onConfigurationChanged()
        }
        .onChange(of: googleModel) { _, _ in onConfigurationChanged() }
        .onChange(of: openAIModel) { _, _ in onConfigurationChanged() }
        .onChange(of: baseURL) { _, _ in onConfigurationChanged() }
        .onDisappear { keyDraft = "" }
        .alert("Delete this provider's API key?", isPresented: $deleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                do { try CloudConfiguration.deleteAPIKey(for: selectedProvider); error = nil; refreshKeyStatus(); onConfigurationChanged() }
                catch { self.error = error.localizedDescription }
            }
        } message: { Text("You will need to enter the key again to use this provider.") }
    }

    private func refreshKeyStatus() {
        do { keySaved = try CloudConfiguration.hasAPIKey(for: selectedProvider) }
        catch { keySaved = false; self.error = error.localizedDescription }
    }
    private func saveKey() {
        do {
            if selectedProvider == .openai { _ = try CloudConfiguration.validatedBaseURL(baseURL) }
            try CloudConfiguration.saveAPIKey(keyDraft, for: selectedProvider)
            keyDraft = ""; error = nil; refreshKeyStatus(); onConfigurationChanged()
        } catch { self.error = error.localizedDescription }
    }
}
