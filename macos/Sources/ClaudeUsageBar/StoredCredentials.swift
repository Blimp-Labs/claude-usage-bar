import Foundation

struct StoredCredentials: Codable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let scopes: [String]

    var hasRefreshToken: Bool {
        guard let refreshToken else { return false }
        return refreshToken.isEmpty == false
    }

    func needsRefresh(at now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
        guard hasRefreshToken, let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(leeway)
    }

    func isExpired(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

struct StoredAccount: Codable, Equatable, Identifiable {
    var id = UUID()
    var credentials: StoredCredentials
    /// `organization/account` from the profile; nil until it loads.
    var profileID: String?
    var email: String?
    var organizationName: String?
}

struct StoredCredentialsStore {
    private let fileManager: FileManager
    let directoryURL: URL
    let credentialsFileURL: URL
    let legacyTokenFileURL: URL

    init(
        directoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claude-usage-bar", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL
        self.credentialsFileURL = directoryURL.appendingPathComponent("credentials.json")
        self.legacyTokenFileURL = directoryURL.appendingPathComponent("token")
    }

    /// Saving no accounts deletes the file.
    func save(_ accounts: [StoredAccount]) throws {
        guard !accounts.isEmpty else {
            try? fileManager.removeItem(at: credentialsFileURL)
            try? fileManager.removeItem(at: legacyTokenFileURL)
            return
        }
        try ensureDirectoryExists()
        let data = try Self.encoder.encode(AccountsFile(accounts: accounts))
        try data.write(to: credentialsFileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialsFileURL.path)
        try? fileManager.removeItem(at: legacyTokenFileURL)
    }

    /// Most recently used first. Throws when the file is there but can't be read or
    /// decoded, so it's never saved over as no accounts.
    func loadAccounts(defaultScopes: [String]) throws -> [StoredAccount] {
        let credentials: StoredCredentials
        if fileManager.fileExists(atPath: credentialsFileURL.path) {
            let data = try Data(contentsOf: credentialsFileURL)
            if let file = try? Self.decoder.decode(AccountsFile.self, from: data) {
                return file.accounts
            }
            credentials = try Self.decoder.decode(StoredCredentials.self, from: data)
        } else if let token = legacyToken(defaultScopes: defaultScopes) {
            credentials = token
        } else {
            return []
        }

        // Earlier versions saved one account. Its fixed id stays the same even if this save fails.
        let accounts = [StoredAccount(id: Self.migratedAccountID, credentials: credentials)]
        try? save(accounts)
        return accounts
    }

    private static let migratedAccountID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private func legacyToken(defaultScopes: [String]) -> StoredCredentials? {
        guard let data = try? Data(contentsOf: legacyTokenFileURL),
              let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              token.isEmpty == false else {
            return nil
        }

        return StoredCredentials(
            accessToken: token,
            refreshToken: nil,
            expiresAt: nil,
            scopes: defaultScopes
        )
    }

    private struct AccountsFile: Codable {
        var accounts: [StoredAccount]
    }

    private func ensureDirectoryExists() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
