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

            // Only a completed cycle clears `lastError`, and switching this off
            // stops cycles entirely — so a stale banner would freeze for the
            // life of the process, describing machinery the user just disabled.
            if !automaticallyChecksForUpdates {
                lastError = nil
            }

            guard updaterController.updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            updaterController.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    /// When Sparkle last completed a check, so the section can say whether the
    /// automatic checks it advertises are actually happening.
    @Published private(set) var lastCheckDate: Date?

    private let updaterController: SPUStandardUpdaterController
    private let delegate: UpdaterDelegate
    private var canCheckObservation: NSKeyValueObservation?
    private var automaticChecksObservation: NSKeyValueObservation?

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

        // `automaticallyChecksForUpdates` is KVO-compliant and can change from
        // outside this class (user defaults, a zeroed check interval), so mirror
        // it back rather than letting the toggle drift from the truth.
        automaticChecksObservation = updaterController.updater.observe(
            \.automaticallyChecksForUpdates,
            options: [.new]
        ) { [weak self] updater, _ in
            let enabled = updater.automaticallyChecksForUpdates
            Task { @MainActor [weak self] in
                self?.automaticallyChecksForUpdates = enabled
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

        // Not re-read afterwards: startUpdater() does not touch this property,
        // and assigning again would only re-enter didSet.
        updaterController.startUpdater()
    }

    func checkForUpdates() {
        // Callers gate on `isConfigured`; with no feed there is nothing to check.
        guard isConfigured else { return }

        updaterController.checkForUpdates(nil)
    }

    /// Maps the outcome of an update cycle onto `lastError`. Not directly
    /// covered: constructing an `AppUpdater` spins up a live
    /// `SPUStandardUpdaterController`. The mapping itself is `describe`, which
    /// is pure and tested.
    func recordUpdateCycleResult(_ error: Error?) {
        lastError = Self.describe(error)
        lastCheckDate = updaterController.updater.lastUpdateCheckDate
    }

    /// The outcomes Sparkle itself declines to log or surface. "No update
    /// found" is the obvious one; the other two are routine too — the user
    /// dismissed the admin prompt, or the automatic path needed admin rights it
    /// could not ask for right now and deferred. None is a failure to report.
    nonisolated private static let benignCodes: Set<Int> = [
        Int(SUError.noUpdateError.rawValue),                    // 1001
        Int(SUError.installationCanceledError.rawValue),        // 4007
        Int(SUError.installationAuthorizeLaterError.rawValue)   // 4008
    ]

    nonisolated static func describe(_ error: Error?) -> String? {
        guard let error else { return nil }

        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain, benignCodes.contains(nsError.code) {
            return nil
        }

        // Sparkle builds many of its errors with `userInfo: nil`, and Foundation
        // then synthesises "The operation couldn't be completed. (SUSparkleError
        // Domain error 4010.)" — debug text, never empty, and not something to
        // show a user. Only trust a description the error actually carries.
        guard let carried = nsError.userInfo[NSLocalizedDescriptionKey] as? String else {
            return "Update check failed"
        }

        let trimmed = carried.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Update check failed" : trimmed
    }
}
