import SwiftUI
import CryptoKit
import AppKit

@MainActor
final class SetupModel: ObservableObject {
    static let shared = SetupModel()
    @Published var pythonPath = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3") ? "/opt/homebrew/bin/python3" : "/usr/bin/python3"
    @Published var log = ""
    @Published var phase = String(localized: "Ready to set up")
    @Published var running = false
    @Published var error: String?
    @Published var completed = false
    @Published var dependenciesNeedUpdate = true
    private var process: Process?
    private var cancelled = false
    private var task: Task<Void, Never>?
    private var marker: URL { ServerModel.support.appendingPathComponent("requirements.sha256") }
    private var lock: URL? { Bundle.main.resourceURL?.appendingPathComponent("requirements.lock") }
    private var defaultModel: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".litert-lm/models/gemma4-26b/model.litertlm") }

    init() { refreshDependencyStatus() }

    func refreshDependencyStatus() {
        guard let digest = try? lockDigest(), let installed = try? String(contentsOf: marker, encoding: .utf8) else {
            dependenciesNeedUpdate = true
            return
        }
        dependenciesNeedUpdate = digest != installed || !FileManager.default.isExecutableFile(atPath: ServerModel.python.path)
    }

    private func lockDigest() throws -> String {
        guard let lock else { throw SetupError.missingRequirements }
        return SHA256.hash(data: try Data(contentsOf: lock)).map { String(format: "%02x", $0) }.joined()
    }

    func start() {
        guard !running else { return }
        cancelled = false
        completed = false
        running = true
        error = nil
        log = ""
        task = Task {
            defer { running = false; process = nil; task = nil }
            do {
                guard FileManager.default.isExecutableFile(atPath: pythonPath) else { throw SetupError.pythonUnavailable }
                guard let lock, FileManager.default.fileExists(atPath: lock.path) else { throw SetupError.missingRequirements }
                try FileManager.default.createDirectory(at: ServerModel.support, withIntermediateDirectories: true)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ServerModel.support.path)
                phase = String(localized: "Checking Python")
                try await run(executable: URL(fileURLWithPath: pythonPath), arguments: ["-c", "import sys, venv; print(sys.version)"])
                if !FileManager.default.isExecutableFile(atPath: ServerModel.python.path) {
                    phase = String(localized: "Creating Python environment")
                    try await run(executable: URL(fileURLWithPath: pythonPath), arguments: ["-m", "venv", ServerModel.support.appendingPathComponent("venv").path])
                }
                refreshDependencyStatus()
                if dependenciesNeedUpdate {
                    phase = String(localized: "Installing dependencies")
                    try await run(executable: ServerModel.python, arguments: ["-m", "pip", "install", "--disable-pip-version-check", "-r", lock.path])
                    try lockDigest().write(to: marker, atomically: true, encoding: .utf8)
                    refreshDependencyStatus()
                }
                let configured = UserDefaults.standard.string(forKey: "modelPath") ?? ""
                if !configured.isEmpty, FileManager.default.fileExists(atPath: configured) {
                    phase = String(localized: "Using existing model")
                } else {
                    if !FileManager.default.fileExists(atPath: defaultModel.path) {
                        phase = String(localized: "Downloading Gemma model")
                        try await run(executable: ServerModel.support.appendingPathComponent("venv/bin/litert-lm"), arguments: [
                            "import", "--from-huggingface-repo=litert-community/gemma-4-26B-A4B-it-litert-lm",
                            "gemma-4-26B-A4B-it-gpu.litertlm", "gemma4-26b"
                        ])
                    }
                    guard FileManager.default.fileExists(atPath: defaultModel.path) else { throw SetupError.modelMissing }
                    UserDefaults.standard.set(defaultModel.path, forKey: "modelPath")
                }
                try checkCancellation()
                phase = String(localized: "Setup complete")
                completed = true
            } catch {
                phase = cancelled ? String(localized: "Setup cancelled") : String(localized: "Setup failed")
                if !cancelled { self.error = error.localizedDescription }
            }
        }
    }

    func cancel() {
        cancelled = true
        phase = String(localized: "Cancelling setup")
        process?.terminate()
    }

    func stop() async {
        guard running else { return }
        let activeTask = task
        cancel()
        await activeTask?.value
    }

    private func checkCancellation() throws {
        if cancelled { throw CancellationError() }
    }

    private func run(executable: URL, arguments: [String]) async throws {
        try checkCancellation()
        let child = Process()
        // A stdlib-only supervisor survives an abrupt app exit and reaps the
        // command's isolated process group, including pip build subprocesses.
        child.executableURL = URL(fileURLWithPath: pythonPath)
        child.arguments = ["-u", "-c", Self.supervisor, String(ProcessInfo.processInfo.processIdentifier), executable.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PATH"] = ServerModel.support.appendingPathComponent("venv/bin").path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = pipe
        process = child
        append("\n$ \(executable.lastPathComponent) \(arguments.joined(separator: " "))\n")
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                let text = String(decoding: data, as: UTF8.self)
                Task { @MainActor in self?.append(text) }
            }
        }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            child.terminationHandler = { process in
                pipe.fileHandleForReading.readabilityHandler = nil
                let trailing = pipe.fileHandleForReading.readDataToEndOfFile()
                Task { @MainActor [weak self] in
                    if !trailing.isEmpty { self?.append(String(decoding: trailing, as: UTF8.self)) }
                    continuation.resume(returning: process.terminationStatus)
                }
            }
            do { try child.run() }
            catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                child.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        process = nil
        try checkCancellation()
        guard status == 0 else { throw SetupError.commandFailed(status) }
    }

    private func append(_ text: String) {
        log += text
        if log.count > 200_000 { log = String(log.suffix(200_000)) }
    }

    static let supervisor = #"""
