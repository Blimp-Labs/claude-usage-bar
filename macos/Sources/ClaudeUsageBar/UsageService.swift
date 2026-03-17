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
    private let session: URLSession
    private let usageEndpoint: URL
    private let userinfoEndpoint: URL
    private let tokenEndpoint: URL
    private let credentialsStore: StoredCredentialsStore
    private let localProfileLoader: @MainActor () -> String?
    private var currentInterval: TimeInterval
    private enum RefreshResult {
        case success
        case permanentFailure
        case transientFailure
    }

    private var refreshTask: Task<RefreshResult, Never>?

    static let defaultPollingMinutes = 30
    static let pollingOptions = [5, 15, 30, 60]
    nonisolated static let maxBackoffInterval: TimeInterval = 60 * 60
    nonisolated static let defaultOAuthScopes = ["user:profile", "user:inference"]
    nonisolated private static let authorizeEndpoint = URL(string: "https://claude.ai/oauth/authorize")!
    nonisolated private static let defaultUsageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    nonisolated private static let defaultUserinfoEndpoint = URL(string: "https://api.anthropic.com/api/oauth/userinfo")!
    nonisolated private static let defaultTokenEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    nonisolated private static let defaultRedirectURI = "https://platform.claude.com/oauth/code/callback"

    @Published private(set) var pollingMinutes: Int

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
    private let redirectUri: String

    // PKCE state (lives only during an auth flow)
    private var codeVerifier: String?
    private var oauthState: String?

    var pct5h: Double { (usage?.fiveHour?.utilization ?? 0) / 100.0 }
    var pct7d: Double { (usage?.sevenDay?.utilization ?? 0) / 100.0 }
    var pctExtra: Double { (usage?.extraUsage?.utilization ?? 0) / 100.0 }
    var reset5h: Date? { usage?.fiveHour?.resetsAtDate }
    var reset7d: Date? { usage?.sevenDay?.resetsAtDate }

    init(
        session: URLSession = .shared,
        usageEndpoint: URL = UsageService.defaultUsageEndpoint,
        userinfoEndpoint: URL = UsageService.defaultUserinfoEndpoint,
        tokenEndpoint: URL = UsageService.defaultTokenEndpoint,
        redirectUri: String = UsageService.defaultRedirectURI,
        credentialsStore: StoredCredentialsStore = StoredCredentialsStore(),
        localProfileLoader: @MainActor @escaping () -> String? = UsageService.loadLocalProfile
    ) {
        self.session = session
        self.usageEndpoint = usageEndpoint
        self.userinfoEndpoint = userinfoEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.redirectUri = redirectUri
        self.credentialsStore = credentialsStore
        self.localProfileLoader = localProfileLoader
        let stored = UserDefaults.standard.integer(forKey: "pollingMinutes")
        let minutes = Self.pollingOptions.contains(stored) ? stored : Self.defaultPollingMinutes
        self.pollingMinutes = minutes
        self.currentInterval = TimeInterval(minutes * 60)
        isAuthenticated = loadCredentials() != nil
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

    // MARK: - OAuth PKCE Flow

    func startOAuthFlow() {
        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        let state = generateCodeVerifier() // random state

        codeVerifier = verifier
        oauthState = state

        var components = URLComponents(url: Self.authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "scope", value: Self.defaultOAuthScopes.joined(separator: " ")),
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
            let (data, response) = try await session.data(for: request)
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
                  let credentials = credentials(from: json) else {
                lastError = "Could not parse token response"
                return
            }

            do {
                try saveCredentials(credentials)
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
        deleteCredentials()
        isAuthenticated = false
        usage = nil
        lastUpdated = nil
        accountEmail = nil
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
        lastError = nil
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
        guard loadCredentials() != nil else {
            lastError = "Not signed in"
            isAuthenticated = false
            return
        }

        do {
            guard let result = try await sendAuthorizedRequest(to: usageEndpoint) else {
                return
            }
            let (data, http) = result
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
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Profile

    func fetchProfile() async {
        if let local = localProfileLoader() {
            accountEmail = local
            return
        }

        guard let result = try? await sendAuthorizedRequest(
            to: userinfoEndpoint,
            expireSessionOnAuthFailure: false
        ) else {
            return
        }
        let (data, http) = result
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let email = json["email"] as? String, !email.isEmpty {
            accountEmail = email
        } else if let name = json["name"] as? String, !name.isEmpty {
            accountEmail = name
        }
    }

    /// Try reading the email from Claude Code's local config as a fallback.
    nonisolated private static func loadLocalProfile() -> String? {
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

    // MARK: - Credential storage

    private func saveCredentials(_ credentials: StoredCredentials) throws {
        try credentialsStore.save(credentials)
    }

    private func loadCredentials() -> StoredCredentials? {
        credentialsStore.load(defaultScopes: Self.defaultOAuthScopes)
    }

    private func deleteCredentials() {
        credentialsStore.delete()
    }

    // MARK: - Authorized requests

    private func sendAuthorizedRequest(
        to url: URL,
        expireSessionOnAuthFailure: Bool = true
    ) async throws -> (Data, HTTPURLResponse)? {
        guard let initialCredentials = loadCredentials() else {
            lastError = "Not signed in"
            isAuthenticated = false
            return nil
        }

        if initialCredentials.needsRefresh() {
            let refreshResult = await refreshCredentials(force: true)
            if refreshResult != .success, initialCredentials.isExpired() {
                switch refreshResult {
                case .permanentFailure:
                    if expireSessionOnAuthFailure {
                        expireSession()
                    }
                case .transientFailure:
                    lastError = "Token refresh failed — will retry"
                case .success:
                    break
                }
                return nil
            }
        }

        let activeCredentials = loadCredentials() ?? initialCredentials

        var result = try await performAuthorizedRequest(
            token: activeCredentials.accessToken,
            url: url
        )

        if result.1.statusCode != 401 {
            return result
        }

        let refreshResult = await refreshCredentials(force: true)
        switch refreshResult {
        case .success:
            guard let refreshedCredentials = loadCredentials() else {
                if expireSessionOnAuthFailure {
                    expireSession()
                }
                return nil
            }

            result = try await performAuthorizedRequest(
                token: refreshedCredentials.accessToken,
                url: url
            )

            if result.1.statusCode == 401 {
                if expireSessionOnAuthFailure {
                    expireSession()
                }
                return nil
            }

            return result

        case .permanentFailure:
            if expireSessionOnAuthFailure {
                expireSession()
            }
            return nil

        case .transientFailure:
            lastError = "Token refresh failed — will retry"
            return nil
        }
    }

    private func performAuthorizedRequest(
        token: String,
        url: URL
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    private func refreshCredentials(force: Bool) async -> RefreshResult {
        if let refreshTask {
            return await refreshTask.value
        }

        let task = Task { [weak self] in
            guard let self else { return RefreshResult.permanentFailure }
            return await self.performRefresh(force: force)
        }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }

    private func performRefresh(force: Bool) async -> RefreshResult {
        guard let currentCredentials = loadCredentials(),
              let refreshToken = currentCredentials.refreshToken,
              refreshToken.isEmpty == false else {
            return .permanentFailure
        }

        if force == false, currentCredentials.needsRefresh() == false {
            return .success
        }

        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
        ]
        if currentCredentials.scopes.isEmpty == false {
            body["scope"] = currentCredentials.scopes.joined(separator: " ")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let http: HTTPURLResponse
        do {
            let (responseData, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .transientFailure
            }
            data = responseData
            http = httpResponse
        } catch {
            return .transientFailure
        }

        guard http.statusCode == 200 else {
            if http.statusCode >= 400, http.statusCode < 500 {
                return .permanentFailure
            }
            return .transientFailure
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let updatedCredentials = credentials(
                from: json,
                fallback: currentCredentials
              ) else {
            return .transientFailure
        }

        do {
            try saveCredentials(updatedCredentials)
        } catch {
            try? await Task.sleep(nanoseconds: 100_000_000)
            do {
                try saveCredentials(updatedCredentials)
            } catch {
                return .transientFailure
            }
        }

        isAuthenticated = true
        return .success
    }

    private func credentials(
        from json: [String: Any],
        fallback: StoredCredentials? = nil
    ) -> StoredCredentials? {
        guard let accessToken = json["access_token"] as? String, accessToken.isEmpty == false else {
            return nil
        }

        let scopeString = json["scope"] as? String
        let scopes = scopeString?
            .split(whereSeparator: \.isWhitespace)
            .map(String.init) ?? fallback?.scopes ?? Self.defaultOAuthScopes

        return StoredCredentials(
            accessToken: accessToken,
            refreshToken: (json["refresh_token"] as? String) ?? fallback?.refreshToken,
            expiresAt: Self.expirationDate(from: json["expires_in"]) ?? fallback?.expiresAt,
            scopes: scopes
        )
    }

    private static func expirationDate(from value: Any?) -> Date? {
        let seconds: TimeInterval?
        switch value {
        case let number as NSNumber:
            seconds = number.doubleValue
        case let number as Double:
            seconds = number
        case let number as Int:
            seconds = TimeInterval(number)
        case let string as String:
            seconds = TimeInterval(string)
        default:
            seconds = nil
        }

        guard let seconds else { return nil }
        return Date().addingTimeInterval(seconds)
    }

    private func expireSession() {
        deleteCredentials()
        isAuthenticated = false
        usage = nil
        lastUpdated = nil
        accountEmail = nil
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
        lastError = "Session expired — please sign in again"
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
