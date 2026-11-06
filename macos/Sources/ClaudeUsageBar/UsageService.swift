import Foundation
import Combine
import CryptoKit
import AppKit
@MainActor
class UsageService: ObservableObject {
    @Published var usage: UsageResponse?
    @Published var lastError: String?
    @Published var lastUpdated: Date?
    /// Most recently used first; the first is the one shown.
    @Published private(set) var accounts: [StoredAccount] = []
    @Published private(set) var isAwaitingCode = false
    @Published private(set) var isWaitingForBrowser = false
    /// False when the server reports no 5-hour window (Ultra plans). Remembered
    /// so the menu bar icon has the right shape before the first fetch.
    @Published private(set) var hasFiveHourWindow: Bool

    var isAuthenticated: Bool { !accounts.isEmpty }
    var accountEmail: String? { accounts.first?.email }

    var historyService: UsageHistoryService?
    var notificationService: NotificationService?

    private var timer: Timer?
    private let session: URLSession
    private let usageEndpoint: URL
    private let profileEndpoint: URL
    private let tokenEndpoint: URL
    private let credentialsStore: StoredCredentialsStore
    private let urlOpener: @MainActor (URL) -> Bool
    private let defaults: UserDefaults
    private let startCallbackListener: (@escaping OAuthCallbackListener.Handler) async -> OAuthCallbackListener?
    private var callbackListener: OAuthCallbackListener?
    private var currentInterval: TimeInterval
    private enum RefreshResult {
        case success
        case permanentFailure
        case transientFailure
    }

    private var refreshTasks: [StoredAccount.ID: Task<RefreshResult, Never>] = [:]

    static let defaultPollingMinutes = 30
    static let pollingOptions = [5, 15, 30, 60]
    nonisolated static let maxBackoffInterval: TimeInterval = 60 * 60
    nonisolated static let defaultOAuthScopes = ["user:profile", "user:inference"]
    nonisolated private static let authorizeEndpoint = URL(string: "https://claude.ai/oauth/authorize")!
    nonisolated private static let defaultUsageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    nonisolated private static let defaultProfileEndpoint = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    nonisolated private static let defaultTokenEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    nonisolated private static let defaultRedirectURI = "https://platform.claude.com/oauth/code/callback"
    nonisolated static let usageEndpointOverrideKey = "CLAUDE_USAGE_BAR_USAGE_ENDPOINT"
    nonisolated private static let hasFiveHourWindowKey = "hasFiveHourWindow"
    nonisolated private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// Endpoint override for testing against `scripts/mock-server.py`.
    ///
    /// Only http(s) loopback URLs are honoured — the request carries an OAuth
    /// bearer token, so an environment variable must never be able to redirect
    /// it off this machine. A rejected value is logged rather than silently
    /// ignored, so a typo doesn't look like the mock server being hit.
    nonisolated static func resolvedUsageEndpoint(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let raw = environment[usageEndpointOverrideKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return defaultUsageEndpoint }

        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              loopbackHosts.contains(host) else {
            print("""
            [UsageService] Ignoring \(usageEndpointOverrideKey)="\(raw)" \
            — only http(s) loopback URLs are allowed. \
            Using \(defaultUsageEndpoint.absoluteString).
            """)
            return defaultUsageEndpoint
        }

        print("[UsageService] Using overridden usage endpoint \(url.absoluteString)")
        return url
    }

