import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var terminating = false
    func applicationWillFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--routine-notify") {
            NSApp.setActivationPolicy(.prohibited)
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["autoStartServer": true, "autoCheckUpdates": true, "workspacePath": ServerModel.defaultWorkspace.path])
        UNUserNotificationCenter.current().delegate = self
        if let index = CommandLine.arguments.firstIndex(of: "--routine-notify"), CommandLine.arguments.count > index + 1 {
            let args = CommandLine.arguments
            func value(_ flag: String) -> String { guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return "" }; return args[i + 1] }
            Task {
                let content = UNMutableNotificationContent()
                content.title = "In-House Agent — " + String(localized: String.LocalizationValue(value("--routine-status")))
                content.body = String(localized: String.LocalizationValue(value("--routine-message")))
                do {
                    let center = UNUserNotificationCenter.current()
                    let settings = await center.notificationSettings()
                    guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                        fputs("Notification permission is not granted (status \(settings.authorizationStatus.rawValue)).\n", stderr)
                        exit(1)
                    }
                    let deliveryID = UUID().uuidString
                    content.userInfo = ["routineID": args[index + 1]]
                    try await center.add(UNNotificationRequest(identifier: deliveryID, content: content, trigger: nil))
                    for _ in 0..<40 {
                        let delivered = await center.deliveredNotifications()
                        if delivered.contains(where: { $0.request.identifier == deliveryID }) {
                            print("Routine notification delivered")
                            exit(0)
                        }
                        try await Task.sleep(for: .milliseconds(250))
                    }
                    fputs("Notification delivery was not confirmed.\n", stderr)
                    exit(1)
                } catch {
                    fputs("Notification failed: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
        } else if ServerModel.shared.configured && !SetupModel().dependenciesNeedUpdate && UserDefaults.standard.bool(forKey: "autoStartServer") {
            ServerModel.shared.start()
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateNow }
        terminating = true
        Task {
            await SetupModel.shared.stop()
            await ServerModel.shared.stop()
            let canQuit = ServerModel.shared.process?.isRunning != true && !SetupModel.shared.running
            if !canQuit { terminating = false }
            sender.reply(toApplicationShouldTerminate: canQuit)
        }
        return .terminateLater
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound, .list] }
}

@main
struct InHouseAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var server = ServerModel.shared
    @StateObject private var updater = AppUpdater.shared
    var body: some Scene {
        WindowGroup {
            MainView().environmentObject(server).frame(minWidth: 800, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.check() }.disabled(!updater.canCheck)
            }
            CommandGroup(after: .newItem) {
                Button("New Chat") { server.newChat(); NotificationCenter.default.post(name: .newChat, object: nil) }.keyboardShortcut("n")
            }
            CommandMenu("Server") { ServerCommands().environmentObject(server) }
        }
        Settings { PreferencesView().environmentObject(server) }
        MenuBarExtra("In-House Agent", systemImage: server.state.symbol) {
            Text(server.state.title)
            ServerCommands().environmentObject(server)
            Divider()
            Button("Quit In-House Agent") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}

extension Notification.Name { static let newChat = Notification.Name("newChat") }

