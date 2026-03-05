import Foundation

enum AppConfig {
    static let directoryURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claude-usage-bar", isDirectory: true)
    }()
    static let tokenURL = directoryURL.appendingPathComponent("token")
    static let historyURL = directoryURL.appendingPathComponent("history.json")

    static func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true)
    }
}
