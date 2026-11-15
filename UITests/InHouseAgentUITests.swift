import XCTest
import AppKit

private enum UIControlError: Error { case foregroundLost }

// XCTest's runner has a container HOME even when the app is not sandboxed.
// Read the account database rather than deriving app paths from runner HOME.
private var applicationSupportURL: URL {
    let account = getpwuid(getuid())!
    return URL(fileURLWithPath: String(cString: account.pointee.pw_dir))
        .appendingPathComponent("Library/Application Support/InHouseAgent")
}

@MainActor
private func requireForeground(_ app: XCUIApplication) throws {
    guard app.state == .runningForeground,
          NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.taisei1989.inhouseagent" else {
        throw UIControlError.foregroundLost
    }
}


/// Run separately from the real-model suite; no model process is started.
final class ScaffoldUITests: XCTestCase {
    @MainActor
    func testSetupAndStandardSettings() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        // These are Foundation's standard, process-local preference overrides.
        // They do not modify the user's persisted settings.
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-autoStartServer", "NO"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        try requireForeground(app)
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Set up In-House Agent"].waitForExistence(timeout: 10),
                      "This first-run test requires an unconfigured app; it never clears user data.")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "setup.pythonPath").firstMatch.exists)
        XCTAssertTrue(app.buttons["Start Setup"].exists)
        XCTAssertTrue(app.buttons["Set Up Later"].exists)
        attach(app, name: "first-run-setup")
        try requireForeground(app)
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.textFields["settings.modelPath"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["settings.workspacePath"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "settings.autoStart").firstMatch.exists, app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "settings.autoUpdates").firstMatch.exists, app.debugDescription)
        attach(app, name: "standard-settings")
        try requireForeground(app)
        app.typeKey("w", modifierFlags: .command)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Run only after the parent verifies the model is installed and no other
