import SwiftUI
import AppKit

struct Routine: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var prompt = ""
    var schedule = "09:00"
    var workspace = ""
    var enabled = false
}

struct RoutineResult: Decodable {
    var status: String
    var message: String
    var finished_at: String
    var notification_status: String?
}

@MainActor
final class RoutineStore: ObservableObject {
    @Published var routines: [Routine] = []
    @Published var results: [UUID: RoutineResult] = [:]
    @Published var error: String?
    @Published var busy = false
    let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/InHouseAgent", isDirectory: true)
    var jsonURL: URL { directory.appendingPathComponent("routines.json") }
    private var agentDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true) }
    private func label(_ routine: Routine) -> String { "com.taisei1989.inhouseagent.routine.\(routine.id.uuidString)" }
    private func plistURL(_ routine: Routine) -> URL { agentDirectory.appendingPathComponent(label(routine) + ".plist") }

    init() { reload() }

    func reload() {
        do {
            if FileManager.default.fileExists(atPath: jsonURL.path) {
                routines = try JSONDecoder().decode([Routine].self, from: Data(contentsOf: jsonURL))
            }
            refreshResults()
        } catch { self.error = error.localizedDescription }
    }

    func refreshResults() {
        var refreshed: [UUID: RoutineResult] = [:]
        for routine in routines {
            let file = directory.appendingPathComponent("routine-results/\(routine.id.uuidString).json")
            if let data = try? Data(contentsOf: file), let result = try? JSONDecoder().decode(RoutineResult.self, from: data) {
                refreshed[routine.id] = result
            }
        }
        results = refreshed
    }

    private func persist(_ values: [Routine]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(values).write(to: jsonURL, options: .atomic)
        routines = values
    }

    func save(_ routine: Routine) {
        do {
            guard !routine.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Self.timeParts(routine.schedule) != nil else { throw RoutineError.invalidInput }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: routine.workspace, isDirectory: &isDirectory), isDirectory.boolValue else { throw RoutineError.invalidWorkspace }
            var values = routines
            if let index = values.firstIndex(where: { $0.id == routine.id }) {
                guard !values[index].enabled else { throw RoutineError.disableBeforeEditing }
                values[index] = routine
            } else { values.append(routine) }
            try persist(values)
        } catch { self.error = error.localizedDescription }
    }

    static func timeParts(_ schedule: String) -> (Int, Int)? {
        let parts = schedule.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    func setEnabled(_ routine: Routine, enabled: Bool) async {
        busy = true
        defer { busy = false }
        do {
            if enabled {
                let model = UserDefaults.standard.string(forKey: "modelPath") ?? ""
                guard FileManager.default.fileExists(atPath: model) else { throw RoutineError.missingModel }
                let python = directory.appendingPathComponent("venv/bin/python3").path
                guard FileManager.default.isExecutableFile(atPath: python),
                      let resources = Bundle.main.resourceURL else { throw RoutineError.missingRuntime }
                let runner = resources.appendingPathComponent("sidecar/routine.py").path
                guard FileManager.default.fileExists(atPath: runner), let time = Self.timeParts(routine.schedule) else { throw RoutineError.missingRuntime }
                try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
                let logs = directory.appendingPathComponent("logs", isDirectory: true)
                try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
                let plist: [String: Any] = [
                    "Label": label(routine),
                    "ProgramArguments": [python, "-B", runner, "--routine", jsonURL.path, "--id", routine.id.uuidString, "--model", model],
                    "EnvironmentVariables": ["PYTHONDONTWRITEBYTECODE": "1"],
                    "StartCalendarInterval": ["Hour": time.0, "Minute": time.1],
                    "WorkingDirectory": routine.workspace,
                    "StandardOutPath": logs.appendingPathComponent("routine-\(routine.id.uuidString).log").path,
                    "StandardErrorPath": logs.appendingPathComponent("routine-\(routine.id.uuidString).log").path,
                    "ProcessType": "Background"
                ]
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL(routine), options: .atomic)
                do { try await launchctl(["bootstrap", "gui/\(getuid())", plistURL(routine).path]) }
                catch { try? FileManager.default.removeItem(at: plistURL(routine)); throw error }
            } else {
                // A job may already be unloaded after logout or an external change.
                if await isRegistered(routine) {
                    try await launchctl(["bootout", "gui/\(getuid())/\(label(routine))"])
                }
                if FileManager.default.fileExists(atPath: plistURL(routine).path) { try FileManager.default.removeItem(at: plistURL(routine)) }
            }
            var values = routines
            guard let index = values.firstIndex(where: { $0.id == routine.id }) else { return }
            values[index].enabled = enabled
            do { try persist(values) }
            catch {
                if enabled { try? await launchctl(["bootout", "gui/\(getuid())/\(label(routine))"]); try? FileManager.default.removeItem(at: plistURL(routine)) }
                throw error
            }
        } catch { self.error = error.localizedDescription }
    }

    private func isRegistered(_ routine: Routine) async -> Bool {
        do { try await launchctl(["print", "gui/\(getuid())/\(label(routine))"]); return true }
        catch { return false }
    }

    func runNow(_ routine: Routine) async {
        busy = true
        defer { busy = false }
        do { try await launchctl(["kickstart", "gui/\(getuid())/\(label(routine))"]) }
        catch { self.error = error.localizedDescription }
    }

    func delete(_ routine: Routine) {
        do {
            guard !routine.enabled else { throw RoutineError.disableBeforeEditing }
            try persist(routines.filter { $0.id != routine.id })
        } catch { self.error = error.localizedDescription }
    }

    private func launchctl(_ arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw RoutineError.launchctl(String(data: data, encoding: .utf8) ?? "launchctl failed")
            }
        }.value
    }
}

