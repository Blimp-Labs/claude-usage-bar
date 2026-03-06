import Foundation
import Combine
import Security

@MainActor
class UsageService: ObservableObject {
    @Published var usage: UsageResponse?
    @Published var lastError: String?
    @Published var lastUpdated: Date?
    @Published var isAuthenticated = false

    var historyService: UsageHistoryService?

    private var timer: AnyCancellable?
    private let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let tokenEndpoint = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    private var currentInterval: TimeInterval

    static let defaultPollingMinutes = 30
    static let pollingOptions = [5, 15, 30, 60]

    @Published var pollingMinutes: Int {
        didSet {
            UserDefaults.standard.set(pollingMinutes, forKey: "pollingMinutes")
            currentInterval = TimeInterval(pollingMinutes * 60)
            if isAuthenticated { scheduleTimer() }
        }
    }

    private var baseInterval: TimeInterval { TimeInterval(pollingMinutes * 60) }

    var pct5h: Double { (usage?.fiveHour?.utilization ?? 0) / 100.0 }
    var pct7d: Double { (usage?.sevenDay?.utilization ?? 0) / 100.0 }
    var reset5h: Date? { usage?.fiveHour?.resetsAtDate }
    var reset7d: Date? { usage?.sevenDay?.resetsAtDate }

    init() {
        let stored = UserDefaults.standard.integer(forKey: "pollingMinutes")
        let minutes = Self.pollingOptions.contains(stored) ? stored : Self.defaultPollingMinutes
        self.pollingMinutes = minutes
        self.currentInterval = TimeInterval(minutes * 60)
        isAuthenticated = loadClaudeCodeToken() != nil
    }

    // MARK: - Polling

    func startPolling() {
        guard isAuthenticated else { return }
        Task { await fetchUsage() }
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.cancel()
        timer = Timer.publish(every: currentInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.isAuthenticated else { return }
                Task { await self.fetchUsage() }
            }
    }

    // MARK: - Keychain (Claude Code credentials)

    private struct ClaudeCodeCredentials {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: TimeInterval
    }

    private func loadClaudeCodeToken() -> ClaudeCodeCredentials? {
        guard let json = readKeychainJSON() else { return nil }
        guard let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String else { return nil }
        let refreshToken = oauth["refreshToken"] as? String
        let expiresAt = oauth["expiresAt"] as? TimeInterval ?? 0
        return ClaudeCodeCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt
        )
    }

    private func readKeychainJSON() -> [String: Any]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func updateKeychainToken(accessToken: String, refreshToken: String?, expiresAt: TimeInterval) {
        guard var json = readKeychainJSON(),
              var oauth = json["claudeAiOauth"] as? [String: Any] else { return }
        oauth["accessToken"] = accessToken
        if let refreshToken { oauth["refreshToken"] = refreshToken }
        oauth["expiresAt"] = expiresAt
        json["claudeAiOauth"] = oauth

        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        SecItemUpdate(query as CFDictionary, update as CFDictionary)
    }

    // MARK: - Token Refresh

    private func refreshAccessToken(credentials: ClaudeCodeCredentials) async -> String? {
        guard let refreshToken = credentials.refreshToken else { return nil }

        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccessToken = json["access_token"] as? String else { return nil }
            let newRefreshToken = json["refresh_token"] as? String
            let expiresIn = json["expires_in"] as? TimeInterval ?? 3600
            let newExpiresAt = Date().timeIntervalSince1970 * 1000 + expiresIn * 1000

            updateKeychainToken(
                accessToken: newAccessToken,
                refreshToken: newRefreshToken ?? refreshToken,
                expiresAt: newExpiresAt
            )
            return newAccessToken
        } catch {
            return nil
        }
    }

    private func getValidToken() async -> String? {
        guard let credentials = loadClaudeCodeToken() else { return nil }

        let nowMs = Date().timeIntervalSince1970 * 1000
        if credentials.expiresAt > nowMs + 60_000 {
            return credentials.accessToken
        }

        if let newToken = await refreshAccessToken(credentials: credentials) {
            return newToken
        }

        return credentials.accessToken
    }

    // MARK: - API Fetch

    func fetchUsage() async {
        guard let token = await getValidToken() else {
            lastError = "Claude Code not signed in"
            isAuthenticated = false
            return
        }

        isAuthenticated = true

        var request = URLRequest(url: usageEndpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                lastError = "Invalid response"
                return
            }
            if http.statusCode == 401 {
                if let credentials = loadClaudeCodeToken(),
                   let freshToken = await refreshAccessToken(credentials: credentials) {
                    var retry = URLRequest(url: usageEndpoint)
                    retry.setValue("Bearer \(freshToken)", forHTTPHeaderField: "Authorization")
                    retry.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
                    let (retryData, retryResp) = try await URLSession.shared.data(for: retry)
                    guard let retryHttp = retryResp as? HTTPURLResponse, retryHttp.statusCode == 200 else {
                        lastError = "Session expired — re-login in Claude Code"
                        isAuthenticated = false
                        return
                    }
                    let decoded = try JSONDecoder().decode(UsageResponse.self, from: retryData)
                    usage = decoded
                    lastError = nil
                    lastUpdated = Date()
                    historyService?.recordDataPoint(pct5h: pct5h, pct7d: pct7d)
                    return
                }
                lastError = "Session expired — re-login in Claude Code"
                isAuthenticated = false
                return
            }
            if http.statusCode == 429 {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(Double.init) ?? currentInterval
                currentInterval = min(max(retryAfter, currentInterval * 2), 600)
                lastError = "Rate limited — backing off to \(Int(currentInterval))s"
                scheduleTimer()
                return
            }
            guard http.statusCode == 200 else {
                lastError = "HTTP \(http.statusCode)"
                return
            }
            let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
            usage = decoded
            lastError = nil
            lastUpdated = Date()
            historyService?.recordDataPoint(pct5h: pct5h, pct7d: pct7d)
            if currentInterval != baseInterval {
                currentInterval = baseInterval
                scheduleTimer()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }
}