/// model process is running. The separate InHouseAgentRuntimeUI scheme opts in.
final class RuntimeUITests: XCTestCase {
    @MainActor
    func testStreamingAndWriteApproval() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-autoStartServer", "NO"]
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("InHouseAgent-UITest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "fixture".write(to: workspace.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
        try "fixture".write(to: workspace.appendingPathComponent("beta.md"), atomically: true, encoding: .utf8)
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        try requireForeground(app)
        addTeardownBlock { @MainActor in app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        try requireForeground(app)
        if app.buttons["Set Up Later"].exists { app.buttons["Set Up Later"].click() }
        try requireForeground(app)
        app.typeKey(",", modifierFlags: .command)
        let workspaceField = app.textFields["settings.workspacePath"]
        XCTAssertTrue(workspaceField.waitForExistence(timeout: 10))
        let previousWorkspace = workspaceField.value as? String ?? ""
        let restoredWorkspace = URL(fileURLWithPath: previousWorkspace).lastPathComponent.hasPrefix("InHouseAgent-UITest-")
            ? applicationSupportURL.appendingPathComponent("Workspace").path
            : previousWorkspace
        try replace(workspaceField, with: workspace.path, app: app)
        XCTAssertEqual(workspaceField.value as? String, workspace.path)
        try requireForeground(app)
        app.typeKey("w", modifierFlags: .command)
        addTeardownBlock { @MainActor in
            // Restore the setting through the same production UI; retain the
            // test fixture as evidence instead of deleting potentially useful data.
            try requireForeground(app)
            app.typeKey(",", modifierFlags: .command)
            try requireForeground(app)
            if workspaceField.waitForExistence(timeout: 5) {
                try self.replace(workspaceField, with: restoredWorkspace, app: app)
                try requireForeground(app)
                app.typeKey("w", modifierFlags: .command)
            }
        }
        try requireForeground(app)
        app.menuBars.menuBarItems["Server"].click()
        try requireForeground(app)
        app.menuBars.menuBarItems["Server"].menus.menuItems["Start Server"].click()
        try requireForeground(app)
        app.descendants(matching: .any).matching(identifier: "nav.server").firstMatch.click()
        let ready = NSPredicate { _, _ in
            app.descendants(matching: .any).matching(identifier: "server.status").allElementsBoundByIndex.contains { $0.label.contains("Ready") || ($0.value as? String)?.contains("Ready") == true }
                || app.staticTexts["Ready"].exists
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 120), .completed, app.debugDescription)
        try requireForeground(app)
        app.descendants(matching: .any).matching(identifier: "nav.chat").firstMatch.click()
        let input = app.descendants(matching: .any).matching(identifier: "chat.input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        try replace(input, with: "Use list_directory to list the files in the workspace. Report the exact file names. Then write a 150-word explanation of how to inspect these files safely without modifying them.", app: app)
        try requireForeground(app)
        app.buttons["chat.send"].click()
        var visibleResponseStates = Set<String>()
        let listed = NSPredicate { _, _ in
            let responses = app.descendants(matching: .any).matching(identifier: "chat.assistant").allElementsBoundByIndex
            let texts = responses.map { ($0.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? $0.label }
            for text in texts where app.buttons["Cancel"].exists && !text.isEmpty && text != "Thinking…" {
                visibleResponseStates.insert(text)
            }
            return !responses.isEmpty && app.buttons["chat.send"].exists
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: listed, object: nil)], timeout: 300), .completed, app.debugDescription)
        waitForSend(app)
        let answerTexts = app.descendants(matching: .any).matching(identifier: "chat.assistant").allElementsBoundByIndex.map { ($0.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? $0.label }
        XCTAssertTrue(answerTexts.contains { $0.contains("alpha.txt") && $0.contains("beta.md") }, "Synthetic workspace reply: \(answerTexts)")
        let streamEvidence = XCTAttachment(string: "Distinct visible response states before completion: \(visibleResponseStates.count)")
        streamEvidence.name = "streaming-observation"
        streamEvidence.lifetime = .keepAlways
        add(streamEvidence)
        XCTAssertGreaterThanOrEqual(visibleResponseStates.count, 2, "At least two changing response states must be visible while generation is active")
        let output = workspace.appendingPathComponent("approved.txt")
        try replace(input, with: "Use create_file to create approved.txt in the workspace with exactly the text APPROVED. Do not use a shell command.", app: app)
        try requireForeground(app)
        app.buttons["chat.send"].click()
        XCTAssertTrue(app.buttons["approval.allow"].waitForExistence(timeout: 300))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "The file must not exist before approval")
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "write-awaiting-approval"
        attachment.lifetime = .keepAlways
        add(attachment)
        let details = app.descendants(matching: .any).matching(identifier: "approval.details").firstMatch
        XCTAssertTrue((details.label + ((details.value as? String) ?? "")).contains("approved.txt"))
        try requireForeground(app)
        app.buttons["approval.allow"].click()
        let written = NSPredicate { _, _ in FileManager.default.fileExists(atPath: output.path) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: written, object: nil)], timeout: 120), .completed)
        XCTAssertTrue(try String(contentsOf: output, encoding: .utf8).contains("APPROVED"))
        waitForSend(app)
        try requireForeground(app)
        app.menuBars.menuBarItems["Server"].click()
        try requireForeground(app)
        app.menuBars.menuBarItems["Server"].menus.menuItems["Stop Server"].click()
        try requireForeground(app)
        app.descendants(matching: .any).matching(identifier: "nav.server").firstMatch.click()
        let stopped = NSPredicate { _, _ in
            app.descendants(matching: .any).matching(identifier: "server.status").allElementsBoundByIndex.contains {
                $0.label.contains("Stopped") || ($0.value as? String)?.contains("Stopped") == true
            }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: stopped, object: nil)], timeout: 30), .completed)
    }

    @MainActor
    private func replace(_ element: XCUIElement, with text: String, app: XCUIApplication) throws {
        try requireForeground(app)
        element.click()
        try requireForeground(app)
        element.typeKey("a", modifierFlags: .command)
        try requireForeground(app)
        element.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        try requireForeground(app)
        if !text.isEmpty { element.typeText(text) }
    }

    @MainActor
    private func waitForSend(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["chat.send"].waitForExistence(timeout: 300))
    }
}

/// Installs the real locked dependencies through the production setup wizard.
/// Run explicitly, once, after ScaffoldUITests and before RuntimeUITests.
final class SetupUITests: XCTestCase {
    @MainActor
    func testInstallEnvironmentWithWizard() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-autoStartServer", "NO"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        try requireForeground(app)
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["setup.start"].waitForExistence(timeout: 20))
        try requireForeground(app)
        app.buttons["setup.start"].click()
        XCTAssertTrue(app.buttons["Cancel Setup"].waitForExistence(timeout: 5) || app.buttons["setup.done"].exists || app.buttons["Retry"].exists, app.debugDescription)
        let finished = NSPredicate { _, _ in
            app.buttons["setup.done"].exists || app.buttons["Retry"].exists
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: finished, object: nil)], timeout: 900), .completed)
        XCTAssertTrue(app.buttons["setup.done"].exists, app.debugDescription)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "setup-completed"
        attachment.lifetime = .keepAlways
        add(attachment)
        try requireForeground(app)
        app.buttons["setup.done"].click()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "chat.input").firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Stopped"].exists, "The setup check must not start a concurrent model.")
    }
}