enum Destination: String, CaseIterable, Identifiable {
    case chat = "Chat", routines = "Routines", server = "Server"
    var id: String { rawValue }
    var symbol: String { switch self { case .chat: "bubble.left.and.bubble.right"; case .routines: "calendar.badge.clock"; case .server: "server.rack" } }
}
struct ServerCommands: View {
    @EnvironmentObject var server: ServerModel
    var body: some View {
        Button("Start Server") { server.start() }.disabled(server.process != nil || server.lifecycleBusy)
        Button("Stop Server", role: .destructive) { Task { await server.stop() } }.disabled(server.process == nil || server.lifecycleBusy)
        Button("Restart Server") { Task { await server.restart() } }.disabled(server.lifecycleBusy)
    }
}
struct MainView: View {
    @EnvironmentObject var server: ServerModel
    @State private var selection: Destination? = .chat
    @State private var prompt = ""
    @State private var setup = !ServerModel.shared.configured || SetupModel().dependenciesNeedUpdate
    @State private var conversationSearch = ""
    @State private var renaming: ConversationRecord?
    @State private var renamedTitle = ""
    @State private var deleting: ConversationRecord?
    private var detailTitle: String {
        if selection == .chat, let current = server.conversations.first(where: { $0.id == server.currentConversationID }) { return current.title }
        return String(localized: String.LocalizationValue((selection ?? .chat).rawValue))
    }
    private var filteredConversations: [ConversationRecord] {
        server.conversations.filter { conversationSearch.isEmpty || $0.title.localizedCaseInsensitiveContains(conversationSearch) }
    }
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Button("New Chat", systemImage: "square.and.pencil") { server.newChat(); selection = .chat; prompt = "" }
                        .disabled(server.sending || server.resettingChat).accessibilityIdentifier("chat.new")
                    ForEach(Destination.allCases) { item in
                        Label(LocalizedStringKey(item.rawValue), systemImage: item.symbol).tag(item).accessibilityIdentifier("nav.\(item.rawValue.lowercased())")
                    }
                }
                Section("Conversations") {
                    TextField("Search conversations", text: $conversationSearch).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search conversations").accessibilityIdentifier("history.search")
                    ForEach(filteredConversations) { conversation in
                        Button {
                            server.openConversation(conversation); selection = .chat; prompt = ""
                        } label: {
                            HStack {
                                Image(systemName: conversation.id == server.currentConversationID ? "bubble.left.fill" : "bubble.left").accessibilityHidden(true)
                                Text(conversation.title).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(server.sending || server.resettingChat)
                            .listRowBackground(conversation.id == server.currentConversationID ? Color.accentColor.opacity(0.08) : Color.clear)
                            .accessibilityIdentifier("history.item.\(conversation.id.uuidString)")
                            .contextMenu {
                                Button("Rename") { renamedTitle = conversation.title; renaming = conversation }
                                Button("Delete Conversation", role: .destructive) { deleting = conversation }
                            }
                    }
                    if filteredConversations.isEmpty { Text("No saved conversations").font(.caption).foregroundStyle(.secondary) }
                }
            }.navigationTitle("In-House Agent")
            .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 330)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(server.state.title, systemImage: server.state.symbol)
                    Text(server.connectionLabel).font(.caption).accessibilityIdentifier("server.mode")
                }.foregroundStyle(.secondary).padding()
            }
        } detail: {
            Group {
                if setup { SetupView { setup = false; if server.configured && UserDefaults.standard.bool(forKey: "autoStartServer") { server.start() } } }
                else {
                    switch selection ?? .chat {
                    case .chat: ChatWorkspaceView(prompt: $prompt)
                    case .routines: RoutinesView()
                    case .server: serverView
                    }
                }
            }
            .navigationTitle(detailTitle)
            .toolbar {
                ToolbarItem { Menu { ServerCommands(); Divider(); Button("Set Up Model…") { setup = true } } label: { Label(server.state.title, systemImage: server.state.symbol) }.accessibilityLabel("Server controls") }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newChat)) { _ in selection = .chat; prompt = "" }
        .alert("Rename Conversation", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renamedTitle)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let record = renaming { server.renameConversation(record.id, title: renamedTitle) }
                renaming = nil
            }.disabled(renamedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Delete this conversation?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) { if let record = deleting { server.deleteConversation(record.id) }; deleting = nil }
        } message: { Text("The saved conversation will be deleted from this Mac. File changes and commands already performed are not undone.") }
        .sheet(item: $server.approval) { approval in
            VStack(alignment: .leading, spacing: 16) {
                Label("Approve this operation?", systemImage: "hand.raised").font(.title2)
                Text(approval.name).font(.headline)
                if !approval.reason.isEmpty { Text(approval.reason) }
                if let error = server.error { Label(error, systemImage: "exclamationmark.triangle").textSelection(.enabled) }
                ScrollView { Text(approval.arguments).accessibilityIdentifier("approval.details").font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 120, maxHeight: 340)
                Text("Only this operation will be allowed. Review the file path or command before approving.").foregroundStyle(.secondary)
                HStack { Spacer(); Button("Deny", role: .cancel) { Task { await server.resolveApproval(false, expectedID: approval.id) } }.keyboardShortcut(.cancelAction).accessibilityIdentifier("approval.deny"); Button("Approve", role: .destructive) { Task { await server.resolveApproval(true, expectedID: approval.id) } }.accessibilityIdentifier("approval.allow") }
            }.padding(24).frame(width: 580).interactiveDismissDisabled().disabled(server.approvalBusy)
        }
    }
    private var serverView: some View {
        Form {
            Section("Server Status") {
                LabeledContent("Status") { Label(server.state.title, systemImage: server.state.symbol).accessibilityIdentifier("server.status") }
                if server.state == .starting || server.state == .loading_model { HStack { ProgressView().controlSize(.small); if let date = server.startedAt { Text(date, style: .timer).monospacedDigit() } } }
                LabeledContent("Model", value: server.modelName)
                LabeledContent("Memory", value: ByteCountFormatter.string(fromByteCount: server.memory, countStyle: .memory))
                if let error = server.error { Text(error).textSelection(.enabled) }
                HStack { ServerCommands() }
            }
            Section("Logs") {
                ScrollView { Text(server.logs).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 200)
                Button("Show Log Files") { NSWorkspace.shared.open(ServerModel.support.appendingPathComponent("logs")) }
            }
        }.formStyle(.grouped)
    }
}

