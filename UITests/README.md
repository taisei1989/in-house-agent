# Native macOS UI checks

The test suites operate the production SwiftUI controls through XCTest. They do
not install hooks or add control endpoints to the application. They use
Foundation launch-argument defaults to select English and suppress automatic
model startup only within the launched process.

Generate the project, then run the first-run suite before completing setup:

```sh
python3 scripts/generate_project.py
xcodebuild -project InHouseAgent.xcodeproj -scheme InHouseAgentScaffoldUI \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build \
  -resultBundlePath /tmp/InHouseAgent-ScaffoldUI.xcresult test
```

The first-run test intentionally fails if setup is already complete. It never
clears existing application data to manufacture a first-run state. Screenshots
of setup and Settings are attached to the result bundle.

To install the real pinned dependencies using the wizard, explicitly run
`InHouseAgentSetupUI` with the same `xcodebuild test` options and a different
result-bundle path. This suite creates the application's environment and reuses
an already downloaded model when present. It does not start the model server.

After real setup has completed, run the real-model suite **only when no other
Gemma process is running**:

```sh
xcodebuild -project InHouseAgent.xcodeproj -scheme InHouseAgentRuntimeUI \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build \
  -resultBundlePath /tmp/InHouseAgent-RuntimeUI.xcresult test
```

This creates a uniquely named fixture directory in the system temporary folder,
sets the workspace through Settings, starts the real server through the menu,
asks for known filenames, and requests creation of `approved.txt`. It checks
that the file does not exist while the approval sheet is visible, approves the
operation, and verifies the resulting contents. The workspace setting is
restored through Settings; fixtures and result screenshots remain as evidence.

The response test requires the real answer and at least two distinct visible
response states while generation is active. It does not prove notification
arrival, server crash recovery, or a Sparkle update; those require their own
runtime observations.

`InHouseAgentLifecycleUI` is a separate, explicit real-model suite for start,
manual restart, automatic crash recovery, the three-crash circuit breaker,
manual recovery, and normal Command-Q cleanup. It reads only public PID/port
metadata from `server.json`, never the Keychain token, and sends signals only
to the recorded sidecar PID. It checks disappearance of observed descendant
PIDs after normal quit. Some XCTest runners hide other processes from both
`Process` and `proc_listchildpids`; in that environment, independently observe
the recorded sidecar and its descendants using host process metadata, and
confirm their disappearance after the UI test quits. Run
`python3 UITests/observe_sidecar_exit.py` concurrently for this PID-only host
check; it requires at least two observed processes and zero survivors. An empty in-runner
descendant list alone is not evidence of child-process cleanup. Run it without
any other model task.

Screenshots are captured from the application's window, not the entire
Desktop. Test outputs remain under ignored build folders or `/tmp`; do not
publish screenshots or logs without separately reviewing their contents.

Before running any UI suite, arrange an uninterrupted interval on the Mac.
Tests activate the app once, then check both XCTest foreground state and
AppKit's frontmost bundle identifier before every pointer or keyboard action.
If another app becomes frontmost, input stops with `foregroundLost`; cleanup
also avoids keyboard input in that state. Do not automatically retry against
an actively used desktop. Process-targeted termination remains permitted.

`InHouseAgentNotificationUI` explicitly launches the installed application and
requests notification authorization in Settings. A successful button interaction
is not evidence of delivery; verify a production routine notification afterward.

`InHouseAgentUpdateUI` requires the signed installed version 0.1.0 and a published
Sparkle feed advertising signed version 0.1.1. It starts the real sidecar, uses
Check for Updates and Sparkle's install controls, verifies the installed version
and relaunch path, and checks that the old sidecar exited. Do not run it against
an unpublished feed or during another model task.