/// Owns only sidecar PIDs read from this app's public connection descriptor.
/// Never reads the session token. Run without another model task in progress.
final class LifecycleUITests: XCTestCase {
    @MainActor
    func testNormalQuitReapsOwnedProcesses() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-autoStartServer", "NO"]
        app.launch(); app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        addTeardownBlock { @MainActor in app.terminate() }
        try requireForeground(app)
        app.descendants(matching: .any).matching(identifier: "nav.server").firstMatch.click()
        try command("Start Server", app: app)
        waitState("Ready", app: app)
        let pid = try currentPID()
        let children = descendants(of: pid)
        record("Observed sidecar plus \(children.count) child processes before normal quit")
        try requireForeground(app); app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 30))
        let stopped = NSPredicate { _, _ in ([pid] + children).allSatisfy { !self.alive($0) } }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: stopped, object: nil)], timeout: 20), .completed)
        record("Normal Command-Q reaped sidecar and all observed child processes")
    }

    @MainActor
    func testRestartCrashRecoveryAndQuit() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-autoStartServer", "NO"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        try requireForeground(app)
        addTeardownBlock { @MainActor in app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        try requireForeground(app)
        app.typeKey(",", modifierFlags: .command)
        let field = app.textFields["settings.workspacePath"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let saved = field.value as? String ?? ""
        let settled = NSPredicate { _, _ in app.dialogs.count == 0 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 10), .completed, app.debugDescription)
        if saved.contains("com.taisei1989.inhouseagent.uitests.xctrunner") || URL(fileURLWithPath: saved).lastPathComponent.hasPrefix("InHouseAgent-UITest-") {
            try requireForeground(app); field.click()
            try requireForeground(app); field.typeKey("a", modifierFlags: .command)
            try requireForeground(app); field.typeText(applicationSupportURL.appendingPathComponent("Workspace").path)
        }
        try requireForeground(app); app.typeKey("w", modifierFlags: .command)
        try requireForeground(app)
        app.descendants(matching: .any).matching(identifier: "nav.server").firstMatch.click()
        try command("Start Server", app: app)
        waitState("Ready", app: app)
        let initial = try currentPID()
        try command("Restart Server", app: app)
        waitPIDChange(from: initial)
        waitState("Ready", app: app)
        let restarted = try currentPID()
        XCTAssertNotEqual(initial, restarted)
        XCTAssertFalse(alive(initial))
        record("Manual restart changed PID and returned Ready")
        XCTAssertEqual(kill(restarted, SIGKILL), 0)
        waitPIDChange(from: restarted)
        waitState("Ready", app: app)
        XCTAssertFalse(alive(restarted))
        record("Forced crash automatically restarted and returned Ready")

        // A manual restart resets the crash budget. Kill each replacement as
        // soon as its descriptor appears, staying inside the 60-second window.
        let recovering = try currentPID()
        try command("Restart Server", app: app)
        waitPIDChange(from: recovering)
        var crashed = try currentPID()
        for index in 0..<3 {
            XCTAssertEqual(kill(crashed, SIGKILL), 0)
            if index < 2 { waitPIDChange(from: crashed); crashed = try currentPID() }
        }
        waitState("Error", app: app, timeout: 30)
        XCTAssertFalse(alive(crashed))
        record("Three rapid crashes paused automatic recovery")
        try command("Start Server", app: app)
        waitState("Ready", app: app)
        let finalPID = try currentPID()
        let ownedDescendants = descendants(of: finalPID)
        try requireForeground(app)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 30))
        let allExited = NSPredicate { _, _ in
            !self.alive(finalPID) && ownedDescendants.allSatisfy { !self.alive($0) }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: allExited, object: nil)], timeout: 20), .completed)
        record("Normal quit reaped sidecar and observed descendants")
    }

    private var descriptor: URL {
        applicationSupportURL.appendingPathComponent("server.json")
    }
    private func currentPID() throws -> Int32 {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: descriptor)) as? [String: Any]
        guard let pid = object?["pid"] as? Int32, pid > 1 else { throw NSError(domain: "UITestDescriptor", code: 1) }
        return pid
    }
    private func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
    private func waitPIDChange(from old: Int32) {
        let changed = NSPredicate { _, _ in
            guard let pid = try? self.currentPID() else { return false }
            return pid != old && self.alive(pid)
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: changed, object: nil)], timeout: 35), .completed)
    }
    @MainActor
    private func command(_ name: String, app: XCUIApplication) throws {
        try requireForeground(app)
        app.menuBars.menuBarItems["Server"].click()
        try requireForeground(app)
        app.menuBars.menuBarItems["Server"].menus.menuItems[name].click()
    }
    @MainActor
    private func waitState(_ title: String, app: XCUIApplication, timeout: TimeInterval = 120) {
        let predicate = NSPredicate { _, _ in
            app.descendants(matching: .any).matching(identifier: "server.status").allElementsBoundByIndex.contains {
                $0.label.contains(title) || ($0.value as? String)?.contains(title) == true
            }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout), .completed, app.debugDescription)
    }
    private func record(_ text: String) {
        let item = XCTAttachment(string: text)
        item.name = "lifecycle-check"
        item.lifetime = .keepAlways
        add(item)
    }

}