enum RoutineError: LocalizedError {
    case invalidInput, invalidWorkspace, disableBeforeEditing, missingModel, missingRuntime
    case launchctl(String)
    var errorDescription: String? {
        switch self {
        case .invalidInput: String(localized: "Enter a name, prompt, and valid time.")
        case .invalidWorkspace: String(localized: "Choose an existing workspace folder.")
        case .disableBeforeEditing: String(localized: "Unregister the routine before editing or deleting it.")
        case .missingModel: String(localized: "Choose a model in Settings before registering a routine.")
        case .missingRuntime: String(localized: "Complete setup before registering a routine.")
        case .launchctl(let message): message
        }
    }
}

struct RoutinesView: View {
    @StateObject private var store = RoutineStore()
    @State private var editing: Routine?
    @State private var deleting: Routine?
    private let refresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if store.routines.isEmpty {
                ContentUnavailableView {
                    Label("No routines", systemImage: "calendar.badge.clock")
                } description: { Text("Schedule tasks to run on this Mac.") }
                actions: { Button("Add Routine") { add() } }
            } else {
                List(store.routines) { routine in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(routine.name).font(.headline)
                            Spacer()
                            Label(LocalizedStringKey(routine.enabled ? "Registered" : "Not registered"), systemImage: routine.enabled ? "checkmark.circle" : "pause.circle")
                                .foregroundStyle(.secondary)
                        }
                        Text("Daily at \(routine.schedule) · \(TimeZone.current.identifier)").font(.subheadline)
                        Text(routine.prompt).lineLimit(3)
                        Text(routine.workspace).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let result = store.results[routine.id] {
                            DisclosureGroup("Last result: \(String(localized: String.LocalizationValue(result.status)))") {
                                Text(result.finished_at).font(.caption).foregroundStyle(.secondary)
                                Text(result.message).textSelection(.enabled)
                                if let status = result.notification_status {
                                    LabeledContent("Notification") { Text(LocalizedStringKey(status == "delivered" ? "Delivered" : status == "error" ? "Delivery failed" : "Not available")) }
                                }
                            }
                        }
                        HStack {
                            Button(LocalizedStringKey(routine.enabled ? "Unregister" : "Register")) { Task { await store.setEnabled(routine, enabled: !routine.enabled) } }
                            Button("Run Now") { Task { await store.runNow(routine) } }.disabled(!routine.enabled)
                            Button("Edit") { editing = routine }.disabled(routine.enabled)
                            Button("Delete", role: .destructive) { deleting = routine }.disabled(routine.enabled)
                        }.disabled(store.busy)
                    }.padding(.vertical, 6)
                }
            }
        }
        .toolbar { ToolbarItem { Button("Add Routine", systemImage: "plus") { add() }.disabled(store.busy) } }
        .safeAreaInset(edge: .bottom) {
            Text("Scheduled tasks cannot approve file changes or commands. Review their results here.")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .sheet(item: $editing) { routine in RoutineEditor(routine: routine) { store.save($0) } }
        .alert("Routine could not be updated", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .alert("Delete this routine?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) { if let routine = deleting { store.delete(routine) }; deleting = nil }
        }
        .onReceive(refresh) { _ in store.refreshResults() }
    }

    private func add() {
        var routine = Routine()
        routine.workspace = UserDefaults.standard.string(forKey: "workspacePath") ?? ServerModel.defaultWorkspace.path
        editing = routine
    }
}

private struct RoutineEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var routine: Routine
    @State private var time = Date()
    let save: (Routine) -> Void
    var body: some View {
        VStack(alignment: .leading) {
            Text("Routine").font(.title2)
            Form {
                TextField("Name", text: $routine.name).accessibilityIdentifier("routine.name")
                TextField("Prompt", text: $routine.prompt, axis: .vertical).accessibilityIdentifier("routine.prompt").lineLimit(4...8)
                DatePicker("Run daily at", selection: $time, displayedComponents: .hourAndMinute).accessibilityIdentifier("routine.time")
                Text(TimeZone.current.identifier).foregroundStyle(.secondary)
                HStack {
                    TextField("Workspace", text: $routine.workspace).accessibilityIdentifier("routine.workspace")
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url { routine.workspace = url.path }
                    }
                }
            }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
                    routine.schedule = String(format: "%02d:%02d", parts.hour ?? 9, parts.minute ?? 0)
                    save(routine)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
                    .disabled(routine.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || routine.workspace.isEmpty)
            }
        }.padding().frame(width: 550)
        .onAppear {
            if let parts = RoutineStore.timeParts(routine.schedule), let date = Calendar.current.date(bySettingHour: parts.0, minute: parts.1, second: 0, of: Date()) { time = date }
        }
    }
}
