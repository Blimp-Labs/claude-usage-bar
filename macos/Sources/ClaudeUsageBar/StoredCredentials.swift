// StoredCredentials uses file-based storage instead of Keychain because the app
// ships with ad-hoc signing, which causes Keychain access prompts on every
// launch. File storage with restricted permissions (0700 directory, 0600 file)
// avoids this issue while still protecting credentials at rest.

import Foundation

struct StoredCredentials: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date

    static let tokenFileName = "token"

    static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claude-usage-bar")
    }

    // MARK: - Computed Properties

    var isExpired: Bool {
        Date() >= expiresAt
    }

    var needsRefresh: Bool {
        Date() >= expiresAt.addingTimeInterval(-300)
    }

    var hasRefreshToken: Bool {
        !refreshToken.isEmpty
    }

    // MARK: - Persistence

    func save(baseDirectory: URL? = nil) throws {
        let dir = baseDirectory ?? Self.configDirectory
        let fileURL: URL
        if baseDirectory != nil {
            fileURL = dir.appendingPathComponent(Self.tokenFileName)
        } else {
            fileURL = Self.configDirectory.appendingPathComponent(Self.tokenFileName)
        }

        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: fileURL, options: .atomic)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    static func load(baseDirectory: URL? = nil) -> StoredCredentials? {
        let fileURL: URL
        if let baseDirectory = baseDirectory {
            fileURL = baseDirectory.appendingPathComponent(tokenFileName)
        } else {
            fileURL = configDirectory.appendingPathComponent(tokenFileName)
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }

        guard !data.isEmpty else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            return try decoder.decode(StoredCredentials.self, from: data)
        } catch {
            print("[StoredCredentials] JSON decode failed: \(error)")

            // Legacy migration: try reading as plain-text access token
            guard let raw = String(data: data, encoding: .utf8) else {
                return nil
            }

            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return nil
            }

            return StoredCredentials(
                accessToken: trimmed,
                refreshToken: "",
                expiresAt: .distantFuture
            )
        }
    }

    static func delete(baseDirectory: URL? = nil) {
        let fileURL: URL
        if let baseDirectory = baseDirectory {
            fileURL = baseDirectory.appendingPathComponent(tokenFileName)
        } else {
            fileURL = configDirectory.appendingPathComponent(tokenFileName)
        }

        try? FileManager.default.removeItem(at: fileURL)
    }
}