private func descendants(of pid: Int32) -> [Int32] {
    var observed = Set<Int32>()
    var pending = [pid]
    while let parent = pending.popLast() {
        var children = [Int32](repeating: 0, count: 1024)
        let size = Int32(children.count * MemoryLayout<Int32>.stride)
        let result = children.withUnsafeMutableBytes { proc_listchildpids(parent, $0.baseAddress, size) }
        guard result > 0 else { continue }
        for child in children where child > 1 && child != pid && observed.insert(child).inserted {
            pending.append(child)
        }
    }
    return Array(observed)
}

/// Requires an installed 0.1.0 and an authenticated/signed published 0.1.1 feed.
/// Never installs a bundle itself; every update action uses Sparkle's real UI.
final class UpdateUITests: XCTestCase {
    @MainActor
    func testInstalledReleaseUpdatesInPlace() throws {
        continueAfterFailure = false
        let installedURL = URL(fileURLWithPath: "/Applications/In-House Agent.app", isDirectory: true)
        func installedVersion() -> String? {
            guard let data = try? Data(contentsOf: installedURL.appendingPathComponent("Contents/Info.plist")),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return nil }
            return plist["CFBundleShortVersionString"] as? String
        }
        XCTAssertEqual(installedVersion(), "0.1.0", "Install the actual signed baseline before running this suite")
        let app = XCUIApplication(url: installedURL)
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-autoStartServer", "NO", "-autoCheckUpdates", "NO"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        try requireForeground(app)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleURL?.standardizedFileURL, installedURL.standardizedFileURL,
                       "The update target must be the installed Release, never the Debug product")
        var succeeded = false
        addTeardownBlock { @MainActor in if !succeeded { app.terminate() } }
        try requireForeground(app)
        app.descendants(matching: .any).matching(identifier: "nav.server").firstMatch.click()
        try requireForeground(app); app.menuBars.menuBarItems["Server"].click()
        try requireForeground(app); app.menuBars.menuBarItems["Server"].menus.menuItems["Start Server"].click()
        let ready = NSPredicate { _, _ in
            app.descendants(matching: .any).matching(identifier: "server.status").allElementsBoundByIndex.contains {
                $0.label.contains("Ready") || ($0.value as? String)?.contains("Ready") == true
            }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 120), .completed)
        let descriptor = try JSONSerialization.jsonObject(with: Data(contentsOf: applicationSupportURL.appendingPathComponent("server.json"))) as? [String: Any]
        let oldPID = try XCTUnwrap(descriptor?["pid"] as? Int32)
        XCTAssertGreaterThan(oldPID, 1)
        let oldChildren = descendants(of: oldPID)
        try requireForeground(app)
        app.menuBars.menuBarItems["In-House Agent"].click()
        let check = app.menuBars.menuBarItems["In-House Agent"].menus.menuItems["Check for Updates…"]
        XCTAssertTrue(check.isEnabled)
        try requireForeground(app)
        check.click()
        let install = app.buttons["Install Update"]
        XCTAssertTrue(install.waitForExistence(timeout: 90), app.debugDescription)
        let offer = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        offer.name = "sparkle-update-offer"
        offer.lifetime = .keepAlways
        add(offer)
        try requireForeground(app)
        install.click()
        let relaunch = app.buttons["Install and Relaunch"]
        XCTAssertTrue(relaunch.waitForExistence(timeout: 180), app.debugDescription)
        try requireForeground(app)
        relaunch.click()
        let updated = NSPredicate { _, _ in installedVersion() == "0.1.1" }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: updated, object: nil)], timeout: 120), .completed)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
        try requireForeground(app)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleURL?.standardizedFileURL, installedURL.standardizedFileURL)
        XCTAssertEqual(installedVersion(), "0.1.1")
        let stopped = NSPredicate { _, _ in
            ([oldPID] + oldChildren).allSatisfy { kill($0, 0) != 0 && errno == ESRCH }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: stopped, object: nil)], timeout: 20), .completed)
        let result = XCTAttachment(string: "Installed /Applications/In-House Agent.app changed from 0.1.0 to 0.1.1 through the app's Sparkle UI and relaunched from the installed path.")
        result.name = "installed-update-result"
        result.lifetime = .keepAlways
        add(result)
        succeeded = true
    }
}

