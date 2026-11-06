@testable import ClaudeUsageBar

extension StoredCredentialsStore {
    /// Replaces the shown account's credentials, keeping its id, or adds an account.
    func save(_ credentials: StoredCredentials) throws {
        var accounts = try loadAccounts(defaultScopes: [])
        if accounts.isEmpty {
            accounts = [StoredAccount(credentials: credentials)]
        } else {
            accounts[0].credentials = credentials
        }
        try save(accounts)
    }

    func load(defaultScopes: [String]) -> StoredCredentials? {
        (try? loadAccounts(defaultScopes: defaultScopes))?.first?.credentials
    }
}
