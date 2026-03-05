import Foundation
import Combine
import CryptoKit
import AppKit
import Security

@MainActor
class UsageService: ObservableObject {
    @Published var usage: UsageResponse?
    @Published var lastError: String?
    @Published var lastUpdated: Date?
    @Published var isAuthenticated = false
    @Published var isAwaitingCode = false

    var historyService: UsageHistoryService?

    private var timer: AnyCancellable?
    private let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let baseInterval: TimeInterval = 60
    private var currentInterval: TimeInterval = 60
    private static let oauthScope = "user:profile user:inference"
    private static let keychainService = "com.local.ClaudeUsageBar"
    private static let keychainAccount = "anthropic-oauth-token"

    // OAuth constants
    private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let redirectUri = "https://console.anthropic.com/oauth/code/callback"
    private let tokenEndpoint = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    // PKCE state (lives only during an auth flow)
    private var codeVerifier: String?
    private var oauthState: String?

    // Legacy file token path kept only for migration from older installs.
    private static var legacyTokenFileURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claude-usage-bar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("token")
    }

    var pct5h: Double { (usage?.fiveHour?.utilization ?? 0) / 100.0 }
    var pct7d: Double { (usage?.sevenDay?.utilization ?? 0) / 100.0 }
    var reset5h: Date? { usage?.fiveHour?.resetsAtDate }
    var reset7d: Date? { usage?.sevenDay?.resetsAtDate }

    init() {
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
            URLQueryItem(name: "scope", value: Self.oauthScope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]

        if let url = components.url {
            lastError = nil
            if NSWorkspace.shared.open(url) {
                isAwaitingCode = true
            } else {
                clearPendingOAuthFlow(clearError: false)
                lastError = "Could not open the browser for Claude sign-in"
            }
        }
    }

    func cancelOAuthFlow() {
        clearPendingOAuthFlow(clearError: false)
    }

    func submitOAuthCode(_ rawCode: String) async {
        // Response format: "code#state" — parse it
        let parts = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#", maxSplits: 1)
        let code = String(parts[0])

        if parts.count > 1 {
            let returnedState = String(parts[1])
            guard returnedState == oauthState else {
                lastError = "OAuth state mismatch — try again"
                clearPendingOAuthFlow(clearError: false)
                return
            }
        }

        guard let verifier = codeVerifier else {
            lastError = "No pending OAuth flow"
            clearPendingOAuthFlow(clearError: false)
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

            guard saveToken(accessToken) else {
                lastError = "Could not store session securely in macOS Keychain"
                clearPendingOAuthFlow(clearError: false)
                return
            }
            isAuthenticated = true
            clearPendingOAuthFlow(clearError: true)

            startPolling()
        } catch {
            lastError = "Token exchange error: \(error.localizedDescription)"
        }
    }

    func signOut() {
        deleteToken()
        isAuthenticated = false
        usage = nil
        lastError = nil
        lastUpdated = nil
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
                signOut()
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

    private func clearPendingOAuthFlow(clearError: Bool) {
        isAwaitingCode = false
        codeVerifier = nil
        oauthState = nil
        if clearError {
            lastError = nil
        }
    }

    // MARK: - Keychain token storage

    private func saveToken(_ token: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }

        let query = baseKeychainQuery()
        let attributes = [kSecValueData: data] as CFDictionary
        let updateStatus = SecItemUpdate(query, attributes)

        switch updateStatus {
        case errSecSuccess:
            deleteLegacyToken()
            return true
        case errSecItemNotFound:
            var item = baseKeychainAttributes()
            item[kSecValueData] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if addStatus == errSecSuccess {
                deleteLegacyToken()
                return true
            }
            return false
        default:
            return false
        }
    }

    private func loadToken() -> String? {
        if let token = loadTokenFromKeychain() {
            return token
        }

        guard let legacyToken = loadLegacyToken() else { return nil }
        if saveToken(legacyToken) {
            return legacyToken
        }
        return legacyToken
    }

    private func deleteToken() {
        SecItemDelete(baseKeychainQuery())
        deleteLegacyToken()
    }

    private func loadTokenFromKeychain() -> String? {
        var query = baseKeychainAttributes()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data else {
            return nil
        }

        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }

    private func loadLegacyToken() -> String? {
        guard let data = try? Data(contentsOf: Self.legacyTokenFileURL) else { return nil }
        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }

    private func deleteLegacyToken() {
        try? FileManager.default.removeItem(at: Self.legacyTokenFileURL)
    }

    private func baseKeychainQuery() -> CFDictionary {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.keychainAccount,
        ] as CFDictionary
    }

    private func baseKeychainAttributes() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.keychainAccount,
        ]
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
