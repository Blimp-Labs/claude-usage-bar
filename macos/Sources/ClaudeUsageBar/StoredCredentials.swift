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

    func save(_ credentials: StoredCredentials) throws {
        try ensureDirectoryExists()
        let data = try Self.encoder.encode(credentials)
        try data.write(to: credentialsFileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialsFileURL.path)
        try? fileManager.removeItem(at: legacyTokenFileURL)
    }

    func load(defaultScopes: [String]) -> StoredCredentials? {
        if let data = try? Data(contentsOf: credentialsFileURL),
           let credentials = try? Self.decoder.decode(StoredCredentials.self, from: data) {
            return credentials
        }

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

    func delete() {
        try? fileManager.removeItem(at: credentialsFileURL)
        try? fileManager.removeItem(at: legacyTokenFileURL)
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