/// Requests notification permission through the installed app's real Settings.
/// Delivery is independently checked by the production routine helper.
final class NotificationUITests: XCTestCase {
    @MainActor
    func testInstalledNotificationPermission() throws {
        continueAfterFailure = false
        let url = URL(fileURLWithPath: "/Applications/In-House Agent.app")
        let app = XCUIApplication(url: url)
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-autoStartServer", "NO", "-autoCheckUpdates", "NO"]
        app.launch(); app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        try requireForeground(app)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleURL?.standardizedFileURL, url.standardizedFileURL)
        addTeardownBlock { @MainActor in app.terminate() }
        try requireForeground(app); app.typeKey(",", modifierFlags: .command)
        let enable = app.buttons["Enable Routine Notifications"]
        XCTAssertTrue(enable.waitForExistence(timeout: 15), app.debugDescription)
        for _ in 0..<4 where !enable.isHittable {
            try requireForeground(app)
            app.windows.firstMatch.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -300)
        }
        XCTAssertTrue(enable.isHittable, app.debugDescription)
        try requireForeground(app); enable.click()
        let allow = app.buttons["Allow"]
        if allow.waitForExistence(timeout: 8) {
            try requireForeground(app)
            allow.click()
        }
        let result = XCTAttachment(string: app.debugDescription)
        result.name = "notification-permission-app-AX"
        result.lifetime = .keepAlways
        add(result)
    }
}

