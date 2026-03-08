---
created: 2026-03-08 15:40
modified: 2026-03-08 15:56
session_id: a1b8cc92
---

# Refresh Token Support -- Implementation Plan (v3)

## Problem Statement

The Claude Usage Bar app currently stores only the `access_token` as a plaintext string in `~/.config/claude-usage-bar/token`. When the token expires (typically 4-8 hours), the app calls `signOut()`, forcing the user to manually re-authenticate through the full OAuth PKCE browser flow. This defeats the purpose of a "set and forget" menu bar utility.

The Anthropic OAuth token endpoint already returns `refresh_token` and `expires_in` fields in its response, but the app ignores them.

## Current Architecture

### Token Storage
- **File**: `~/.config/claude-usage-bar/token`
- **Format**: Raw plaintext string (just the access token)
- **Permissions**: `0600` on the file; directory has no explicit permission hardening
- **Functions**: `saveToken(_:)`, `loadToken() -> String?`, `deleteToken()` in `UsageService`

### Token Exchange (line 152-197 of UsageService.swift)
The `submitOAuthCode(_:)` method exchanges the authorization code for tokens. On line 179-183, it parses the JSON response but only extracts `access_token`, discarding `refresh_token` and `expires_in`:
```swift
guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let accessToken = json["access_token"] as? String else {
    lastError = "Could not parse token response"
    return
}
saveToken(accessToken)
```

### Token Usage
Two methods call `loadToken()`:
1. `fetchUsage()` (line 223) -- on 401, calls `signOut()` immediately
2. `fetchProfile()` (line 284) -- silently fails on auth errors; has an early-return at line 279 via `loadLocalProfile()` that fires before any token check for Claude Code users

### Class Design
`UsageService` is `@MainActor`-isolated, which naturally serializes all method calls and prevents concurrent access issues. All API calls, token storage, and state mutations happen on the main actor.

## Design

### 1. StoredCredentials Model

Create a new `Codable` struct to replace the raw string token.

**File location**: `macos/Sources/ClaudeUsageBar/StoredCredentials.swift`

This should be a standalone file following the project convention of one primary type per file (see `UsageModel.swift`, `UsageHistoryModel.swift`).

```swift
// File-based credential storage. Keychain is not used because this app
// ships with ad-hoc signing, which causes Keychain access prompts on
// every launch. File storage at ~/.config/claude-usage-bar/ with
// restricted permissions (dir 0700, file 0600) avoids this.
struct StoredCredentials: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}
```

`expiresAt` is computed at save time from the moment the HTTP response is received (see section 9 for the explicit `responseTime` capture).

The struct contains the following API surface:

**Shared constants**:
- `static let configDirectory: URL` -- `~/.config/claude-usage-bar/`, created with `0700` permissions. This is the default used when no `baseDirectory` is passed. Methods that accept `baseDirectory` compute the file URL inline from the provided directory, ignoring `configDirectory` entirely.
- `static let tokenFileName = "token"`

**Persistence**:
- `func save(baseDirectory: URL? = nil) throws` -- Writes JSON to disk with atomic write option. When `baseDirectory` is nil, uses `Self.configDirectory`; otherwise uses the provided directory directly. Sets directory to `0700` and file to `0600`. **Throws on failure** so callers can decide how to handle write errors.
- `static func load(baseDirectory: URL? = nil) -> StoredCredentials?` -- Reads from disk with migration support. When `baseDirectory` is nil, uses `Self.configDirectory`; otherwise uses the provided directory. Returns nil on missing file or corrupt data.
- `static func delete(baseDirectory: URL? = nil)` -- Removes the file. Swallows errors.

The `baseDirectory` parameter on all three methods enables tests to use a temporary directory without polluting the real config path.

**Computed properties**:
- `var isExpired: Bool` -- `Date() >= expiresAt`. Part of the public API for callers that need to distinguish between "expired" and "expiring soon" (e.g., for logging or UI display), but the refresh decision path does not use this property directly.
- `var needsRefresh: Bool` -- `Date() >= expiresAt.addingTimeInterval(-300)` (true when expired OR within 5 minutes of expiry). This is the sole predicate used by the refresh decision path. It subsumes `isExpired` -- anything that is expired also needs refresh.
- `var hasRefreshToken: Bool` -- `!refreshToken.isEmpty`

