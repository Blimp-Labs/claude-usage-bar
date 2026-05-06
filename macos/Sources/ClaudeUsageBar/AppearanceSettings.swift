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
}
