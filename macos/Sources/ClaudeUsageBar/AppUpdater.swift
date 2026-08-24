import Foundation
import Sparkle

/// Forwards Sparkle's delegate callbacks. A separate object because
/// `SPUStandardUpdaterController` wants its delegate at construction, before
/// `self` exists.
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var onUpdateCycleFinished: ((Error?) -> Void)?

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        onUpdateCycleFinished?(error)
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var isConfigured: Bool
    @Published private(set) var lastError: String?

    /// Sparkle enrols every user in a daily background check via
    /// `SUEnableAutomaticChecks` without ever asking. This is the only place a
    /// user can see that it happens, or turn it off.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            guard isConfigured else { return }
            guard updaterController.updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            updaterController.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    private let updaterController: SPUStandardUpdaterController
    private let delegate: UpdaterDelegate
    private var canCheckObservation: NSKeyValueObservation?

    init(bundle: Bundle = .main) {
        let feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        self.isConfigured = !(feedURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && !(publicKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        let delegate = UpdaterDelegate()
        self.delegate = delegate
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        self.automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates

        canCheckObservation = updaterController.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = canCheck
            }
        }

        // Without this, a failed background check is completely silent: Sparkle
        // suppresses scheduled-check errors from the UI, so nothing would ever
        // populate `lastError` and a user could sit on a broken feed forever.
        delegate.onUpdateCycleFinished = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.recordUpdateCycleResult(error)
            }
        }

        guard isConfigured else { return }

        updaterController.startUpdater()
        automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates
    }

    func checkForUpdates() {
        guard isConfigured else {
            lastError = "Updater is not configured for this build"
            return
        }

        updaterController.checkForUpdates(nil)
    }

    /// Maps the outcome of an update cycle onto `lastError`. Exposed for tests.
    func recordUpdateCycleResult(_ error: Error?) {
        lastError = Self.describe(error)
    }

    /// "No update found" is a successful outcome, not a failure — surfacing it
    /// would put a red banner in the popover every time the app is up to date.
    nonisolated static func describe(_ error: Error?) -> String? {
        guard let error else { return nil }

        // NS_ENUM(OSStatus, SUError) imports as SUError.noUpdateError; rawValue
        // is Int32, and the domain check keeps 1001 from another domain out.
        let nsError = error as NSError
        let isNoUpdate = nsError.domain == SUSparkleErrorDomain
            && nsError.code == Int(SUError.noUpdateError.rawValue)
        guard !isNoUpdate else { return nil }

        let description = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? "Update check failed" : description
    }
}
