import Foundation
import Combine
import CryptoKit
import AppKit

@MainActor
class UsageService: ObservableObject {
    @Published var usage: UsageResponse?
    @Published var lastError: String?
    @Published var lastUpdated: Date?
    @Published var isAuthenticated = false
    @Published var isAwaitingCode = false
    @Published private(set) var accountEmail: String?

    var historyService: UsageHistoryService?
    var notificationService: NotificationService?

    private var timer: Timer?
    private let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let userinfoEndpoint = URL(string: "https://api.anthropic.com/api/oauth/userinfo")!
    private var currentInterval: TimeInterval

    static let defaultPollingMinutes = 30
    static let pollingOptions = [5, 15, 30, 60]
    nonisolated static let maxBackoffInterval: TimeInterval = 60 * 60

    @Published private(set) var pollingMinutes: Int

    private var refreshTask: Task<StoredCredentials?, Never>?

    func updatePollingInterval(_ minutes: Int) {
        pollingMinutes = minutes
        UserDefaults.standard.set(minutes, forKey: "pollingMinutes")
        currentInterval = TimeInterval(minutes * 60)
        if isAuthenticated {
            scheduleTimer()
            Task { await fetchUsage() }
        }
    }

    private var baseInterval: TimeInterval { TimeInterval(pollingMinutes * 60) }

    nonisolated static func backoffInterval(
        retryAfter: TimeInterval?,
        currentInterval: TimeInterval
    ) -> TimeInterval {
        min(max(retryAfter ?? currentInterval, currentInterval * 2), maxBackoffInterval)
    }

    // OAuth constants
    private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let redirectUri = "https://console.anthropic.com/oauth/code/callback"
    private let tokenEndpoint = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    // PKCE state (lives only during an auth flow)
    private var codeVerifier: String?
    private var oauthState: String?

    var pct5h: Double { (usage?.fiveHour?.utilization ?? 0) / 100.0 }
    var pct7d: Double { (usage?.sevenDay?.utilization ?? 0) / 100.0 }
    var pctExtra: Double { (usage?.extraUsage?.utilization ?? 0) / 100.0 }
    var reset5h: Date? { usage?.fiveHour?.resetsAtDate }
    var reset7d: Date? { usage?.sevenDay?.resetsAtDate }

    init() {
        let stored = UserDefaults.standard.integer(forKey: "pollingMinutes")
        let minutes = Self.pollingOptions.contains(stored) ? stored : Self.defaultPollingMinutes
        self.pollingMinutes = minutes
        self.currentInterval = TimeInterval(minutes * 60)
        isAuthenticated = StoredCredentials.load() != nil
    }

    // MARK: - Polling