struct PreferencesView: View {
    @EnvironmentObject var server: ServerModel
    @ObservedObject private var updater = AppUpdater.shared
    @AppStorage("modelPath") private var modelPath = ""
    @AppStorage("workspacePath") private var workspacePath = ""
    @AppStorage("autoStartServer") private var autoStart = true
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true
    @State private var notificationStatus = "Not requested"
    @State private var notificationError: String?
    var body: some View {
        Form {
            Section("Model") {
                TextField("Model path", text: $modelPath).accessibilityIdentifier("settings.modelPath")
                TextField("Workspace", text: $workspacePath).accessibilityIdentifier("settings.workspacePath")
                Text("Restart the server to apply model and workspace changes.").foregroundStyle(.secondary)
            }
            CloudSettingsView { server.configurationChanged() }
            Section("Server") { Toggle("Start server when the app opens", isOn: $autoStart).accessibilityIdentifier("settings.autoStart") }
            Section("Notifications") {
                LabeledContent("Permission") { Text(LocalizedStringKey(notificationStatus)).accessibilityIdentifier("settings.notificationStatus") }
                Button("Enable Routine Notifications") {
                    Task {
                        do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]); notificationError = nil }
                        catch { notificationError = error.localizedDescription }
                        await refreshNotificationStatus()
                    }
                }
                Text("If permission was denied, enable notifications for In-House Agent in System Settings.").font(.caption).foregroundStyle(.secondary)
                if let notificationError { Text(notificationError).textSelection(.enabled) }
            }
            Section("Conversation History") {
                Text("Conversations, model thinking, and tool previews are saved on this Mac. Delete conversations from the sidebar to remove their saved history.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $autoCheckUpdates).accessibilityIdentifier("settings.autoUpdates")
                Button("Check for Updates…") { updater.check() }.disabled(!updater.canCheck)
                if let error = updater.error { Text(error).foregroundStyle(.secondary) }
            }
        }.formStyle(.grouped).padding().frame(width: 600).navigationTitle("Settings")
            .task { await refreshNotificationStatus() }
    }
    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: notificationStatus = "Allowed"
        case .denied: notificationStatus = "Not allowed"
        case .notDetermined: notificationStatus = "Not requested"
        default: notificationStatus = "Unknown"
        }
    }
}