### 2. Migration from Plaintext Token

The `load()` method must handle the transition gracefully. When it reads the file:

1. Attempt JSON decode as `StoredCredentials` (using `JSONDecoder` with `.iso8601` date strategy)
2. If that fails, check if the contents are a non-empty UTF-8 string (legacy plaintext token)
3. If it is a legacy plaintext token (trimmed, non-empty), return a `StoredCredentials` with:
   - `accessToken`: the trimmed raw string
   - `refreshToken`: `""` (empty -- cannot be recovered)
   - `expiresAt`: `Date.distantFuture`

**Why `Date.distantFuture`**: A migrated legacy token has no refresh token. Setting `expiresAt` to `distantFuture` ensures `needsRefresh` returns `false`, so no refresh is attempted (which would fail anyway with an empty refresh token). The token is used as-is until the server returns 401, at which point the 401 handler attempts refresh, fails (no refresh token), and signs out -- exactly the same behavior as today, without unnecessary network calls.

4. If the content is empty, not valid UTF-8, or the file does not exist, return nil

### 3. Directory Permission Hardening

In the `configDirectory` computed property (and in `save()` when using a custom `baseDirectory`), after `createDirectory`, apply `0700` permissions:

```swift
try? FileManager.default.setAttributes(
    [.posixPermissions: 0o700], ofItemAtPath: dir.path)
```

The file itself gets `0600`. The directory moves from whatever umask default (usually `0755`) to `0700`, preventing other users from listing the directory contents.

### 4. The `validAccessToken()` Method

Add a central method to `UsageService` that encapsulates all token acquisition logic:

```swift
/// Returns a valid access token, refreshing if needed.
/// Returns nil only when no credentials exist at all.
private func validAccessToken() async -> String? {
    guard let credentials = StoredCredentials.load() else {
        return nil
    }

    if credentials.needsRefresh && credentials.hasRefreshToken {
        if let refreshed = await coalescedRefresh(credentials: credentials) {
            return refreshed.accessToken
        }
        // Refresh failed -- fall through to return existing token.
        // It may still be valid on the server even if our local
        // expiresAt says otherwise (clock skew, server grace period).
    }

    // When hasRefreshToken is false (legacy migration or server didn't
    // provide one), we skip refresh entirely and return the existing
    // token. The server will accept it until it actually expires, at
    // which point the 401 handler takes over.
    return credentials.accessToken
}
```

**Critical behavior**: When `needsRefresh` is true but refresh fails (network error, invalid refresh token) OR when `hasRefreshToken` is false (legacy migration), this method still returns the existing `accessToken`. The caller proceeds with the API call. If the server rejects it with 401, the 401 handler takes over.

### 5. Task Coalescing for Concurrent Refresh

Instead of a simple boolean that silently drops concurrent callers, use a stored `Task` that concurrent callers can await:

```swift
private var refreshTask: Task<StoredCredentials?, Never>?

private func coalescedRefresh(credentials: StoredCredentials) async -> StoredCredentials? {
    if let existing = refreshTask {
        return await existing.value
    }

    let task = Task<StoredCredentials?, Never> {
        await performRefresh(credentials: credentials)
    }
    refreshTask = task
    defer { refreshTask = nil }
    return await task.value
}
```

The `defer` ensures `refreshTask` is set to nil regardless of how `await task.value` completes -- including cancellation.

Since `UsageService` is `@MainActor`, all access to `refreshTask` is serialized. The `Task` created inside inherits the main actor context.

### 6. The `performRefresh()` Method

This is the actual network call, separated from coalescing logic for clarity:

