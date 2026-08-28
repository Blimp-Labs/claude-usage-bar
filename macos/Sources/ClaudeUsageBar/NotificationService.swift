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

    private var previousPct5h: Double?
    private var previousPct7d: Double?
    private var previousPctExtra: Double?
    private let delegate = NotificationDelegate()

    /// False when this process cannot use notifications at all, so callers can
    /// say so instead of silently doing nothing.
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
        previousPct5h = nil
        if threshold5h > 0 { requestPermission() }
    }

    func setThreshold7d(_ value: Int) {
        threshold7d = clamp(value)
        UserDefaults.standard.set(threshold7d, forKey: "notificationThreshold7d")
        previousPct7d = nil
        if threshold7d > 0 { requestPermission() }
    }

    func setThresholdExtra(_ value: Int) {
        thresholdExtra = clamp(value)
        UserDefaults.standard.set(thresholdExtra, forKey: "notificationThresholdExtra")
        previousPctExtra = nil
        if thresholdExtra > 0 { requestPermission() }
    }

    func requestPermission() {
        guard isAvailable else {
            print("[Notification] Permission not requested — no app bundle")
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func checkAndNotify(pct5h: Double, pct7d: Double, pctExtra: Double) {
        let current5h = pct5h * 100
        let current7d = pct7d * 100
        let currentExtra = pctExtra * 100

        let prev5h = previousPct5h ?? 0
        let prev7d = previousPct7d ?? 0
        let prevExtra = previousPctExtra ?? 0

        defer {
            previousPct5h = current5h
            previousPct7d = current7d
            previousPctExtra = currentExtra
        }

        let alerts = crossedThresholds(
            threshold5h: threshold5h,
            threshold7d: threshold7d,
            thresholdExtra: thresholdExtra,
            previous5h: prev5h,
            previous7d: prev7d,
            previousExtra: prevExtra,
            current5h: current5h,
            current7d: current7d,
            currentExtra: currentExtra
        )

        for alert in alerts {
            sendNotification(window: alert.window, pct: alert.pct)
        }
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

/// Shown wherever notification controls are offered but cannot work. Only
/// reachable in development — a packaged build always declares APPL.
let notificationsUnavailableMessage =
    "Notifications require a packaged application build — run `make app` and launch the bundle."

/// Whether this process can use `UNUserNotificationCenter` at all.
///
/// `UNUserNotificationCenter.current()` aborts the process rather than
/// returning nil when it is unhappy, and Apple exposes no availability check,
/// so this is a deliberately conservative heuristic rather than a documented
/// test. The precise precondition it enforces is not public — a nil
/// `LSBundleProxy` alone does not trigger the abort — so this errs toward the
/// configurations known to work.
///
/// `CFBundlePackageType` is the key that declares a bundle's type.
/// `object(forInfoDictionaryKey:)` reads it strictly — a `.app` that omits the
/// key returns nil rather than falling back to the path extension — so this
/// depends on nothing but the declaration itself. That gets renamed, symlinked
/// and oddly-cased bundles right, and excludes app extensions (which declare
/// `XPC!`) for free. Under `swift test` and `swift run` there is no such key,
/// which is exactly the case that used to abort.
func supportsUserNotifications(bundle: Bundle = .main) -> Bool {
    bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL"
}
