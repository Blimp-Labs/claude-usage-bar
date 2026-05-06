import Foundation

/// User preference keys for the reset-time divider appearance settings.
///
/// The reset-time divider shows a vertical line on the menubar icon indicating when the usage bucket resets.
/// These keys control two independent toggles in Settings:
/// 1. Whether the divider is visible at all
/// 2. Whether the divider uses semantic colors (warning/critical states) or a neutral single color
///
/// **Design constraint:** Colored mode requires the divider to be visible; if `showResetDivider` is false,
/// the colored toggle is disabled in the UI (see SettingsView).
enum AppearanceDefaultsKey {
    /// Controls divider visibility. If false, the reset indicator is hidden from the menubar icon.
    /// Default: true
    static let showResetDivider = "showResetDivider"

    /// Controls divider color mode. If true, uses semantic colors (orange for warning, red for critical, etc.).
    /// If false, uses a neutral gray color (`.secondary`). Only meaningful when `showResetDivider` is true.
    /// Default: true
    static let coloredResetDivider = "coloredResetDivider"

    // MARK: - Service Status (Claude status indicator) — added in DV-1.6

    /// Master feature flag for the Claude service-status indicator. Default: false (off in v1).
    static let showServiceStatus = "showServiceStatus"

    /// When the rolled-up status is `operational`, tint the logo subtle green if true; otherwise leave
    /// the logo untinted. Default: false (only tint when there is something actionable).
    static let showOverlayWhenOperational = "showOverlayWhenOperational"

    /// Status-page polling interval in minutes. Valid values: 1, 5, 15, 30. Default: 5.
    static let statusPollMinutes = "statusPollMinutes"

    /// JSON-encoded `StatusComponentFilter`. Default: encoded `StatusComponentFilter.default`.
    static let statusComponentFilter = "statusComponentFilter"
}

/// Helpers for round-tripping `StatusComponentFilter` through `UserDefaults` `Data`.
/// Lives next to the keys so callers don't need to import the StatusPage stack.
public enum StatusComponentFilterStore {
    public static func encode(_ filter: StatusComponentFilter) throws -> Data {
        try JSONEncoder().encode(filter)
    }

    public static func decode(_ data: Data) throws -> StatusComponentFilter {
        try JSONDecoder().decode(StatusComponentFilter.self, from: data)
    }

    /// Read from `defaults`, falling back to `StatusComponentFilter.default` on missing/invalid data.
    public static func load(from defaults: UserDefaults) -> StatusComponentFilter {
        guard let data = defaults.data(forKey: AppearanceDefaultsKey.statusComponentFilter) else {
            return .default
        }
        return (try? decode(data)) ?? .default
    }

    public static func save(_ filter: StatusComponentFilter, to defaults: UserDefaults) {
        guard let data = try? encode(filter) else { return }
        defaults.set(data, forKey: AppearanceDefaultsKey.statusComponentFilter)
    }
}

/// Valid options for `statusPollMinutes`.
public enum StatusPollOptions {
    public static let minutes: [Int] = [1, 5, 15, 30]
    public static let `default`: Int = 5
}
