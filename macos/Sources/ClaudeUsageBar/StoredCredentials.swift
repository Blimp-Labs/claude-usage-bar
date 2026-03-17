import Foundation
import Security

struct StoredCredentials: Codable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let scopes: [String]

    var hasRefreshToken: Bool {
        guard let refreshToken else { return false }
        return refreshToken.isEmpty == false
    }

    func needsRefresh(at now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        guard hasRefreshToken, let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(leeway)
    }
}

struct StoredCredentialsStore {
    private let fileManager: FileManager
    private let useKeychain: Bool
    private let keychainService: String
    private let keychainAccount: String
    let directoryURL: URL
    let credentialsFileURL: URL
    let legacyTokenFileURL: URL

    init(
        directoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claude-usage-bar", isDirectory: true),
        fileManager: FileManager = .default,
        useKeychain: Bool = true,
        keychainService: String = "claude-usage-bar",
        keychainAccount: String = "credentials"
    ) {
        self.fileManager = fileManager
        self.useKeychain = useKeychain
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
        self.directoryURL = directoryURL
        self.credentialsFileURL = directoryURL.appendingPathComponent("credentials.json")
        self.legacyTokenFileURL = directoryURL.appendingPathComponent("token")
    }

    func save(_ credentials: StoredCredentials) throws {
        let data = try Self.encoder.encode(credentials)

        if useKeychain {
            try saveToKeychain(data)
            // Remove file-based credentials after successful Keychain save
            try? fileManager.removeItem(at: credentialsFileURL)
        } else {
            try ensureDirectoryExists()
            try data.write(to: credentialsFileURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialsFileURL.path)
        }
        try? fileManager.removeItem(at: legacyTokenFileURL)
    }

    func load(defaultScopes: [String]) -> StoredCredentials? {
        // 1. Try Keychain first
        if useKeychain, let data = loadFromKeychain(),
           let credentials = try? Self.decoder.decode(StoredCredentials.self, from: data) {
            return credentials
        }

        // 2. Try file-based credentials (migration path)
        if let data = try? Data(contentsOf: credentialsFileURL),
           let credentials = try? Self.decoder.decode(StoredCredentials.self, from: data) {
            // Migrate to Keychain if available
            if useKeychain {
                try? saveToKeychain(data)
                try? fileManager.removeItem(at: credentialsFileURL)
            }
            return credentials
        }

        // 3. Try legacy plaintext token file
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
        if useKeychain {
            deleteFromKeychain()
        }
        try? fileManager.removeItem(at: credentialsFileURL)
        try? fileManager.removeItem(at: legacyTokenFileURL)
    }

    // MARK: - Keychain Operations

    private func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private func saveToKeychain(_ data: Data) throws {
        let query = keychainQuery()

        // Try update first, then add
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Keychain save failed (OSStatus \(status))"]
            )
        }
    }

    private func loadFromKeychain() -> Data? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func deleteFromKeychain() {
        SecItemDelete(keychainQuery() as CFDictionary)
    }

    // MARK: - File Helpers

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
