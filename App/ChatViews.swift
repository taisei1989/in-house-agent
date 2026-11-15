import SwiftUI
import AppKit

struct ChatWorkspaceView: View {
    @EnvironmentObject var server: ServerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var prompt: String
    @State private var followResponse = true
    @State private var confirmContinue = false
    @State private var confirmRetry = false
    private var workspace: String { UserDefaults.standard.string(forKey: "workspacePath") ?? ServerModel.defaultWorkspace.path }
    private var history: ConversationRecord? { server.conversations.first { $0.id == server.currentConversationID } }
    private var displayedBackend: String { server.viewingHistory ? (history?.backend ?? server.activeBackend) : server.activeBackend }
    private var displayedModel: String { server.viewingHistory ? (history?.model ?? server.modelName) : server.modelName }
    private var displayedConnection: LocalizedStringKey {
        switch displayedBackend { case "google": "Google cloud"; case "openai": "OpenAI-compatible cloud"; default: "Local model" }
    }
    private var canSend: Bool { server.state == .ready && !server.lifecycleBusy && !server.configurationInvalidated && !server.resettingChat && !server.viewingHistory }

    var body: some View {
        VStack(spacing: 0) {
            contextHeader
            Divider()
            if server.messages.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("What would you like to work on?").font(.title2.weight(.semibold))
                    Text("Ask about files, make a change, or plan your next task.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("List files in this workspace") { prompt = String(localized: "List the files in my workspace.") }
                        .buttonStyle(.bordered).disabled(server.viewingHistory)
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcript
            }
            if let error = server.error ?? server.historyError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).textSelection(.enabled)
                    .frame(maxWidth: 760, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 8)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .alert("Continue with saved history?", isPresented: $confirmContinue) {
            Button("Cancel", role: .cancel) { }
            Button("Continue") { server.continueConversation() }
        } message: {
            Text("This starts a new model session with up to the most recent 16,000 characters of this conversation. Previous tool operations are not replayed. History will be sent to the connection shown below.")
            Text(server.connectionLabel)
            Text(server.modelName)
            Text(workspace)
        }
        .alert("Send the request again?", isPresented: $confirmRetry) {
            Button("Cancel", role: .cancel) { }
            Button("Send Again") { if let text = server.lastUserPrompt { followResponse = true; server.send(text) } }
        } message: { Text("This starts a new execution. Previously completed file changes or commands could run again; review any approval request carefully.") }
    }

    private var contextHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Label(displayedConnection, systemImage: displayedBackend == "litert" ? "desktopcomputer" : "cloud")
                if !displayedModel.isEmpty { Text(displayedModel).lineLimit(1).truncationMode(.middle) }
                Spacer(minLength: 8)
                if server.viewingHistory { Label("Saved conversation", systemImage: "clock.arrow.circlepath") }
            }.font(.callout).foregroundStyle(.secondary)
            Label(URL(fileURLWithPath: server.viewingHistory ? (history?.workspace ?? workspace) : workspace).lastPathComponent, systemImage: "folder")
                .font(.caption).foregroundStyle(.secondary).help(server.viewingHistory ? (history?.workspace ?? workspace) : workspace)
                .accessibilityLabel(Text("Workspace"))
                .accessibilityValue(server.viewingHistory ? (history?.workspace ?? workspace) : workspace)
        }.frame(maxWidth: 760, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 12).frame(maxWidth: .infinity)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ForEach(server.messages) { message in ChatTurnView(message: message).id(message.id) }
                        Color.clear.frame(height: 1).id("conversation-bottom")
                    }.frame(maxWidth: 760).padding(.horizontal, 24).padding(.vertical, 24).frame(maxWidth: .infinity)
                }
                HStack {
                    Toggle("Follow response", isOn: $followResponse).toggleStyle(.checkbox).font(.caption)
                        .help("Turn off to read earlier messages while a response is arriving.")
                    Spacer()
                    Button("Latest", systemImage: "arrow.down") { scrollToBottom(proxy) }.font(.caption)
                    if !server.sending && !server.viewingHistory && server.lastUserPrompt != nil {
                        Button("Send Again", systemImage: "arrow.clockwise") { confirmRetry = true }.font(.caption).disabled(!canSend)
                    }
                }.foregroundStyle(.secondary).frame(maxWidth: 760).padding(.horizontal, 24).padding(.bottom, 8).frame(maxWidth: .infinity)
            }
            .onChange(of: server.messages.last?.text) { _, _ in if followResponse { proxy.scrollTo("conversation-bottom", anchor: .bottom) } }
            .onChange(of: server.messages.count) { _, _ in if followResponse { proxy.scrollTo("conversation-bottom", anchor: .bottom) } }
            .onChange(of: server.currentConversationID) { _, _ in followResponse = true; proxy.scrollTo("conversation-bottom", anchor: .bottom) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if reduceMotion { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
        else { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("conversation-bottom", anchor: .bottom) } }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if server.viewingHistory {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Viewing saved history").font(.callout.weight(.medium))
                        Text("Continue in a new model session to send another message.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if server.state == .stopped || server.state == .error {
                        Button("Start Server") { server.start() }.disabled(server.lifecycleBusy)
                    } else {
                        Button("Continue Conversation") { confirmContinue = true }.disabled(server.sending || server.resettingChat || server.state != .ready)
                    }
                }
            } else if server.state != .ready || server.configurationInvalidated || server.resettingChat {
                HStack {
                    Label(server.state.title, systemImage: server.state.symbol).font(.caption)
                    if server.state == .stopped || server.state == .error {
                        Button("Start Server") { server.start() }.controlSize(.small).disabled(server.lifecycleBusy)
                    } else if server.state == .loading_model || server.state == .starting {
                        ProgressView().controlSize(.mini)
                        if let date = server.startedAt { Text(date, style: .timer).font(.caption.monospacedDigit()) }
                    }
                    Spacer()
                }.foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Message", text: $prompt, axis: .vertical).lineLimit(1...8).textFieldStyle(.plain)
                    .accessibilityLabel("Message").accessibilityIdentifier("chat.input").disabled(server.viewingHistory)
                if server.sending {
                    Button("Cancel", systemImage: "stop.fill") { server.cancelChat() }
                        .labelStyle(.iconOnly).buttonStyle(.bordered).help("Stop this response")
                } else {
                    Button("Send", systemImage: "arrow.up") { followResponse = true; server.send(prompt); prompt = "" }
                        .labelStyle(.iconOnly).buttonStyle(.borderedProminent).accessibilityIdentifier("chat.send")
                        .keyboardShortcut(.return, modifiers: .command).help("Send (⌘Return)")
                        .disabled(!canSend || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(14).background(.background, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.quaternary))
            Text("File changes and commands require your approval. ⌘Return to send.").font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: 760).padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 16).frame(maxWidth: .infinity).background(.bar)
    }
}