final class ModernUITests: XCTestCase {
    @MainActor
    func testJapaneseToolsAndPersistentConversation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP", "-autoStartServer", "NO"]
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("InHouseAgent-UITest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try "synthetic fixture".write(to: fixture.appendingPathComponent("modern-ui.txt"), atomically: true, encoding: .utf8)
        let marker = "UI-" + UUID().uuidString.prefix(8)
        app.launch(); app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        addTeardownBlock { @MainActor in app.terminate() }
        try requireForeground(app); app.typeKey(",", modifierFlags: .command)
        let field = app.textFields["settings.workspacePath"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let original = field.value as? String ?? ""
        try replace(field, text: fixture.path, app: app)
        try requireForeground(app); app.typeKey("w", modifierFlags: .command)
        addTeardownBlock { @MainActor in
            try requireForeground(app); app.typeKey(",", modifierFlags: .command)
            if field.waitForExistence(timeout: 10) { try self.replace(field, text: original, app: app) }
            try requireForeground(app); app.typeKey("w", modifierFlags: .command)
        }
        XCTAssertEqual(app.buttons["chat.new"].label, "新規チャット")
        try requireForeground(app); app.buttons["chat.new"].click()
        try requireForeground(app); app.menuBars.menuBarItems["サーバー"].click()
        try requireForeground(app); app.menuBars.menuBarItems["サーバー"].menus.menuItems["サーバーを起動"].click()
        try requireForeground(app); app.descendants(matching: .any).matching(identifier: "nav.server").firstMatch.click()
        let ready = NSPredicate { _, _ in app.descendants(matching: .any).matching(identifier: "server.status").allElementsBoundByIndex.contains { $0.label.contains("準備完了") || ($0.value as? String)?.contains("準備完了") == true } }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 120), .completed)
        try requireForeground(app); app.descendants(matching: .any).matching(identifier: "nav.chat").firstMatch.click()
        let input = app.descendants(matching: .any).matching(identifier: "chat.input").firstMatch
        try replace(input, text: "\(marker) Use list_directory to list the files in the workspace. Report the exact file names without modifying anything.", app: app)
        try requireForeground(app); app.buttons["chat.send"].click()
        let answered = NSPredicate { _, _ in
            app.buttons["chat.send"].exists && app.descendants(matching: .any).matching(identifier: "chat.assistant").allElementsBoundByIndex.contains { ($0.value as? String ?? $0.label).contains("modern-ui.txt") }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: answered, object: nil)], timeout: 300), .completed, app.debugDescription)
        let thinking = app.descendants(matching: .any).matching(identifier: "chat.thinking").firstMatch
        if thinking.exists { try requireForeground(app); thinking.click() }
        let disclosure = app.descendants(matching: .any).matching(identifier: "chat.tools").firstMatch
        XCTAssertTrue(disclosure.exists, app.debugDescription)
        try requireForeground(app); disclosure.click()
        let tool = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "list_directory")).firstMatch
        XCTAssertTrue(tool.exists, app.debugDescription)
        try requireForeground(app); tool.click()
        XCTAssertTrue(app.staticTexts["結果"].waitForExistence(timeout: 5), app.debugDescription)
        let evidence = XCTAttachment(string: thinking.exists ? "SDK thinking disclosure exists and was expanded; tool activity expanded." : "SDK provided no thinking text for this response; tool activity expanded.")
        evidence.name = "modern-disclosures"; evidence.lifetime = .keepAlways; add(evidence)
        screenshot(app, name: "japanese-tool-result")
        try requireForeground(app); app.buttons["chat.new"].click()
        let search = app.textFields["history.search"]
        try replace(search, text: String(marker), app: app)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.item.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let identifier = row.identifier
        try requireForeground(app); row.click()
        XCTAssertFalse(input.isEnabled)
        XCTAssertTrue(app.buttons["会話を続ける"].exists)
        screenshot(app, name: "japanese-saved-conversation")
        try requireForeground(app); app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 30))
        app.launch(); app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        let restored = app.buttons[identifier]
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        try requireForeground(app); restored.click()
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "chat.input").firstMatch.isEnabled)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "chat.assistant").allElementsBoundByIndex.contains { ($0.value as? String ?? $0.label).contains("modern-ui.txt") })
        XCTAssertTrue(app.buttons["サーバーを起動"].exists)
        screenshot(app, name: "japanese-restored-history")
    }
    @MainActor private func replace(_ element: XCUIElement, text: String, app: XCUIApplication) throws {
        try requireForeground(app); element.click()
        try requireForeground(app); element.typeKey("a", modifierFlags: .command)
        try requireForeground(app); element.typeText(text)
    }
    @MainActor private func screenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

/// Changes only this application's OS notification authorization.
final class SystemNotificationUITests: XCTestCase {
    @MainActor
    func testAuthorizeOnlyInHouseNotifications() throws {
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        XCTAssertTrue(NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!))
        settings.activate()
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 15))
        func guardSettings() throws {
            guard settings.state == .runningForeground,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences"
            else { throw UIControlError.foregroundLost }
        }
        let row = settings.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "In-House Agent", "InHouseAgent")).firstMatch
        _ = row.waitForExistence(timeout: 3)
        for _ in 0..<10 where !row.exists {
            try guardSettings()
            let views = settings.windows.firstMatch.scrollViews
            XCTAssertGreaterThan(views.count, 0)
            views.element(boundBy: views.count - 1).scroll(byDeltaX: 0, deltaY: -450)
        }
        XCTAssertTrue(row.waitForExistence(timeout: 3), "In-House Agent must be listed in the OS Notifications pane")
        try guardSettings(); row.click()
        let controls = settings.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR label == %@", "Allow notifications", "通知を許可"))
        let control = controls.firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 10), "The selected app must expose its Allow notifications control")
        let evidence = controls.allElementsBoundByIndex.map { "type=\($0.elementType.rawValue) label=\($0.label) value=\($0.value ?? "nil")" }.joined(separator: "\n")
        let item = XCTAttachment(string: evidence); item.name = "inhouse-notification-controls"; item.lifetime = .keepAlways; add(item)
        if control.value as? String == "0" {
            try guardSettings(); control.click()
        }
        XCTAssertEqual(control.value as? String, "1", "Only the selected app's notification permission should be enabled")
    }
}
