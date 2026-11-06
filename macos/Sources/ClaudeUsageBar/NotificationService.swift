import Foundation
@preconcurrency import UserNotifications

struct ThresholdAlert: Equatable {
    let window: String
    let pct: Int
}

/// Pure logic: returns which threshold alerts should fire given a state transition.
func crossedThresholds(
    threshold5h: Int,
    threshold7d: Int,
    thresholdExtra: Int,
    previous5h: Double,
    previous7d: Double,
    previousExtra: Double,
    current5h: Double,
    current7d: Double,
    currentExtra: Double
) -> [ThresholdAlert] {
    var alerts = [ThresholdAlert]()

    if threshold5h > 0 {
        let t = Double(threshold5h)
        if current5h >= t && previous5h < t {
            alerts.append(ThresholdAlert(window: "5-hour", pct: Int(round(current5h))))
        }
    }

    if threshold7d > 0 {
        let t = Double(threshold7d)
        if current7d >= t && previous7d < t {
            alerts.append(ThresholdAlert(window: "7-day", pct: Int(round(current7d))))
        }
    }

    if thresholdExtra > 0 {
        let t = Double(thresholdExtra)
        if currentExtra >= t && previousExtra < t {
            alerts.append(ThresholdAlert(window: "Extra usage", pct: Int(round(currentExtra))))
        }
    }

    return alerts
}

private class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

@MainActor
class NotificationService: ObservableObject {
    /// 0 = off, 5–100 = alert when window reaches this %.
    @Published private(set) var threshold5h: Int
    @Published private(set) var threshold7d: Int
    @Published private(set) var thresholdExtra: Int

    private struct Percentages {
        var pct5h: Double?
        var pct7d: Double?
        var pctExtra: Double?
    }
    /// Per account, so switching back to one doesn't repeat its alert.
    private var previous: [String: Percentages] = [:]
    private let delegate = NotificationDelegate()
    let isAvailable = supportsUserNotifications()

    init() {
        threshold5h = Self.load("notificationThreshold5h")
        threshold7d = Self.load("notificationThreshold7d")
        thresholdExtra = Self.load("notificationThresholdExtra")
        if isAvailable {
            UNUserNotificationCenter.current().delegate = delegate
        }
    }

    func setThreshold5h(_ value: Int) {
        threshold5h = clamp(value)
        UserDefaults.standard.set(threshold5h, forKey: "notificationThreshold5h")
        for account in previous.keys { previous[account]?.pct5h = nil }
        if threshold5h > 0 { requestPermission() }
    }

    func setThreshold7d(_ value: Int) {
        threshold7d = clamp(value)
        UserDefaults.standard.set(threshold7d, forKey: "notificationThreshold7d")
        for account in previous.keys { previous[account]?.pct7d = nil }
        if threshold7d > 0 { requestPermission() }
    }

    func setThresholdExtra(_ value: Int) {
        thresholdExtra = clamp(value)
        UserDefaults.standard.set(thresholdExtra, forKey: "notificationThresholdExtra")
        for account in previous.keys { previous[account]?.pctExtra = nil }
        if thresholdExtra > 0 { requestPermission() }
    }

    func requestPermission() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @discardableResult
    func checkAndNotify(
        pct5h: Double, pct7d: Double, pctExtra: Double, account: String
    ) -> [ThresholdAlert] {
        let current5h = pct5h * 100
        let current7d = pct7d * 100
        let currentExtra = pctExtra * 100

        let last = previous[account] ?? Percentages()
        previous[account] = Percentages(pct5h: current5h, pct7d: current7d, pctExtra: currentExtra)

        let alerts = crossedThresholds(
            threshold5h: threshold5h,
            threshold7d: threshold7d,
            thresholdExtra: thresholdExtra,
            previous5h: last.pct5h ?? 0,
            previous7d: last.pct7d ?? 0,
            previousExtra: last.pctExtra ?? 0,
            current5h: current5h,
            current7d: current7d,
            currentExtra: currentExtra
        )

        for alert in alerts {
            sendNotification(window: alert.window, pct: alert.pct)
        }
        return alerts
    }

    private func sendNotification(window: String, pct: Int) {
        guard isAvailable else {
            print("[Notification] \(window) usage has reached \(pct)% (no bundle – skipped)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Claude Usage"
        content.body = "\(window) usage has reached \(pct)%"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "usage-\(window)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[Notification] Failed to deliver: \(error)")
            } else {
                print("[Notification] Delivered: \(window) at \(pct)%")
            }
        }
    }

    private func clamp(_ value: Int) -> Int {
        max(0, min(100, value))
    }

    private static func load(_ key: String) -> Int {
        let value = UserDefaults.standard.integer(forKey: key)
        return max(0, min(100, value))
    }
}

/// Dev-only: packaged builds always declare APPL.
let notificationsUnavailableMessage =
    "Notifications require a packaged application build — run `make app` and launch the bundle."

/// `UNUserNotificationCenter.current()` aborts outside a real app (e.g. `swift test`/`swift run`) and
/// there is no availability API, so require a declared `APPL` type (renamed bundles OK, `.appex` excluded).
func supportsUserNotifications(bundle: Bundle = .main) -> Bool {
    bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL"
}