```swift
private func performRefresh(credentials: StoredCredentials) async -> StoredCredentials? {
    guard credentials.hasRefreshToken else { return nil }

    var request = URLRequest(url: tokenEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 30  // 30-second timeout for refresh calls

    let body: [String: String] = [
        "grant_type": "refresh_token",
        "refresh_token": credentials.refreshToken,
        "client_id": clientId,
    ]
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        let responseTime = Date()  // Capture immediately after response receipt

        guard let http = response as? HTTPURLResponse else {
            print("[TokenRefresh] Invalid response type")
            lastError = "Token refresh failed -- invalid response"
            return nil
        }

        // Permanent rejection: the refresh token itself is invalid or revoked.
        // Delete stored credentials to avoid an infinite retry loop.
        if http.statusCode == 400 || http.statusCode == 401 {
            print("[TokenRefresh] Permanent rejection (HTTP \(http.statusCode)) -- clearing credentials")
            lastError = "Session expired -- please sign in again"
            StoredCredentials.delete()
            return nil
        }

        guard http.statusCode == 200 else {
            print("[TokenRefresh] Failed with HTTP \(http.statusCode)")
            lastError = "Token refresh failed (HTTP \(http.statusCode))"
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            print("[TokenRefresh] Could not parse refresh response")
            lastError = "Token refresh failed -- invalid response"
            return nil
        }

        let refreshToken = json["refresh_token"] as? String ?? credentials.refreshToken
        let expiresIn = json["expires_in"] as? TimeInterval ?? 3600
        let newCredentials = StoredCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: responseTime.addingTimeInterval(expiresIn)
        )

        do {
            try newCredentials.save()
        } catch {
            print("[TokenRefresh] Failed to save refreshed credentials: \(error)")
            // Still return the credentials -- they're valid in memory even if disk write failed
        }

        print("[TokenRefresh] Token refreshed successfully, expires in \(Int(expiresIn))s")
        lastError = nil  // Clear any previous refresh error
        return newCredentials
    } catch {
        print("[TokenRefresh] Network error: \(error.localizedDescription)")
        lastError = "Token refresh failed -- \(error.localizedDescription)"
        return nil
    }
}
```

Key details:
- **Timeout**: 30 seconds.
- **Error reporting**: Failures set `lastError` for UI visibility. On success, `lastError` is cleared.
- **Permanent rejection**: HTTP 400/401 from the token endpoint → `StoredCredentials.delete()` to prevent retry loops.
- **Transient failures** (network errors, 5xx): Do NOT delete credentials.
- **Response timestamp**: `responseTime` captured as `Date()` immediately after `URLSession.shared.data(for:)` returns.
- **Logging**: Uses `print()` with `[TokenRefresh]` prefix consistent with the existing codebase.

### 7. Revised `fetchUsage()` with 401 Retry

```swift
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
            // Token rejected -- attempt refresh and retry once
            if let credentials = StoredCredentials.load(),
               credentials.hasRefreshToken,
               let refreshed = await coalescedRefresh(credentials: credentials) {
                // Retry with the NEW token from the refresh response
                var retryRequest = request
                retryRequest.setValue(
                    "Bearer \(refreshed.accessToken)",
                    forHTTPHeaderField: "Authorization"
                )
                do {
                    let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
                    if let retryHttp = retryResponse as? HTTPURLResponse,
                       retryHttp.statusCode == 200 {
                        let decoded = try JSONDecoder().decode(UsageResponse.self, from: retryData)
                        handleSuccessfulUsageResponse(decoded)
                        return
                    }
                } catch {
                    // Retry network/decode failed -- fall through to signOut
                }
            }
            // Refresh failed or retry failed -- sign out
            lastError = "Session expired -- please sign in again"
            signOut()
            return
        }

        // ... 429 handling unchanged ...
        // ... 200 handling extracted to handleSuccessfulUsageResponse() ...
    } catch {
        lastError = error.localizedDescription
    }
}
```

**Critical details**:
- The retry request uses `refreshed.accessToken` from the refresh response, not the stale `token` variable.
- The retry branch uses a separate `do/catch` block so that both `URLSession.shared.data` and `JSONDecoder().decode` can use bare `try`. If either fails, the `catch` falls through to sign-out.
- `handleSuccessfulUsageResponse(_:)` extracts the existing success path to avoid duplication.

### 8. Revised `fetchProfile()` with Refresh

