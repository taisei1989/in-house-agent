import Combine
import Foundation
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()

    @Published private(set) var canCheck = false
    @Published private(set) var error: String?

    private var controller: SPUStandardUpdaterController?
    private var subscriptions = Set<AnyCancellable>()

    private override init() {
        super.init()
        guard !CommandLine.arguments.contains("--routine-notify") else { return }
        UserDefaults.standard.register(defaults: ["autoCheckUpdates": true])
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            error = String(localized: "Updates are not configured. Set the release feed and public signing key.")
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                Task { @MainActor [weak self] in self?.canCheck = value }
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.applyAutomaticCheckPreference() }
            }
            .store(in: &subscriptions)
        // Match Sparkle's own preference before starting its scheduling machinery.
        UserDefaults.standard.set(UserDefaults.standard.bool(forKey: "autoCheckUpdates"),
                                  forKey: "SUEnableAutomaticChecks")
        controller.startUpdater()
        applyAutomaticCheckPreference()
    }

    func check() {
        guard canCheck, let controller else { return }
        error = nil
        controller.checkForUpdates(nil)
    }

    private func applyAutomaticCheckPreference() {
        guard let updater = controller?.updater else { return }
        let enabled = UserDefaults.standard.bool(forKey: "autoCheckUpdates")
        if updater.automaticallyChecksForUpdates != enabled {
            updater.automaticallyChecksForUpdates = enabled
        }
    }

    func updater(_ updater: SPUUpdater,
                 shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        Task { @MainActor in
            await SetupModel.shared.stop()
            await ServerModel.shared.stop()
            guard ServerModel.shared.process?.isRunning != true, !SetupModel.shared.running else { return }
            installHandler()
        }
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        self.error = error.localizedDescription
    }
}