    func startPolling() {
        guard isAuthenticated else { return }
        Task {
            await fetchUsage()
            if accountEmail == nil { await fetchProfile() }
        }
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: currentInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isAuthenticated else { return }
                Task { await self.fetchUsage() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Token Refresh

    private func validAccessToken() async -> String? {
        guard let credentials = StoredCredentials.load() else { return nil }

        guard credentials.needsRefresh else {
            return credentials.accessToken
        }

        guard credentials.hasRefreshToken else {
            // Legacy migration: no refresh token, return existing token directly
            return credentials.accessToken
        }

        if let refreshed = await coalescedRefresh(credentials: credentials) {
            return refreshed.accessToken
        }

        // Refresh failed — return existing token anyway; it may still work
        return credentials.accessToken
    }

    private func coalescedRefresh(credentials: StoredCredentials) async -> StoredCredentials? {
        if let existing = refreshTask {
            return await existing.value
        }

        let task = Task { await performRefresh(credentials: credentials) }
        refreshTask = task
        defer { refreshTask = nil }
        return await task.value
    }

    private func performRefresh(credentials: StoredCredentials) async -> StoredCredentials? {
        guard credentials.hasRefreshToken else { return nil }

        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "client_id": clientId,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let responseTime = Date()

            guard let http = response as? HTTPURLResponse else {
                lastError = "Invalid refresh response"
                print("[UsageService] Token refresh returned non-HTTP response")
                return nil
            }

            if http.statusCode == 400 || http.statusCode == 401 {
                // Permanent rejection — delete credentials to prevent retry loops
                StoredCredentials.delete()
                lastError = "Refresh token rejected (HTTP \(http.statusCode)) — please sign in again"
                return nil
            }

            guard http.statusCode == 200 else {
                lastError = "Token refresh failed: HTTP \(http.statusCode)"
                print("[UsageService] Token refresh failed: HTTP \(http.statusCode)")
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else {
                lastError = "Could not parse refresh response"
                print("[UsageService] Could not parse token refresh response")
                return nil
            }

            let refreshToken = json["refresh_token"] as? String ?? credentials.refreshToken
            let expiresIn = json["expires_in"] as? Double ?? 3600
            let expiresAt = responseTime.addingTimeInterval(expiresIn)

            let newCredentials = StoredCredentials(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: expiresAt
            )

            do {
                try newCredentials.save()
            } catch {
                print("[UsageService] Failed to save refreshed credentials: \(error)")
            }

            lastError = nil
            return newCredentials
        } catch {
            lastError = "Token refresh error: \(error.localizedDescription)"
            print("[UsageService] Token refresh error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - OAuth PKCE Flow

    func startOAuthFlow() {
        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        let state = generateCodeVerifier() // random state

        codeVerifier = verifier
        oauthState = state

        var components = URLComponents(string: "https://claude.ai/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "scope", value: "user:profile user:inference"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]

        if let url = components.url {
            NSWorkspace.shared.open(url)
            isAwaitingCode = true
        }
    }

    func submitOAuthCode(_ rawCode: String) async {
        // Response format: "code#state" — parse it
        let parts = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#", maxSplits: 1)
        let code = String(parts[0])

        if parts.count > 1 {
            let returnedState = String(parts[1])
            guard returnedState == oauthState else {
                lastError = "OAuth state mismatch — try again"
                isAwaitingCode = false
                codeVerifier = nil
                oauthState = nil
                return
            }
        }

        guard let verifier = codeVerifier else {
            lastError = "No pending OAuth flow"
            isAwaitingCode = false
            return
        }

        // Exchange code for token
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "state": oauthState ?? "",
            "client_id": clientId,
            "redirect_uri": redirectUri,
            "code_verifier": verifier,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let responseTime = Date()

            guard let http = response as? HTTPURLResponse else {
                lastError = "Invalid token response"
                return
            }
            guard http.statusCode == 200 else {
                let bodyStr = String(data: data, encoding: .utf8) ?? ""
                lastError = "Token exchange failed: HTTP \(http.statusCode) \(bodyStr)"
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else {
                lastError = "Could not parse token response"
                return
            }

            let refreshToken = json["refresh_token"] as? String ?? ""
            let expiresIn = json["expires_in"] as? Double ?? 3600
            let expiresAt = responseTime.addingTimeInterval(expiresIn)

            let credentials = StoredCredentials(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: expiresAt
            )

            do {
                try credentials.save()
            } catch {
                lastError = "Failed to save credentials: \(error.localizedDescription)"
                return
            }

            isAuthenticated = true
            isAwaitingCode = false
            lastError = nil
            codeVerifier = nil
            oauthState = nil

            await fetchProfile()
            startPolling()
        } catch {
            lastError = "Token exchange error: \(error.localizedDescription)"
        }
    }

    func signOut() {
        StoredCredentials.delete()
        isAuthenticated = false
        usage = nil
        lastError = nil
        lastUpdated = nil
        accountEmail = nil
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncoded()
    }

    // MARK: - API Fetch

    func fetchUsage() async {
        guard let token = await validAccessToken() else {
            lastError = "Not signed in"
            isAuthenticated = false
            return
        }

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
                // Attempt token refresh before signing out
                if let credentials = StoredCredentials.load(),
                   credentials.hasRefreshToken,
                   let refreshed = await coalescedRefresh(credentials: credentials) {
                    // Retry with refreshed token
                    var retryRequest = URLRequest(url: usageEndpoint)
                    retryRequest.setValue("Bearer \(refreshed.accessToken)", forHTTPHeaderField: "Authorization")
                    retryRequest.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

                    do {
                        let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
                        guard let retryHttp = retryResponse as? HTTPURLResponse,
                              retryHttp.statusCode == 200 else {
                            signOut()
                            return
                        }
                        let decoded = try JSONDecoder().decode(UsageResponse.self, from: retryData)
                        handleSuccessfulUsageResponse(decoded)
                    } catch {
                        signOut()
                    }
                } else {
                    lastError = "Session expired — please sign in again"
                    signOut()
                }
                return
            }
            if http.statusCode == 429 {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(Double.init) ?? currentInterval
                currentInterval = Self.backoffInterval(
                    retryAfter: retryAfter,
                    currentInterval: currentInterval
                )
                lastError = "Rate limited — backing off to \(Int(currentInterval))s"
                scheduleTimer()
                return
            }
            guard http.statusCode == 200 else {
                lastError = "HTTP \(http.statusCode)"
                return
            }
            let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
            handleSuccessfulUsageResponse(decoded)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func handleSuccessfulUsageResponse(_ decoded: UsageResponse) {
        let reconciled = decoded.reconciled(with: usage)
        usage = reconciled
        lastError = nil
        lastUpdated = Date()
        historyService?.recordDataPoint(pct5h: pct5h, pct7d: pct7d)
        notificationService?.checkAndNotify(pct5h: pct5h, pct7d: pct7d, pctExtra: pctExtra)
        if currentInterval != baseInterval {
            currentInterval = baseInterval
            scheduleTimer()
        }
    }

    // MARK: - Profile

    func fetchProfile() async {
        if let local = Self.loadLocalProfile() {
            accountEmail = local
            return
        }

        guard let token = await validAccessToken() else { return }

        var request = URLRequest(url: userinfoEndpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return
        }

        if http.statusCode == 401 {
            // Attempt token refresh — do NOT sign out on failure (fetchProfile is not the session authority)
            if let credentials = StoredCredentials.load(),
               credentials.hasRefreshToken,
               let refreshed = await coalescedRefresh(credentials: credentials) {
                var retryRequest = URLRequest(url: userinfoEndpoint)
                retryRequest.setValue("Bearer \(refreshed.accessToken)", forHTTPHeaderField: "Authorization")
                retryRequest.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

                guard let (retryData, retryResponse) = try? await URLSession.shared.data(for: retryRequest),
                      let retryHttp = retryResponse as? HTTPURLResponse,
                      retryHttp.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: retryData) as? [String: Any] else {
                    return
                }
                parseProfileResponse(json)
            }
            return
        }

        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        parseProfileResponse(json)
    }

    private func parseProfileResponse(_ json: [String: Any]) {
        if let email = json["email"] as? String, !email.isEmpty {
            accountEmail = email
        } else if let name = json["name"] as? String, !name.isEmpty {
            accountEmail = name
        }
    }

    /// Try reading the email from Claude Code's local config as a fallback.
    private static func loadLocalProfile() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any] else {
            return nil
        }
        if let email = account["emailAddress"] as? String, !email.isEmpty {
            return email
        }
        if let name = account["displayName"] as? String, !name.isEmpty {
            return name
        }
        return nil
    }
}

// MARK: - Base64URL

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