```swift
func fetchProfile() async {
    // Fast path: read from Claude Code's local config
    if let local = Self.loadLocalProfile() {
        accountEmail = local
        return
    }

    // Network path: needs a valid token
    guard let token = await validAccessToken() else { return }

    var request = URLRequest(url: userinfoEndpoint)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

    guard let (data, response) = try? await URLSession.shared.data(for: request),
          let http = response as? HTTPURLResponse else {
        return
    }

    if http.statusCode == 401 {
        if let credentials = StoredCredentials.load(),
           credentials.hasRefreshToken,
           let refreshed = await coalescedRefresh(credentials: credentials) {
            var retryRequest = request
            retryRequest.setValue(
                "Bearer \(refreshed.accessToken)",
                forHTTPHeaderField: "Authorization"
            )
            if let (retryData, retryResponse) = try? await URLSession.shared.data(for: retryRequest),
               let retryHttp = retryResponse as? HTTPURLResponse,
               retryHttp.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: retryData) as? [String: Any] {
                parseProfileResponse(json)
                return
            }
        }
        // fetchProfile does NOT sign out -- fetchUsage is the session authority.
        return
    }

    guard http.statusCode == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return
    }
    parseProfileResponse(json)
}
```

### 9. Changes to `submitOAuthCode`

```swift
guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let accessToken = json["access_token"] as? String else {
    lastError = "Could not parse token response"
    return
}

let responseTime = Date()  // Capture immediately after successful parse
let refreshToken = json["refresh_token"] as? String ?? ""
let expiresIn = json["expires_in"] as? TimeInterval ?? 3600

let credentials = StoredCredentials(
    accessToken: accessToken,
    refreshToken: refreshToken,
    expiresAt: responseTime.addingTimeInterval(expiresIn)
)

do {
    try credentials.save()
} catch {
    lastError = "Failed to save credentials: \(error.localizedDescription)"
    return
}
```

### 10. Extracted Helper Methods

```swift
/// Process a successful /usage response.
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

/// Parse email/name from userinfo JSON.
private func parseProfileResponse(_ json: [String: Any]) {
    if let email = json["email"] as? String, !email.isEmpty {
        accountEmail = email
    } else if let name = json["name"] as? String, !name.isEmpty {
        accountEmail = name
    }
}
```

## Files to Modify

| File | Changes |
|------|---------|
| `macos/Sources/ClaudeUsageBar/StoredCredentials.swift` | **NEW** -- `StoredCredentials` model, file I/O, migration, `configDirectory` |
| `macos/Sources/ClaudeUsageBar/UsageService.swift` | Remove inline token storage; use `StoredCredentials`; add `validAccessToken()`, `coalescedRefresh()`, `performRefresh()`; update `submitOAuthCode`; update 401 handling in both `fetchUsage` and `fetchProfile`; extract `handleSuccessfulUsageResponse` and `parseProfileResponse` |
| `macos/Tests/ClaudeUsageBarTests/StoredCredentialsTests.swift` | **NEW** -- Tests for serialization, migration, expiry logic, permissions |
| `macos/Tests/ClaudeUsageBarTests/UsageServiceTests.swift` | Existing tests unchanged |

## Testing Strategy

The existing test suite follows a clear pattern: pure logic functions are tested directly. No mocking frameworks are used.

### StoredCredentialsTests

These test the `StoredCredentials` model in isolation using a temporary directory:

