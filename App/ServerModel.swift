import SwiftUI
import AppKit
import Security

enum ServerState: String {
    case stopped, starting, loading_model, ready, error
    var title: LocalizedStringKey {
        switch self { case .stopped: "Stopped"; case .starting: "Starting"; case .loading_model: "Loading model"; case .ready: "Ready"; case .error: "Error" }
    }
    var symbol: String {
        switch self { case .stopped: "stop.circle"; case .starting, .loading_model: "hourglass"; case .ready: "checkmark.circle"; case .error: "exclamationmark.triangle" }
    }
}
struct Approval: Identifiable { let id: String; let name: String; let arguments: String; let reason: String }

@MainActor
final class ServerModel: ObservableObject {
    static let shared = ServerModel()
    static var support: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/InHouseAgent") }
    static var python: URL { support.appendingPathComponent("venv/bin/python3") }
    static var defaultWorkspace: URL { support.appendingPathComponent("Workspace", isDirectory: true) }
    @Published var state: ServerState = .stopped
    @Published var logs = ""
    @Published var error: String?
    @Published var modelName = ""
    @Published private(set) var activeBackend = "litert"
    var connectionLabel: LocalizedStringKey {
        switch activeBackend {
        case "google": "Google cloud"
        case "openai": "OpenAI-compatible cloud"
        default: "Local model"
        }
    }
    @Published var memory: Int64 = 0
    @Published var messages: [ChatMessage] = []
    @Published var tools: [ToolActivity] = []
    @Published private(set) var conversations: [ConversationRecord] = []
    @Published private(set) var currentConversationID = UUID()
    @Published private(set) var viewingHistory = false
    @Published private(set) var historyError: String?
    private var attachHistoryOnNextSend = false
    private var conversationTitle: String?
    private var conversationWorkspace = ""
    private var conversationBackend = ""
    private var conversationModel = ""
    private var lastHistorySave = Date.distantPast
    private var conversationStore: ConversationStore { ConversationStore(directory: Self.support.appendingPathComponent("Conversations")) }

    private init() {
        do {
            var unreadable = false
            conversations = try conversationStore.load { unreadable = true }
            if unreadable { historyError = String(localized: "Some conversations could not be loaded. Their files have been preserved.") }
        }
        catch { historyError = String(localized: "Conversation history could not be loaded.") }
    }

    private func saveConversation() {
        guard !messages.isEmpty, !viewingHistory else { return }
        let title = conversationTitle ?? String((messages.first(where: { $0.user })?.text ?? String(localized: "New Chat")).prefix(60))
        let record = ConversationRecord(id: currentConversationID, title: title, updatedAt: Date(), messages: messages,
            workspace: conversationWorkspace, backend: conversationBackend, model: conversationModel)
        do {
            try conversationStore.save(record)
            conversations.removeAll { $0.id == record.id }; conversations.insert(record, at: 0)
            lastHistorySave = Date(); historyError = nil
        } catch { historyError = String(localized: "Conversation history could not be saved.") }
    }

    func openConversation(_ record: ConversationRecord) {
        guard !sending, !resettingChat else { return }
        saveConversation()
        currentConversationID = record.id; conversationTitle = record.title
        messages = record.messages; tools = record.messages.last?.tools ?? []
        conversationWorkspace = record.workspace; conversationBackend = record.backend; conversationModel = record.model
        viewingHistory = true; attachHistoryOnNextSend = false
    }

    func deleteConversation(_ id: UUID) {
        guard !sending, !resettingChat else { return }
        do {
            try conversationStore.delete(id); conversations.removeAll { $0.id == id }
            if currentConversationID == id {
                messages = []; tools = []; viewingHistory = false; currentConversationID = UUID(); conversationTitle = nil
                newChat()
            }
        } catch { historyError = String(localized: "Conversation could not be deleted.") }
    }

    func renameConversation(_ id: UUID, title: String) {
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !title.isEmpty, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        var record = conversations[index]; record.title = title
        do { try conversationStore.save(record); conversations[index] = record; if currentConversationID == id { conversationTitle = title } }
        catch { historyError = String(localized: "Conversation history could not be saved.") }
    }

    /// Call after the user confirms the currently selected provider/workspace.
    func continueConversation() {
        guard viewingHistory, !sending, !resettingChat else { return }
        // Branch from the transcript. Never replay tool calls or claim SDK state restoration.
        currentConversationID = UUID(); viewingHistory = false; conversationTitle = nil
        attachHistoryOnNextSend = true
        newChat(preservingTranscript: true)
    }

    var lastUserPrompt: String? { messages.last(where: { $0.user })?.text }