struct ChatTurnView: View {
    let message: ChatMessage
    @State private var copied = false
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.user { Spacer(minLength: 64) }
            VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: message.user ? "person.crop.circle" : "sparkles").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(LocalizedStringKey(message.user ? "You" : "Assistant")).font(.callout.weight(.semibold))
                Spacer()
                if !message.user { AgentStatusView(status: message.status) }
            }
            if !message.user {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Text provided by the model through the SDK. It may be incomplete or incorrect.").font(.caption).foregroundStyle(.secondary)
                        if message.thought.isEmpty {
                            Text("This model connection has not provided thinking text.").font(.callout).foregroundStyle(.secondary)
                        } else {
                            Text(message.thought).font(.callout).textSelection(.enabled)
                        }
                        if message.thoughtTruncated { Text("Some content was omitted from this preview.").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.top, 8)
                } label: { Label("Model thinking", systemImage: "brain").font(.caption).foregroundStyle(.secondary) }
                .accessibilityIdentifier("chat.thinking")
            }
            if !message.tools.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) { ForEach(message.tools) { ToolRunView(tool: $0) } }.padding(.top, 8)
                } label: { Label("Tool activity (\(message.tools.count))", systemImage: "wrench.and.screwdriver").font(.caption).foregroundStyle(.secondary) }
                .accessibilityIdentifier("chat.tools")
            }
            if let failure = message.failure {
                Label(failure, systemImage: "exclamationmark.triangle").font(.callout).textSelection(.enabled)
            }
            if !message.text.isEmpty {
                ChatMarkdownView(text: message.text)
                    .accessibilityElement(children: .ignore).accessibilityLabel(Text(message.text))
                    .accessibilityIdentifier(message.user ? "chat.user" : "chat.assistant")
            }
            if !message.text.isEmpty {
                HStack(spacing: 12) {
                    Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string); copied = true
                    }.buttonStyle(.borderless).font(.caption).help("Copy message")
                    Text(message.createdAt, style: .time).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.padding(message.user ? 16 : 0).frame(maxWidth: .infinity, alignment: .leading)
            .background { if message.user { RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.04)) } }
        }
    }
}

struct AgentStatusView: View {
    let status: String
    private var title: LocalizedStringKey {
        switch status {
        case "responding", "running": "Working"
        case "waiting": "Awaiting approval"
        case "cancelled": "Stopped"
        case "unknown": "Outcome unknown"
        case "error", "failed": "Failed"
        case "denied": "Denied"
        default: "Completed"
        }
    }
    private var symbol: String {
        switch status {
        case "responding", "running": "ellipsis.circle"
        case "waiting": "hand.raised"
        case "cancelled": "stop.circle"
        case "unknown": "questionmark.circle"
        case "error", "failed": "exclamationmark.triangle"
        case "denied": "hand.raised.slash"
        default: "checkmark.circle"
        }
    }
    var body: some View { Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary) }
}

struct ToolRunView: View {
    let tool: ToolActivity
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                if !tool.args.isEmpty { preview("Arguments", tool.args) }
                if !tool.result.isEmpty { preview("Result", tool.result) }
                if !tool.error.isEmpty { preview("Error details", tool.error) }
                if tool.truncated { Text("Some content was omitted from this preview.").font(.caption).foregroundStyle(.secondary) }
            }.padding(.top, 8)
        } label: {
            HStack { Text(tool.name).font(.system(.callout, design: .monospaced)); Spacer(); AgentStatusView(status: tool.status) }
        }.accessibilityIdentifier("chat.tool.run.\(tool.id)")
            .padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
    private func preview(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
                }.buttonStyle(.borderless).labelStyle(.iconOnly).help("Copy details")
            }
            ScrollView(.horizontal) { Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(8).accessibilityIdentifier("chat.tool.preview") }
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// Keep fenced code selectable and monospaced without treating generated HTML as UI.
struct ChatMarkdownView: View {
    let text: String
    private struct Block: Identifiable { let id: Int; let text: String; let code: Bool }
    private var blocks: [Block] {
        var blocks: [Block] = [], lines: [String] = []
        var code = false
        func append() { if !lines.isEmpty { blocks.append(Block(id: blocks.count, text: lines.joined(separator: "\n"), code: code)); lines = [] } }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") { append(); code.toggle() } else { lines.append(line) }
        }
        append(); return blocks
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                if block.code {
                    ScrollView(.horizontal) { Text(block.text).font(.system(.body, design: .monospaced)).textSelection(.enabled).padding(12) }
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    Text((try? AttributedString(markdown: block.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block.text))
                        .textSelection(.enabled).lineSpacing(4)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
