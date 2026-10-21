import Foundation
import Sparkle

/// Separate object: the controller needs its delegate before `self` exists.
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var onUpdateCycleFinished: ((SPUUpdateCheck, Error?) -> Void)?

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        onUpdateCycleFinished?(updateCheck, error)
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var isConfigured: Bool
    @Published private(set) var lastError: String?
    @Published private(set) var automaticallyChecksForUpdates: Bool

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

        // Can also change via user defaults; keep the toggle in sync.
        automaticChecksObservation = updaterController.updater.observe(
            \.automaticallyChecksForUpdates,
            options: [.new]
        ) { [weak self] updater, _ in
            let enabled = updater.automaticallyChecksForUpdates
            Task { @MainActor [weak self] in
                self?.automaticallyChecksForUpdates = enabled
            }
        }

        // Sparkle hides scheduled-check errors from the UI; surface them here.
        delegate.onUpdateCycleFinished = { [weak self] check, error in
            guard !AppUpdater.isOfflineBackgroundCheck(check, error: error) else { return }
            Task { @MainActor [weak self] in
                self?.lastError = AppUpdater.describe(error)
            }
        }

        guard isConfigured else { return }

        updaterController.startUpdater()
    }

    func checkForUpdates() {
        guard isConfigured else { return }

        updaterController.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard isConfigured else { return }

        // Disabling stops cycles, so nothing else would clear a stale error.
        if !enabled {
            lastError = nil
        }
        automaticallyChecksForUpdates = enabled
        updaterController.updater.automaticallyChecksForUpdates = enabled
    }

    /// Outcomes Sparkle itself treats as routine: no update, prompt dismissed, install deferred.
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

        // Sparkle often leaves userInfo nil, and Foundation's synthesised
        // description is debug text ("SUSparkleErrorDomain error 4010").
        guard let message = (nsError.userInfo[NSLocalizedDescriptionKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !message.isEmpty else {
            return "Update check failed"
        }

        // Disk-image/translocation errors put the fix in the recovery suggestion.
        let recovery = (nsError.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let recovery, !recovery.isEmpty else { return message }

        return "\(message) \(recovery)"
    }

    nonisolated private static let offlineCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
        NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
        NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed
    ]

    /// A scheduled check that couldn't reach the network (e.g. a laptop waking
    /// before Wi-Fi reconnects) says nothing about the feed.
    nonisolated static func isOfflineBackgroundCheck(_ check: SPUUpdateCheck, error: Error?) -> Bool {
        guard check == .updatesInBackground else { return false }

        // Sparkle nests the URL error inside one or more of its own download errors.
        var current = error as NSError?
        while let nsError = current {
            if nsError.domain == NSURLErrorDomain { return offlineCodes.contains(nsError.code) }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