    /// True when the usage endpoint points at a local mock rather than the real
    /// API. A mock's 401 must never be treated as the real session expiring.
    nonisolated private static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return loopbackHosts.contains(host)
    }

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
        usageEndpoint: URL = UsageService.resolvedUsageEndpoint(),
        profileEndpoint: URL = UsageService.defaultProfileEndpoint,
        tokenEndpoint: URL = UsageService.defaultTokenEndpoint,
        redirectUri: String = UsageService.defaultRedirectURI,
        credentialsStore: StoredCredentialsStore = StoredCredentialsStore(),
        urlOpener: @MainActor @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        startCallbackListener: @escaping (@escaping OAuthCallbackListener.Handler) async -> OAuthCallbackListener? = {
            try? await OAuthCallbackListener.start(handler: $0)
        },
        defaults: UserDefaults = .standard
    ) {
        self.session = session
        self.usageEndpoint = usageEndpoint
        self.profileEndpoint = profileEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.redirectUri = redirectUri
        self.credentialsStore = credentialsStore
        self.urlOpener = urlOpener
        self.startCallbackListener = startCallbackListener
        self.defaults = defaults
        self.hasFiveHourWindow = defaults.object(forKey: Self.hasFiveHourWindowKey) as? Bool ?? true
        let stored = UserDefaults.standard.integer(forKey: "pollingMinutes")
        let minutes = Self.pollingOptions.contains(stored) ? stored : Self.defaultPollingMinutes
        self.pollingMinutes = minutes
        self.currentInterval = TimeInterval(minutes * 60)
        accounts = credentialsStore.loadAccounts(defaultScopes: Self.defaultOAuthScopes)
    }

    // MARK: - Polling

    func startPolling() {
        guard isAuthenticated else { return }
        Task { await poll() }
        scheduleTimer()
    }

    /// Looks the profile up until it loads, for accounts saved by earlier
    /// versions or whose lookup failed at sign-in.
    private func poll() async {
        await fetchUsage()
        if accounts.first?.profileID == nil { await fetchProfile() }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: currentInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isAuthenticated else { return }
                Task { await self.poll() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - OAuth PKCE Flow

    func startOAuthFlow() async {
        endOAuthFlow()
        lastError = nil

        let verifier = generateCodeVerifier()
        let state = generateCodeVerifier() // random state
        codeVerifier = verifier
        oauthState = state

        // Like Claude Code, the browser hands the code back to a listener on
        // 127.0.0.1. Without one, the user pastes the code instead.
        let listener = await startCallbackListener { [weak self] query in
            guard let self else {
                return (400, await SignInPage.html(
                    title: "This sign-in has ended", message: "Start again from Claude Usage Bar."
                ))
            }
            return await self.handleBrowserCallback(query)
        }
        guard oauthState == state else {
            // A newer sign-in started while this listener was starting.
            listener?.stop()
            return
        }
        callbackListener = listener

        let redirectURI = listener?.redirectURI ?? redirectUri
        guard urlOpener(authorizeURL(verifier: verifier, state: state, redirectURI: redirectURI)) else {
            endOAuthFlow()
            lastError = "Could not open Claude sign-in page"
            return
        }
        isWaitingForBrowser = listener != nil
        isAwaitingCode = true
    }

    /// Falls back to pasting a code, for when the browser can't reach the listener.
    func switchToPastedCode() {
        guard let verifier = codeVerifier, let state = oauthState else { return }
        guard urlOpener(authorizeURL(verifier: verifier, state: state, redirectURI: redirectUri)) else {
            lastError = "Could not open Claude sign-in page"
            return
        }
        isWaitingForBrowser = false
    }

    func endOAuthFlow() {
        callbackListener?.stop()
        callbackListener = nil
        codeVerifier = nil
        oauthState = nil
        isAwaitingCode = false
        isWaitingForBrowser = false
    }

    func submitOAuthCode(_ rawCode: String) async {
        // Response format: "code#state" — parse it
        let parts = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#", maxSplits: 1)
        // A whitespace-only paste trims to "" and yields no parts, so guard before
        // indexing. Leave isAwaitingCode set so the user can retry without restarting.
        guard let code = parts.first.map(String.init), !code.isEmpty else {
            lastError = "No OAuth code entered"
            return
        }

        if oauthState != nil {
            guard parts.count > 1 else {
                endOAuthFlow()
                lastError = "Missing OAuth state — expected code#state format"
                return
            }
            let returnedState = String(parts[1])
            guard returnedState == oauthState else {
                endOAuthFlow()
                lastError = "OAuth state mismatch — try again"
                return
            }
        }

        guard let verifier = codeVerifier, let state = oauthState else {
            lastError = "No pending OAuth flow"
            isAwaitingCode = false
            return
        }

        await exchangeCode(code, state: state, verifier: verifier, redirectURI: redirectUri)
    }

    /// Answers the browser's redirect to the listener, and returns the page it shows.
    func handleBrowserCallback(_ query: [URLQueryItem]) async -> (status: Int, html: String) {
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }

        // Anything without this sign-in's state is ignored rather than ending it.
        guard let state = oauthState, value("state") == state,
              let verifier = codeVerifier, let redirectURI = callbackListener?.redirectURI else {
            return (400, SignInPage.html(
                title: "This sign-in has expired", message: "Start a new one from Claude Usage Bar."
            ))
        }
        guard let code = value("code"), !code.isEmpty else {
            guard value("error") != nil else {
                return (400, SignInPage.html(
                    title: "Sign-in didn't finish", message: "No authorization code was received."
                ))
            }
            endOAuthFlow()
            lastError = "Sign-in was canceled in the browser"
            return (200, SignInPage.html(title: "Sign-in canceled", message: "You can close this tab."))
        }

        // The code only works once, so claim this sign-in before exchanging it.
        oauthState = nil
        guard await exchangeCode(code, state: state, verifier: verifier, redirectURI: redirectURI) else {
            endOAuthFlow()
            return (200, SignInPage.html(
                title: "Sign-in didn't finish",
                message: "\(lastError ?? "Unknown error"). Try again from Claude Usage Bar."
            ))
        }
        return (200, SignInPage.html(
            title: "You're signed in", message: "You can close this tab and go back to Claude Usage Bar."
        ))
    }

    @discardableResult
    private func exchangeCode(_ code: String, state: String, verifier: String, redirectURI: String) async -> Bool {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": clientId,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                lastError = "Invalid token response"
                return false
            }
            guard http.statusCode == 200 else {
                let bodyStr = String(data: data, encoding: .utf8) ?? ""
                lastError = "Token exchange failed: HTTP \(http.statusCode) \(bodyStr)"
                return false
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let credentials = credentials(from: json) else {
                lastError = "Could not parse token response"
                return false
            }

            do {
                try updateAccounts { $0.insert(StoredAccount(credentials: credentials), at: 0) }
            } catch {
                lastError = "Failed to save credentials: \(error.localizedDescription)"
                return false
            }
            endOAuthFlow()

            await fetchProfile()
            startPolling()
            return true
        } catch {
            lastError = "Token exchange error: \(error.localizedDescription)"
            return false
        }
    }

    private func authorizeURL(verifier: String, state: String, redirectURI: String) -> URL {
        var components = URLComponents(url: Self.authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: Self.defaultOAuthScopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: generateCodeChallenge(from: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    // MARK: - Accounts

    func switchAccount(to id: StoredAccount.ID) {
        guard !isShown(id) else { return }
        try? updateAccounts { accounts in
            guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
            accounts.insert(accounts.remove(at: index), at: 0)
        }
        startPolling()
    }

    /// Moves to the account used last, if another is signed in.
    func signOut() {
        guard let id = accounts.first?.id else { return }
        removeAccount(id)
    }

    private func removeAccount(_ id: StoredAccount.ID) {
        refreshTasks.removeValue(forKey: id)?.cancel()
        let wasShown = isShown(id)
        try? updateAccounts { $0.removeAll { $0.id == id } }
        if wasShown { startPolling() }
    }

    private func isShown(_ id: StoredAccount.ID) -> Bool {
        accounts.first?.id == id
    }

    /// Edits the accounts as saved, so tokens another copy of the app refreshed aren't lost.
    private func updateAccounts(_ change: (inout [StoredAccount]) -> Void) throws {
        var updated = credentialsStore.loadAccounts(defaultScopes: Self.defaultOAuthScopes)
        change(&updated)
        try credentialsStore.save(updated)
        let shown = accounts.first?.id
        accounts = updated
        if accounts.first?.id != shown { shownAccountDidChange() }
    }

    private func shownAccountDidChange() {
        usage = nil
        lastUpdated = nil
        lastError = nil
        historyService?.setAccount(accounts.first?.profileID)
        if accounts.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private func storedCredentials(for id: StoredAccount.ID) -> StoredCredentials? {
        credentialsStore.loadAccounts(defaultScopes: Self.defaultOAuthScopes)
            .first { $0.id == id }?.credentials
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
        guard let id = accounts.first?.id else {
            lastError = "Not signed in"
            return
        }

        do {
            // A local mock returning 401 must not delete the user's real
            // credentials — the token endpoint is not overridable, so the
            // refresh-then-retry path would otherwise sign them out for real.
            // (It does still refresh against the real token endpoint, which
            // rotates the refresh token; harmless, but worth knowing.)
            let isLocalMock = Self.isLoopback(usageEndpoint)
            let result = try await sendAuthorizedRequest(
                to: usageEndpoint,
                for: id,
                expireSessionOnAuthFailure: !isLocalMock
            )
            // Another account was shown while this one's request was in flight.
            guard isShown(id) else { return }
            guard let result else {
                // expireSession() normally reports this; skipping it must not
                // leave stale numbers on screen with no indication why.
                if isLocalMock, lastError == nil {
                    lastError = "Local endpoint rejected the request — credentials left intact"
                }
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
            hasFiveHourWindow = reconciled.fiveHour != nil
            defaults.set(hasFiveHourWindow, forKey: Self.hasFiveHourWindowKey)
            lastError = nil
            lastUpdated = Date()
            historyService?.recordDataPoint(pct5h: pct5h, pct7d: pct7d)
            notificationService?.checkAndNotify(pct5h: pct5h, pct7d: pct7d, pctExtra: pctExtra)
            if currentInterval != baseInterval {
                currentInterval = baseInterval
                scheduleTimer()
            }
        } catch {
            if isShown(id) { lastError = error.localizedDescription }
        }
    }

    // MARK: - Profile

    func fetchProfile() async {
        guard let id = accounts.first?.id,
              let result = try? await sendAuthorizedRequest(
                to: profileEndpoint,
                for: id,
                expireSessionOnAuthFailure: false
              ) else {
            return
        }
        let (data, http) = result
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["account"] as? [String: Any],
              let accountID = account["uuid"] as? String,
              let email = account["email"] as? String, !email.isEmpty,
              let organization = json["organization"] as? [String: Any],
              let organizationID = organization["uuid"] as? String else {
            return
        }
        // Limits belong to the organization, so one login in two orgs is two accounts.
        let profileID = "\(organizationID)/\(accountID)"
        try? updateAccounts { accounts in
            guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
            accounts[index].profileID = profileID
            accounts[index].email = email
            accounts[index].organizationName = organization["name"] as? String
            // Signing in to an account again replaces its earlier sign-in.
            accounts.removeAll { $0.id != id && $0.profileID == profileID }
        }
        if isShown(id) { historyService?.setAccount(profileID) }
    }

    // MARK: - Authorized requests

    private func sendAuthorizedRequest(
        to url: URL,
        for id: StoredAccount.ID,
        expireSessionOnAuthFailure: Bool = true
    ) async throws -> (Data, HTTPURLResponse)? {
        guard let initialCredentials = storedCredentials(for: id) else { return nil }

        if initialCredentials.needsRefresh() {
            let refreshResult = await refreshCredentials(for: id, force: true)
            if refreshResult != .success, initialCredentials.isExpired() {
                switch refreshResult {
                case .permanentFailure:
                    if expireSessionOnAuthFailure {
                        expireSession(id)
                    }
                case .transientFailure:
                    if isShown(id) { lastError = "Token refresh failed — will retry" }
                case .success:
                    break
                }
                return nil
            }
        }

        let activeCredentials = storedCredentials(for: id) ?? initialCredentials

        var result = try await performAuthorizedRequest(
            token: activeCredentials.accessToken,
            url: url
        )

        if result.1.statusCode != 401 {
            return result
        }

        let refreshResult = await refreshCredentials(for: id, force: true)
        switch refreshResult {
        case .success:
            guard let refreshedCredentials = storedCredentials(for: id) else {
                if expireSessionOnAuthFailure {
                    expireSession(id)
                }
                return nil
            }

            result = try await performAuthorizedRequest(
                token: refreshedCredentials.accessToken,
                url: url
            )

            if result.1.statusCode == 401 {
                if expireSessionOnAuthFailure {
                    expireSession(id)
                }
                return nil
            }

            return result

        case .permanentFailure:
            if expireSessionOnAuthFailure {
                expireSession(id)
            }
            return nil

        case .transientFailure:
            if isShown(id) { lastError = "Token refresh failed — will retry" }
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

    private func refreshCredentials(for id: StoredAccount.ID, force: Bool) async -> RefreshResult {
        if let refreshTask = refreshTasks[id] {
            return await refreshTask.value
        }

        let task = Task { [weak self] in
            guard let self else { return RefreshResult.permanentFailure }
            return await self.performRefresh(for: id, force: force)
        }
        refreshTasks[id] = task
        let result = await task.value
        refreshTasks[id] = nil
        return result
    }

    private func performRefresh(for id: StoredAccount.ID, force: Bool) async -> RefreshResult {
        guard let currentCredentials = storedCredentials(for: id),
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

        // Saved even if another account is shown by now: the old refresh token no longer works.
        func save() throws {
            try updateAccounts { accounts in
                guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
                accounts[index].credentials = updatedCredentials
            }
        }
        do {
            try save()
        } catch {
            try? await Task.sleep(nanoseconds: 100_000_000)
            do {
                try save()
            } catch {
                return .transientFailure
            }
        }

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

    private func expireSession(_ id: StoredAccount.ID) {
        let wasShown = isShown(id)
        removeAccount(id)
        if wasShown && !isAuthenticated {
            lastError = "Session expired — please sign in again"
        }
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