1. **testRoundTrip** -- Save credentials, load, verify all fields match (expiresAt within 1-second tolerance).
2. **testMigrationFromPlaintextToken** -- Write `"sk-ant-abc123"` to `tmp/token`, verify `accessToken == "sk-ant-abc123"`, `refreshToken == ""`, `expiresAt == Date.distantFuture`.
3. **testMigrationFromPlaintextTokenWithWhitespace** -- Write `"  sk-ant-abc123\n"`, verify `accessToken == "sk-ant-abc123"` (trimmed).
4. **testMigrationFromCorruptFile** -- Write bytes `[0xFF, 0xFE]`, verify `load()` returns nil.
5. **testMigrationFromEmptyFile** -- Write empty data, verify `load()` returns nil.
6. **testMigratedCredentialsDoNotNeedRefresh** -- Load migrated plaintext token, verify `needsRefresh == false`.
7. **testNeedsRefreshReturnsTrueWithinFiveMinutes** -- `expiresAt` 4m59s from now → `needsRefresh == true`.
8. **testNeedsRefreshReturnsFalseWithAmpleTime** -- `expiresAt` 5m01s from now → `needsRefresh == false`.
9. **testNeedsRefreshReturnsTrueAtExactBoundary** -- `expiresAt` exactly 300s from now → `needsRefresh == true` (`>=`).
10. **testNeedsRefreshReturnsTrueWhenExpired** -- `expiresAt` in the past → `needsRefresh == true`.
11. **testIsExpiredReturnsTrueForPastDate** -- Verify `isExpired` for past expiresAt.
12. **testIsExpiredReturnsFalseForFutureDate** -- Verify `isExpired` for future expiresAt.
13. **testHasRefreshTokenReturnsFalseForEmpty** -- `refreshToken == ""` → `hasRefreshToken == false`.
14. **testHasRefreshTokenReturnsTrueForNonEmpty** -- Non-empty → `hasRefreshToken == true`.
15. **testDirectoryPermissions** -- After save, verify directory has `0700`.
16. **testFilePermissions** -- After save, verify file has `0600`.
17. **testDeleteRemovesFile** -- Save, delete, verify load returns nil.
18. **testOverwriteReturnsLatestValues** -- Save A, save B, load returns B.
19. **testValidAccessTokenReturnsTokenWhenNoRefreshToken** -- Empty `refreshToken` + `needsRefresh == false` → `accessToken` still accessible.

### What NOT to test in unit tests

- Actual network calls to the token endpoint
- The full `fetchUsage -> 401 -> refresh -> retry` flow (requires mocking URLSession)
- `coalescedRefresh` behavior (requires async concurrency testing infrastructure)

## Agent-Teams Development Plan

### Teammate 1: StoredCredentials Model + Migration

**Files owned**: `StoredCredentials.swift` (create), `StoredCredentialsTests.swift` (create)

**Deliverable**: Self-contained `StoredCredentials` type with all 19 tests passing. No dependencies on other teammates.

### Teammate 2: Refresh Logic in UsageService

**Files owned**: `UsageService.swift` (modify)

**Deliverable**: UsageService uses `StoredCredentials` for all token operations with proactive refresh, 401 retry, and task coalescing.

**Depends on**: Teammate 1's API contract (can work in parallel using agreed API).

### Teammate 3: Test Review + Enhancement

**Files owned**: `StoredCredentialsTests.swift` (enhance), `UsageServiceTests.swift` (verify)

**Depends on**: Both Teammates 1 and 2.

### Execution Order

```
[Teammate 1: StoredCredentials.swift + tests]  --\
                                                   +--> [Teammate 3: Test review + enhancement]
[Teammate 2: UsageService.swift modifications] --/
```

## Verification Checklist

1. `cd macos && swift build` compiles without errors
2. `cd macos && swift test` passes all tests (existing + new)
3. Token file contains JSON after fresh sign-in
4. Existing plaintext token migrated without disruption
5. Config directory has `0700`, token file has `0600`
6. No Keychain usage in codebase
7. Silent refresh after token expiry
8. `lastError` reflects refresh status; cleared on success
9. Sign out only after both refresh AND retry fail (in `fetchUsage`)
10. `fetchProfile()` never triggers sign-out
11. Legacy tokens work until server-side expiry
12. Concurrent `validAccessToken()` calls coalesce
13. HTTP 400/401 from token endpoint deletes credentials
14. `fetchUsage` retry uses `do/catch` (not bare `try` inside `try?`)

## Risk Considerations

- **Token endpoint might not return `refresh_token`**: Non-fatal; defaults to empty string.
- **`expires_in` absent**: Defaults to 3600 seconds.
- **Refresh token revoked**: HTTP 400/401 → credential deletion → sign-out.
- **`save()` throws during refresh**: Returns in-memory credentials; retries on next cycle.
- **Clock skew**: Falls through to existing token; server decides.
- **Sandboxed CI**: Uses `temporaryDirectory` for tests.
- **Concurrent 401s**: `coalescedRefresh` with `defer` cleanup.