import os, signal, subprocess, sys, time

owner = int(sys.argv[1])
stopping = False

def stop(signum, frame):
    global stopping
    stopping = True

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
child = None
code = 1
try:
    if os.getppid() != owner:
        sys.exit(130)
    child = subprocess.Popen(sys.argv[2:], stdin=subprocess.DEVNULL, start_new_session=True)
    while child.poll() is None and not stopping and os.getppid() == owner:
        time.sleep(0.1)
    code = child.returncode if child.returncode is not None else 130
finally:
    if child is not None:
        # Also clean descendants if their immediate parent already exited.
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        # Do not probe with signal 0: restricted launch environments may deny
        # probes while still permitting cleanup of this owned process group.
        time.sleep(2)
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except PermissionError:
            # macOS process restrictions can report EPERM for a vanished group.
            # A still-running direct child must never be treated as cleaned up.
            if child.poll() is None:
                raise
        child.wait()
sys.exit(code)
"""#
}

private enum SetupError: LocalizedError {
    case pythonUnavailable, missingRequirements, modelMissing
    case commandFailed(Int32)
    var errorDescription: String? {
        switch self {
        case .pythonUnavailable: String(localized: "Python is unavailable. Choose an installed Python 3 executable.")
        case .missingRequirements: String(localized: "The application is missing requirements.lock. Reinstall the application.")
        case .modelMissing: String(localized: "The model import finished without creating the expected model file. Check the setup log.")
        case .commandFailed(let status): String(localized: "Setup command failed with exit code \(status). Check the log for Python compatibility, network, or model access errors.")
        }
    }
}

struct SetupView: View {
    @StateObject private var setup = SetupModel.shared
    let onComplete: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up In-House Agent").font(.title)
            Text("Create a Python environment and download Gemma to this Mac. The model requires a large download and is stored separately from the application.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Python executable", text: $setup.pythonPath).accessibilityIdentifier("setup.pythonPath").disabled(setup.running)
                LabeledContent("Environment", value: ServerModel.support.appendingPathComponent("venv").path)
                LabeledContent("Dependencies", value: setup.dependenciesNeedUpdate ? String(localized: "Installation required") : String(localized: "Up to date"))
            }.formStyle(.grouped).fixedSize(horizontal: false, vertical: true)
            HStack {
                if setup.running { ProgressView().controlSize(.small) }
                Text(setup.phase).accessibilityAddTraits(.updatesFrequently)
            }
            if let error = setup.error {
                Label(error, systemImage: "exclamationmark.triangle").textSelection(.enabled)
            }
            ScrollView {
                Text(setup.log.isEmpty ? String(localized: "Setup output will appear here.") : setup.log)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }.frame(minHeight: 180).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Setup log")
            HStack {
                Spacer()
                if setup.running {
                    Button("Cancel Setup", role: .cancel) { setup.cancel() }
                } else if setup.completed {
                    Button("Done", action: onComplete).accessibilityIdentifier("setup.done").keyboardShortcut(.defaultAction)
                } else {
                    Button("Set Up Later", action: onComplete).keyboardShortcut(.cancelAction)
                    Button(LocalizedStringKey(setup.error == nil ? "Start Setup" : "Retry")) { setup.start() }.accessibilityIdentifier("setup.start").keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(minWidth: 640, minHeight: 560)
        .onDisappear { if setup.running { setup.cancel() } }
    }
}
