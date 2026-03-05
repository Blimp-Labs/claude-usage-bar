import Foundation
import Combine
import CryptoKit
import AppKit
import OSLog

@MainActor
class UsageService: ObservableObject {
    @Published var usage: UsageResponse?
    @Published var lastError: String?
    @Published var lastUpdated: Date?
    @Published var isAuthenticated = false
    @Published var isAwaitingCode = false
    @Published var isLoading = false

    private let historyService: UsageHistoryService

    private var timer: AnyCancellable?
    private let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let baseInterval: TimeInterval = 60
    private var currentInterval: TimeInterval = 60

    // OAuth constants
    // OAuth client ID registered at console.anthropic.com for ClaudeUsageBar
    private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let redirectUri = "https://console.anthropic.com/oauth/code/callback"
    private let tokenEndpoint = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    // PKCE state (lives only during an auth flow)
    private var codeVerifier: String?
    private var oauthState: String?

    // File-based token storage (avoids Keychain prompts for unsigned binaries)

    var pct5h: Double { (usage?.fiveHour?.utilization ?? 0) / 100.0 }
    var pct7d: Double { (usage?.sevenDay?.utilization ?? 0) / 100.0 }
    var reset5h: Date? { usage?.fiveHour?.resetsAtDate }
    var reset7d: Date? { usage?.sevenDay?.resetsAtDate }

    init(historyService: UsageHistoryService) {
        self.historyService = historyService
        isAuthenticated = loadToken() != nil
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

    // MARK: - OAuth PKCE Flow

    func startOAuthFlow() {
        Logger.oauth.info("Starting OAuth PKCE flow")
        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        let state = generateRandomBase64URLString() // random state

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

            saveToken(accessToken)
            isAuthenticated = true
            isAwaitingCode = false
            lastError = nil
            codeVerifier = nil
            oauthState = nil
            Logger.oauth.info("OAuth token exchange successful")

            startPolling()
        } catch {
            lastError = "Token exchange error: \(error.localizedDescription)"
            Logger.oauth.error("Token exchange failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func cancelOAuthFlow() {
        isAwaitingCode = false
        codeVerifier = nil
        oauthState = nil
    }

    func signOut() {
        deleteToken()
        isAuthenticated = false
        usage = nil
        lastError = nil
        lastUpdated = nil
    }

    // MARK: - PKCE Helpers

    private func generateRandomBase64URLString(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private func generateCodeVerifier() -> String {
        generateRandomBase64URLString(byteCount: 32)
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncoded()
    }

    // MARK: - API Fetch

    func fetchUsage() async {
        isLoading = true
        defer { isLoading = false }
        Logger.usage.info("Polling usage endpoint")
        guard let token = loadToken() else {
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
                lastError = "Session expired — please sign in again"
                isAuthenticated = false
                isAwaitingCode = false
                deleteToken()
                // Do NOT clear usage or lastUpdated — user can still see last known data
                return
            }
            if http.statusCode == 429 {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(Double.init) ?? currentInterval
                currentInterval = min(max(retryAfter, currentInterval * 2), 600)
                lastError = "Rate limited — backing off to \(Int(currentInterval))s"
                Logger.usage.warning("Rate limited, backing off to \(self.currentInterval, privacy: .public)s")
                scheduleTimer()
                return
            }
            // Reset backoff for any non-429 response (including errors like 500)
            if currentInterval != baseInterval {
                currentInterval = baseInterval
                scheduleTimer()
            }
            guard http.statusCode == 200 else {
                lastError = "HTTP \(http.statusCode)"
                return
            }
            let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
            usage = decoded
            lastError = nil
            lastUpdated = Date()
            historyService.recordDataPoint(pct5h: pct5h, pct7d: pct7d)
            Logger.usage.info("Usage fetched: 5h=\(self.pct5h, privacy: .public) 7d=\(self.pct7d, privacy: .public)")
        } catch {
            lastError = error.localizedDescription
            Logger.usage.error("Fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - File-based token storage

    private func saveToken(_ token: String) {
        let url = AppConfig.tokenURL
        try? Data(token.utf8).write(to: url, options: .atomic)
        // Restrict permissions to owner-only (0600)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func loadToken() -> String? {
        guard let data = try? Data(contentsOf: AppConfig.tokenURL) else { return nil }
        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }

    private func deleteToken() {
        try? FileManager.default.removeItem(at: AppConfig.tokenURL)
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
