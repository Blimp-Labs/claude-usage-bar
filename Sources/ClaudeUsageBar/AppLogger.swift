import OSLog

extension Logger {
    static let usage = Logger(subsystem: "com.claudeusagebar", category: "usage")
    static let history = Logger(subsystem: "com.claudeusagebar", category: "history")
    static let oauth = Logger(subsystem: "com.claudeusagebar", category: "oauth")
}