    @Published var approval: Approval?
    @Published var sending = false
    @Published var startedAt: Date?
    private(set) var process: Process?
    private var token = ""
    private var port: Int?
    private var stopping = false
    @Published private(set) var lifecycleBusy = false
    @Published private(set) var approvalBusy = false
    private var failures: [Date] = []
    private var healthTask: Task<Void, Never>?
    private var chatTask: Task<Void, Never>?
    private var chatGeneration = UUID()
    @Published private(set) var resettingChat = false
    @Published private(set) var configurationInvalidated = false
    private var stdoutBuffer = ""
    private var logHandle: FileHandle?
    private let keychainService = "com.taisei1989.inhouseagent.sidecar"

    private func saveConnection(port: Int) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: "session"]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(token.utf8)] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = Data(token.utf8)
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw URLError(.userAuthenticationRequired) }
        } else if status != errSecSuccess { throw URLError(.userAuthenticationRequired) }
        try FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.support.path)
        let data = try JSONSerialization.data(withJSONObject: ["port": port, "pid": process?.processIdentifier ?? 0])
        try data.write(to: Self.support.appendingPathComponent("server.json"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.support.appendingPathComponent("server.json").path)
    }
    private func removeConnection() { try? FileManager.default.removeItem(at: Self.support.appendingPathComponent("server.json")) }

    var configured: Bool {
        FileManager.default.fileExists(atPath: Self.python.path) &&
        FileManager.default.fileExists(atPath: UserDefaults.standard.string(forKey: "modelPath") ?? "")
    }
    func log(_ line: String) {
        let text = line.replacingOccurrences(of: token.isEmpty ? "<unavailable-secret>" : token, with: "<redacted>")
        logs += text
        if logs.count > 100_000 { logs = String(logs.suffix(80_000)) }
        if logHandle == nil {
            let directory = Self.support.appendingPathComponent("logs")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("server.log")
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            logHandle = try? FileHandle(forWritingTo: url)
            _ = try? logHandle?.seekToEnd()
        }
        try? logHandle?.write(contentsOf: Data(text.utf8))
    }
    func start(manual: Bool = true) {
        guard process == nil, !lifecycleBusy else { return }
        if manual { failures = [] }
        guard configured else { state = .error; error = String(localized: "Complete setup before starting the server."); return }
        let backend: [String: Any]
        do { backend = try CloudConfiguration.bootstrap() }
        catch { state = .error; self.error = error.localizedDescription; return }
        do { try FileManager.default.createDirectory(at: Self.defaultWorkspace, withIntermediateDirectories: true) }
        catch { state = .error; self.error = error.localizedDescription; return }
        activeBackend = backend["backend"] as? String ?? "litert"
        stopping = false; configurationInvalidated = false; port = nil; stdoutBuffer = ""; error = nil; state = .starting; startedAt = Date()
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { state = .error; error = String(localized: "Unable to generate session token"); return }
        token = Data(bytes).base64EncodedString()
        let child = Process(), input = Pipe(), output = Pipe(), stderr = Pipe()
        child.executableURL = Self.python
        child.currentDirectoryURL = Bundle.main.resourceURL
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        child.environment = environment
        child.arguments = ["-B", "-u", "-m", "sidecar.server", "--model", UserDefaults.standard.string(forKey: "modelPath") ?? "", "--workspace", UserDefaults.standard.string(forKey: "workspacePath") ?? ServerModel.defaultWorkspace.path, "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
        child.standardInput = input; child.standardOutput = output; child.standardError = stderr
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let string = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                guard self?.process === child else { return }
                self?.receiveBootstrap(string)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let string = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.log(string) }
        }
        child.terminationHandler = { [weak self] finished in
            Task { @MainActor in self?.terminated(finished) }
        }
        do {
            try child.run(); process = child
            var settings = backend
            settings["token"] = token
            let bootstrap = try JSONSerialization.data(withJSONObject: settings)
            try input.fileHandleForWriting.write(contentsOf: bootstrap + Data([10])); try input.fileHandleForWriting.close()
            log("Server launched (PID \(child.processIdentifier)).\n")
        } catch {
            stopping = true
            if child.isRunning { child.terminate() }
            self.error = error.localizedDescription; state = .error
            if !child.isRunning { process = nil }
        }
    }
    private func receiveBootstrap(_ string: String) {
        stdoutBuffer += string
        while let end = stdoutBuffer.firstIndex(of: "\n") {
            let line = String(stdoutBuffer[..<end]); stdoutBuffer.removeSubrange(...end)
            if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], object["event"] as? String == "listening", let value = object["port"] as? Int {
                port = value
                do { try saveConnection(port: value) } catch { log("Routine connection unavailable: \(error.localizedDescription)\n") }
                healthTask?.cancel()
                healthTask = Task { [weak self] in
                    while !Task.isCancelled {
                        await self?.pollHealth()
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
            } else { log(line + "\n") }
        }
    }
    func request(_ path: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard let port else { throw URLError(.cannotConnectToHost) }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        if let body { request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return request
    }
    private func pollHealth() async {
        let observedProcess = process
        do {
            let (data, response) = try await URLSession.shared.data(for: request("/health"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            guard !stopping, !Task.isCancelled, process === observedProcess else { return }
            state = ServerState(rawValue: object["status"] as? String ?? "error") ?? .error
            modelName = object["model"] as? String ?? ""
            memory = (object["memory_bytes"] as? NSNumber)?.int64Value ?? 0
            error = object["error"] as? String
        } catch { if !Task.isCancelled && !stopping && process === observedProcess { self.error = error.localizedDescription } }
    }
    private func terminated(_ child: Process) {
        guard process === child else { return }
        process = nil; port = nil; healthTask?.cancel(); cancelChat()
        if !messages.isEmpty { viewingHistory = true }
        removeConnection()
        log("Server exited (\(child.terminationStatus)).\n")
        if stopping { state = .stopped; return }
        failures = failures.filter { Date().timeIntervalSince($0) < 60 }; failures.append(Date())
        guard failures.count < 3 else { state = .error; error = String(localized: "Server failed repeatedly. Automatic restart paused."); return }
        state = .starting
        Task { try? await Task.sleep(for: .seconds(2)); if !stopping { start(manual: false) } }
    }
    func stop() async {
        if lifecycleBusy {
            while lifecycleBusy { try? await Task.sleep(for: .milliseconds(100)) }
            return
        }
        lifecycleBusy = true
        defer { lifecycleBusy = false }
        stopping = true; healthTask?.cancel(); cancelChat()
        guard let child = process else { state = .stopped; return }
        if let request = try? request("/shutdown", body: [:]) { _ = try? await URLSession.shared.data(for: request) }
        for _ in 0..<150 { if !child.isRunning { break }; try? await Task.sleep(for: .milliseconds(100)) }
        if child.isRunning { child.terminate() }
        for _ in 0..<40 { if !child.isRunning { break }; try? await Task.sleep(for: .milliseconds(100)) }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        for _ in 0..<30 { if !child.isRunning { break }; try? await Task.sleep(for: .milliseconds(100)) }
        guard !child.isRunning else { state = .error; error = String(localized: "Server did not stop. Try again before quitting."); return }
        if process === child || process == nil { process = nil; port = nil; state = .stopped; removeConnection() }
        if !messages.isEmpty { viewingHistory = true }
    }
    func restart() async { await stop(); start() }
    func send(_ prompt: String) {
        guard !viewingHistory, state == .ready, !stopping, !lifecycleBusy, !configurationInvalidated, !sending, !resettingChat, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let generation = UUID(); chatGeneration = generation
        var requestPrompt = prompt
        if attachHistoryOnNextSend {
            let transcript = messages.map { ($0.user ? "User: " : "Assistant: ") + $0.text }.joined(separator: "\n\n")
            requestPrompt = "Previous conversation, supplied as context only. Do not repeat previous tool actions.\n<previous_conversation>\n" + String(transcript.suffix(16_000)) + "\n</previous_conversation>\nCurrent request:\n" + prompt
        }
        conversationWorkspace = UserDefaults.standard.string(forKey: "workspacePath") ?? Self.defaultWorkspace.path
        conversationBackend = activeBackend; conversationModel = modelName
        error = nil
        messages.append(ChatMessage(user: true, text: prompt)); messages.append(ChatMessage(user: false, text: "", status: "responding")); tools = []; sending = true
        saveConversation()
        chatTask = Task {
            defer {
                if chatGeneration == generation {
                    sending = false; approval = nil
                    if let last = messages.indices.last, ["responding", "waiting"].contains(messages[last].status) {
                        messages[last].status = "error"
                        messages[last].failure = String(localized: "The response ended before completion. You can send the request again.")
                    }
                    if let last = messages.indices.last {
                        for index in messages[last].tools.indices where messages[last].tools[index].status == "running" { messages[last].tools[index].status = "unknown" }
                        tools = messages[last].tools
                    }
                    saveConversation()
                }
            }
            do {
                var request = try request("/chat", body: ["prompt": requestPrompt, "workspace": UserDefaults.standard.string(forKey: "workspacePath") ?? ServerModel.defaultWorkspace.path]); request.timeoutInterval = 3600
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                guard chatGeneration == generation else { return }
                attachHistoryOnNextSend = false
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    guard chatGeneration == generation else { return }
                    guard line.hasPrefix("data: "), let object = try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any] else { continue }
                    handleEvent(object)
                }
            } catch {
                if !Task.isCancelled, chatGeneration == generation {
                    self.error = error.localizedDescription
                    if let last = messages.indices.last { messages[last].status = "error"; messages[last].failure = error.localizedDescription }
                    log("Chat error: \(error.localizedDescription)\n")
                }
            }
        }
    }
    private func handleEvent(_ object: [String: Any]) {
        guard let last = messages.indices.last, !messages[last].user else { return }
        switch object["type"] as? String {
        case "token": messages[last].text += object["text"] as? String ?? ""
        case "thought":
            messages[last].thought += object["text"] as? String ?? ""
            messages[last].thoughtTruncated = messages[last].thoughtTruncated || object["truncated"] as? Bool == true
        case "tool":
            let id = object["id"] as? String ?? UUID().uuidString
            let status = object["status"] as? String ?? "running"
            var tool = messages[last].tools.first(where: { $0.id == id }) ?? ToolActivity(id: id, name: object["name"] as? String ?? "Tool", status: status)
            tool.status = status
            if let args = object["args"] as? String { tool.args = args }
            else if let args = object["args"], let data = try? JSONSerialization.data(withJSONObject: args, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { tool.args = text }
            if let result = object["result"] as? String { tool.result = result }
            if let error = object["error"] as? String { tool.error = error }
            tool.truncated = tool.truncated || object["truncated"] as? Bool == true
            if let index = messages[last].tools.firstIndex(where: { $0.id == id }) { messages[last].tools[index] = tool }
            else { messages[last].tools.append(tool) }
            tools = messages[last].tools
        case "approval":
            let data = try? JSONSerialization.data(withJSONObject: object["args"] ?? [:], options: [.prettyPrinted, .sortedKeys])
            approval = Approval(id: object["id"] as? String ?? "", name: object["name"] as? String ?? "", arguments: data.flatMap { String(data: $0, encoding: .utf8) } ?? "", reason: object["reason"] as? String ?? "")
            messages[last].status = "waiting"
        case "error": error = object["message"] as? String; messages[last].failure = error; messages[last].status = "error"
        case "done": messages[last].status = "completed"
        default: break
        }
        if Date().timeIntervalSince(lastHistorySave) > 2 { saveConversation() }
    }
    func resolveApproval(_ approved: Bool, expectedID: String) async {
        guard let current = approval, current.id == expectedID, !approvalBusy else { return }
        approvalBusy = true
        defer { approvalBusy = false }
        do {
            let (_, response) = try await URLSession.shared.data(for: request("/approvals/\(current.id)", body: ["approved": approved]))
            if (response as? HTTPURLResponse)?.statusCode == 404 {
                if approval?.id == current.id { approval = nil }
                error = String(localized: "This approval has expired. Review the task status before trying again.")
                return
            }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        } catch { self.error = error.localizedDescription; return }
        error = nil
        if approval?.id == current.id {
            approval = nil
            if let last = messages.indices.last { messages[last].status = "responding" }
        }
    }
    func cancelChat() {
        if sending, let last = messages.indices.last {
            messages[last].status = "cancelled"
            for index in messages[last].tools.indices where messages[last].tools[index].status == "running" { messages[last].tools[index].status = "cancelled" }
            tools = messages[last].tools
        }
        chatGeneration = UUID(); chatTask?.cancel(); chatTask = nil; approval = nil; sending = false
        saveConversation()
    }
    func configurationChanged() {
        configurationInvalidated = true
        cancelChat()
        Task { await stop() }
    }
    func newChat(preservingTranscript: Bool = false) {
        guard !resettingChat else { return }
        cancelChat()
        if !preservingTranscript {
            messages = []; tools = []; viewingHistory = false; currentConversationID = UUID(); conversationTitle = nil
            attachHistoryOnNextSend = false
        }
        guard process != nil else { return }
        resettingChat = true
        Task {
            defer { resettingChat = false }
            do {
                for _ in 0..<100 {
                    let (data, response) = try await URLSession.shared.data(for: request("/health"))
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    let health = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    if health?["busy"] as? Bool == false { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                let (_, response) = try await URLSession.shared.data(for: request("/conversations/reset", body: [:]))
                guard (response as? HTTPURLResponse)?.statusCode == 202 else { throw URLError(.badServerResponse) }
                state = .loading_model; startedAt = Date()
            } catch {
                configurationInvalidated = true
                self.error = error.localizedDescription
            }
        }
    }
}
