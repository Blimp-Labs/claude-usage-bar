# ClaudeUsageBar Implementation Plan

## Executive Summary

ClaudeUsageBar is a compact, dependency-free macOS menu bar app in a healthy state for its size. The codebase is coherent and follows a consistent pattern of two `@MainActor ObservableObject` services feeding SwiftUI views. That said, a code audit across all eight source files has identified 30 issues spanning crash-level bugs, architectural debt, production resilience gaps, and UX polish.

The most urgent work is fixing the three force-unwrap crashes (Issues 1, 2, 3) and resolving the two structural problems that affect every poll cycle: the repeated directory creation in computed static properties (Issues 4/18) and the optional-dependency injection anti-pattern (Issue 6). These should be addressed before any release. A second wave covers the remaining tech debt — flush timer correctness, backoff logic, UUID identity, downsampling performance — all of which are behavior-preserving changes with low regression risk. Production hardening (logging, versioning, large-file guards) and UX polish (animations, tooltip positioning, color semantics) form the final two phases and can proceed independently once the structural work is stable.

The expected outcomes are: zero known crash paths, consistent and deterministic chart rendering, a clean separation between view and service responsibilities, a maintainable logging trail for diagnosing production issues, and a noticeably more polished popover UI.

---

## Critical Bugs

### Bug 1 — Force unwrap in `parseSVGPath` `num()`

**Problem:** Inside `parseSVGPath(_:)` in `MenuBarIconRenderer.swift` line 137, the inner `num()` function returns `CGFloat(Double(String(chars[start..<i]))!)`. The `!` force-unwraps `Double(String(...))`, which is a failable initializer returning `Optional<Double>`. If the substring contains only `"-"` (minus sign with nothing after it), or consists of a lone `.` character, or is otherwise an incomplete numeric token, the double conversion returns `nil` and the force-unwrap crashes the app. The outer `num()` function signature is `-> CGFloat?`, implying the callers are already prepared for a nil result — the crash is purely an implementation oversight inside the function body.

**Impact:** Hard crash (`EXC_BAD_INSTRUCTION`) whenever the SVG parser encounters a malformed numeric token. The hardcoded `claudeSVG` constant is well-formed, so this does not trigger in normal operation today. However, any future modification to the SVG string (even a trailing space or a minus with no following digit) will crash the app at launch, because `drawClaudeLogo` is called unconditionally when drawing the menu bar icon.

**Affected file(s):** `MenuBarIconRenderer.swift`, line 137.

**Fix:** Replace the force-unwrap with a guarded optional binding. The `num()` function should return `nil` on a failed parse, consistent with its declared return type:

```swift
// Before (line 137):
return CGFloat(Double(String(chars[start..<i]))!)

// After:
guard let d = Double(String(chars[start..<i])) else { return nil }
return CGFloat(d)
```

No call sites change — all callers already use `guard let x = num() else { break }`.

**Testing:** Add a unit test (when tests are introduced) that calls `parseSVGPath` with edge-case inputs: `"M- 10"`, `"M . 10"`, `"M"` (empty number). Manually verify the app does not crash with any of these. In the meantime, replace the SVG constant with a deliberately malformed variant in a local debug build and confirm the path returns an empty `NSBezierPath` rather than crashing.

---

### Bug 2 — Force unwrap on `proxy.plotFrame` in chart overlay

**Problem:** `UsageChartView.swift` line 111: `geo[proxy.plotFrame!]`. The `plotFrame` property on `ChartProxy` is `Anchor<CGRect>?`. It is nil when the chart has not completed layout — which can happen on the first appearance of the popover, on window resize, or any time SwiftUI invalidates the chart's layout before the overlay geometry reader has resolved. Force-unwrapping an `Anchor` that is nil crashes with a fatal error.

**Impact:** Intermittent crash triggered by hover events that arrive before the chart finishes its first layout pass. Reproducible by moving the mouse onto the chart immediately after opening the popover, or by resizing the popover window while hovering.

**Affected file(s):** `UsageChartView.swift`, line 111.

**Fix:** Guard the optional before use. If `plotFrame` is nil, exit the hover handler silently:

```swift
// Before (line 111):
let plotOrigin = geo[proxy.plotFrame!].origin

// After:
guard let plotFrame = proxy.plotFrame else { return }
let plotOrigin = geo[plotFrame].origin
```

**Testing:** Open the popover and immediately move the mouse over the chart area before any data has rendered. Confirm no crash. Resize the popover window while hovering over the chart. Confirm no crash.

---

### Bug 3 — Force unwrap on sorted array bounds in interpolation

**Problem:** `UsageChartView.swift` lines 165: `sorted.first!.timestamp` and `sorted.last!.timestamp`. Although a `guard !points.isEmpty` check exists on line 160, `sorted` is a separately derived array (`let sorted = points.sorted(...)`) created on line 162. If `points` is mutated concurrently between the guard check and the array access — or if the guard is removed or reorganised during future refactoring — accessing `first!` and `last!` on an empty array will crash.

**Impact:** Low probability of triggering today because `@MainActor` isolation prevents concurrent mutation in practice. However, the pattern is fragile and will bite during refactoring.

**Affected file(s):** `UsageChartView.swift`, lines 165.

**Fix:** Use the optional `first` and `last` properties with guard:

```swift
// Before (lines 165):
if date < sorted.first!.timestamp || date > sorted.last!.timestamp {

// After:
guard let firstPoint = sorted.first, let lastPoint = sorted.last else { return nil }
if date < firstPoint.timestamp || date > lastPoint.timestamp {
```

**Testing:** Verify that calling `interpolateValues(at:in:)` with an empty array returns `nil` without crashing. The existing `guard !points.isEmpty` guard makes this unreachable in practice, but the defensive coding removes the dependency on that guard remaining in place.

---

## Tech Debt

### Issue 4 / Issue 18 — Static property side effects and duplicated config path

**Problem:** Both `UsageService.tokenFileURL` (lines 31–36) and `UsageHistoryService.historyFileURL` (lines 16–21) are computed `static var` properties. Each one calls `FileManager.default.createDirectory(at:withIntermediateDirectories:true)` as a side effect every time the property is accessed. The config directory path `~/.config/claude-usage-bar/` is also duplicated across both files as an inline string. Every call to `loadToken()`, `saveToken()`, `deleteToken()`, `loadHistory()`, and `flushToDisk()` results in a redundant syscall.

**Impact:** Minor performance overhead on every file I/O operation. The duplication makes it easy to introduce a typo that causes the two services to use different directories.

**Affected file(s):** `UsageService.swift` lines 31–36; `UsageHistoryService.swift` lines 16–21.

**Fix:** Extract a shared `ConfigDirectory` namespace with a `url: URL` property that creates the directory lazily once. Place it in a new file `ConfigDirectory.swift` or at the top of `UsageHistoryService.swift`:

```swift
// New: ConfigDirectory.swift (or at file scope in a shared location)
enum ConfigDirectory {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claude-usage-bar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}
```

Then replace both computed properties with simple `let` constants:

```swift
// UsageService.swift — replace lines 31-36:
private static let tokenFileURL = ConfigDirectory.url.appendingPathComponent("token")

// UsageHistoryService.swift — replace lines 16-21:
private static let historyFileURL = ConfigDirectory.url.appendingPathComponent("history.json")
```

The directory is created once when `ConfigDirectory.url` is first accessed, which happens before any file I/O operation. No call site changes required.

**Migration Notes:** The `ConfigDirectory.url` lazy initializer should be called explicitly at app startup in `ClaudeUsageBarApp` (e.g., `_ = ConfigDirectory.url`) before either service performs any I/O, to make the initialization point explicit rather than implicit on first access. Add a comment noting this.

---

### Issue 5 — View directly mutates service state

**Problem:** `PopoverView.swift` line 173: the Cancel button in `CodeEntryView` sets `service.isAwaitingCode = false` directly. This bypasses any cleanup `UsageService` might need: clearing `codeVerifier` and `oauthState` to prevent a stale PKCE state from interfering with a subsequent auth attempt.

**Affected file(s):** `PopoverView.swift` line 173; `UsageService.swift` (new method needed).

**Fix:** Add a `cancelOAuthFlow()` method to `UsageService` that performs the complete cleanup:

```swift
// UsageService.swift — add after startOAuthFlow():
func cancelOAuthFlow() {
    isAwaitingCode = false
    codeVerifier = nil
    oauthState = nil
}
```

Update the Cancel button in `CodeEntryView`:

```swift
// PopoverView.swift line 173 — before:
service.isAwaitingCode = false

// after:
service.cancelOAuthFlow()
```

**Migration Notes:** Check the entire codebase for any other direct writes to `service.isAwaitingCode` from view code; at present there are none beyond line 173, but this should be verified after any view refactoring.

---

### Issue 6 — Optional dependency injection anti-pattern

**Problem:** `UsageService.historyService` is declared as `var historyService: UsageHistoryService?` on line 14 of `UsageService.swift`, then assigned via `service.historyService = historyService` inside a `.task` block on an `Image` in `ClaudeUsageBarApp.swift` (lines 16–20). Between app launch and the first SwiftUI layout pass that triggers the `.task`, the property is nil. Any poll that completes before that assignment silently drops the data point (line 222: `historyService?.recordDataPoint(...)`). The property is required for correct operation but looks optional throughout the codebase.

**Affected file(s):** `UsageService.swift` line 14; `ClaudeUsageBarApp.swift` lines 5–20.

**Fix:** Change `UsageService.init()` to accept a `historyService` parameter. Remove the post-init assignment and the optional:

```swift
// UsageService.swift — before:
var historyService: UsageHistoryService?
init() { isAuthenticated = loadToken() != nil }

// after:
private let historyService: UsageHistoryService
init(historyService: UsageHistoryService) {
    self.historyService = historyService
    isAuthenticated = loadToken() != nil
}
// all call sites change from historyService?.recordDataPoint to historyService.recordDataPoint
```

`ClaudeUsageBarApp.swift` then becomes:

```swift
// before:
@StateObject private var service = UsageService()
@StateObject private var historyService = UsageHistoryService()
// ... service.historyService = historyService in .task

// after:
@StateObject private var historyService = UsageHistoryService()
@StateObject private var service: UsageService
init() {
    let hs = UsageHistoryService()
    _historyService = StateObject(wrappedValue: hs)
    _service = StateObject(wrappedValue: UsageService(historyService: hs))
}
```

The `.task` block is simplified to only call `historyService.loadHistory()` and `service.startPolling()`, removing the injection assignment.

**Migration Notes:** The `App` struct `init()` pattern with `StateObject` wrapping requires care — `StateObject` must be initialised exactly once. The above pattern is correct because `@StateObject` stores its initial value but only uses it once. Alternatively, introduce a coordinator/app-level class that owns both services and passes the reference at init time, avoiding the `@main` struct `init()` complexity.

---

### Issue 7 — UUID regeneration breaks SwiftUI chart identity

**Problem:** `UsageDataPoint.id` is `UUID()` in `init` (line 10, `UsageHistoryModel.swift`). `downsampledPoints(for:)` in `UsageHistoryService.swift` lines 120–124 creates new `UsageDataPoint` instances by calling the normal initialiser. Each call generates new UUIDs. Since SwiftUI's `ForEach` uses `id` for view identity, every call to `downsampledPoints` on re-render causes the chart to believe all points have been replaced, destroying animation continuity and forcing a full diff.

**Affected file(s):** `UsageHistoryModel.swift` lines 9–14; `UsageHistoryService.swift` lines 115–125.

**Fix:** Generate a deterministic ID for downsampled points based on the bucket index and the selected range. Since the bucket index and range uniquely identify the aggregation slot, two renders of the same range with similar data will produce the same IDs:

```swift
// UsageHistoryService.swift — in downsampledPoints, replace lines 120-124:
let bucketID = UUID(uuid: (
    UInt8(bucketIndex & 0xFF), UInt8((bucketIndex >> 8) & 0xFF), 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
))
return UsageDataPoint(
    id: bucketID,
    timestamp: Date(timeIntervalSince1970: avgTimestamp),
    pct5h: avgPct5h,
    pct7d: avgPct7d
)
```

To support this, add a second `init` to `UsageDataPoint` that accepts an explicit `id`:

```swift
// UsageHistoryModel.swift — add:
init(id: UUID, timestamp: Date, pct5h: Double, pct7d: Double) {
    self.id = id
    self.timestamp = timestamp
    self.pct5h = pct5h
    self.pct7d = pct7d
}
```

The `bucketIndex` variable already exists in the `compactMap` closure but must be tracked via `enumerated()`.

**Migration Notes:** Because `id` is `var`, this is backward-compatible with JSON decoding of existing `history.json` files (see also Issue 19, which proposes excluding `id` from `CodingKeys`).

---

### Issue 8 — Repeated sorting and downsampling on hover

**Problem:** On every mouse-move event, `chartView(points:)` calls `interpolateValues(at:in:)` (line 34 of `UsageChartView.swift`), which calls `points.sorted(...)` on line 162. Additionally, `downsampledPoints(for:selectedRange)` is called inside the `body` computed property (line 19), meaning it runs on every view body evaluation — including every hover position change. With 200 points and a 60fps hover event rate, this is up to 12,000 sort operations per second.

**Affected file(s):** `UsageChartView.swift` lines 19, 34, 162.

**Fix:** Cache the downsampled, pre-sorted points in `@State` and only recompute when `selectedRange` or `history.dataPoints` changes:

```swift
// UsageChartView.swift — add state:
@State private var cachedPoints: [UsageDataPoint] = []

// Add .onChange modifiers to rebuild the cache:
.onChange(of: selectedRange) { _ in rebuildCache() }
.onChange(of: historyService.history.dataPoints.count) { _ in rebuildCache() }
.onAppear { rebuildCache() }

private func rebuildCache() {
    cachedPoints = historyService.downsampledPoints(for: selectedRange)
        .sorted { $0.timestamp < $1.timestamp }
}
```

Replace the `let points = historyService.downsampledPoints(for: selectedRange)` on line 19 with `let points = cachedPoints`. Remove the `sorted` call inside `interpolateValues` since the input is now guaranteed sorted.

**Migration Notes:** The `.onChange(of:)` modifier for `history.dataPoints.count` may not catch all mutations (e.g., if count stays the same but values change). A more robust trigger is to make `UsageHistoryService` publish a `lastUpdated: Date` that changes on every `recordDataPoint` call, and observe that instead.

---

### Issue 9 — Flush timer not cancelled when `isDirty` is false

**Problem:** `UsageHistoryService.flushToDisk()` (line 73) begins with `guard isDirty else { return }`. When called from `willTerminateNotification` with no new data since the last flush, the function returns early without cancelling `flushTimer`. If the timer fires again before termination completes, it re-enters the same dead path. The timer leaks until deallocation.

**Affected file(s):** `UsageHistoryService.swift` lines 72–81.

**Fix:** Always cancel the timer in `flushToDisk()`, regardless of dirty state:

```swift
func flushToDisk() {
    flushTimer?.cancel()
    flushTimer = nil
    guard isDirty else { return }
    // ... existing flush logic unchanged
    isDirty = false
}
```

This is safe because `startFlushTimerIfNeeded()` guards on `flushTimer == nil`, so the timer will be recreated on the next `recordDataPoint` if needed.

**Migration Notes:** This is a purely additive two-line change with no observable behavior difference under normal usage.

---

### Issue 10 — Implicit backoff freeze on non-429 errors

**Problem:** `UsageService.fetchUsage()` (lines 214–229) handles three cases: 401 (sign out), 429 (double interval), 200 (reset to base, redecedule). Any other status code (500, 503, network error) hits the `catch` block or the `guard http.statusCode == 200` branch and returns without modifying `currentInterval`. If a prior 429 pushed the interval to 240 seconds and the next poll gets a 500, the interval stays at 240 seconds indefinitely until a 200 arrives. There is no escape hatch.

**Affected file(s):** `UsageService.swift` lines 213–229.

**Fix:** Chosen strategy — reset `currentInterval` to `baseInterval` on any non-429 non-success response. This treats server errors as transient rather than as signals to back off further. Document the decision with an inline comment:

```swift
guard http.statusCode == 200 else {
    // Non-429 errors (e.g. 500) do not indicate rate limiting.
    // Reset to base interval so temporary server failures don't
    // strand the polling interval at a previously backed-off value.
    if currentInterval != baseInterval {
        currentInterval = baseInterval
        scheduleTimer()
    }
    lastError = "HTTP \(http.statusCode)"
    return
}
```

**Migration Notes:** The `catch` block at line 227 should similarly reset the interval: `if currentInterval != baseInterval { currentInterval = baseInterval; scheduleTimer() }`.

---

### Issue 11 — `generateCodeVerifier()` reused for OAuth state

**Problem:** `UsageService.swift` line 70: `let state = generateCodeVerifier()`. The function name implies PKCE-verifier semantics (32 cryptographic random bytes, Base64URL-encoded). Using it for the OAuth `state` parameter works but is semantically confusing to future readers and conflates two distinct security primitives.

**Affected file(s):** `UsageService.swift` lines 70, 171–175.

**Fix:** Extract a general helper and call both from it:

```swift
private func generateRandomBase64URL(byteCount: Int = 32) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return Data(bytes).base64URLEncoded()
}

private func generateCodeVerifier() -> String { generateRandomBase64URL() }
// Line 70: let state = generateRandomBase64URL()
```

**Migration Notes:** No caller changes required beyond replacing `generateCodeVerifier()` on line 70 with `generateRandomBase64URL()`. The underlying output is identical.

---

### Issue 12 — Hardcoded `NSColor.black` in menu bar drawing

**Problem:** `MenuBarIconRenderer.swift` lines 19, 80, 88, 96, 114 use `NSColor.black` for foreground and fill colors. Since `image.isTemplate = true` (lines 49, 72), macOS uses the alpha channel as a mask and recolors the image automatically for light/dark mode and active/inactive states. The actual color specified is irrelevant at runtime — but it is invisible documentation debt.

**Affected file(s):** `MenuBarIconRenderer.swift` lines 19, 80, 88, 96, 114.

**Fix:** This is low risk. At minimum, add a comment in `makeAttrs()` and the drawing functions explaining the intentional use of black with template images:

```swift
// Template images use alpha as a mask; actual color is replaced by macOS.
// NSColor.black is used as the drawing color solely for maximum alpha opacity.
private func makeAttrs() -> [NSAttributedString.Key: Any] { ... }
```

Optionally, replace with `NSColor.labelColor` which is semantically correct for foreground content and also produces full-opacity alpha, making the template image behavior identical while being self-documenting. This change requires verifying the alpha output of `labelColor` is consistently 1.0.

**Migration Notes:** If `isTemplate` is ever set to `false` to support colored icons, replace all `NSColor.black` with semantic color choices at that time.

---

### Issue 13 — `.task` on `MenuBarExtra` label `Image`

**Problem:** `ClaudeUsageBarApp.swift` lines 16–20. The `.task` modifier is attached to the `Image` inside the `MenuBarExtra` label closure. This label closure re-evaluates on every state change (it reads `service.isAuthenticated`, `service.pct5h`, `service.pct7d`). SwiftUI's `.task` is tied to view identity, not re-evaluation frequency, so it should fire only once — but attaching initialization logic to a label `Image` is unconventional and its behavior under edge cases (e.g., the `MenuBarExtra` being toggled off and on) is not well-specified.

**Affected file(s):** `ClaudeUsageBarApp.swift` lines 8–23.

**Fix:** Move the initialization sequence to `PopoverView.onAppear` or, better, to the `App` struct's `init()`:

```swift
// ClaudeUsageBarApp.swift — move init logic to App init:
init() {
    // historyService and service are already initialized via @StateObject wrapping.
    // Startup I/O and polling are deferred to onAppear in PopoverView.
}
```

In `PopoverView.swift`, add:

```swift
.onAppear {
    historyService.loadHistory()
    service.startPolling()
}
```

This approach is conventional, clearly scoped to the view lifecycle, and avoids the label closure ambiguity. If Issue 6 is addressed first (injecting `historyService` into `UsageService.init()`), the `service.historyService = historyService` line is already removed, making this migration simpler.

**Migration Notes:** Confirm that `onAppear` fires only once for a `MenuBarExtra` content window on first open. If it fires on every popover open, add a guard using a boolean `@State` flag or by checking `service.isPollingStarted`.

---

### Issue 14 — Silent sign-out on 401 with no user notice

**Problem:** `UsageService.fetchUsage()` line 201–204: on a 401 response, `signOut()` is called immediately, wiping `usage`, `lastUpdated`, and the token. The user sees the sign-in screen with no explanation of why they were signed out. The last-known usage data is discarded.

**Affected file(s):** `UsageService.swift` lines 201–205, 161–167.

**Fix:** Preserve `usage` and `lastUpdated` on sign-out-due-to-401, and set a clear error message before showing the sign-in view:

```swift
// New method in UsageService:
private func handleSessionExpiry() {
    lastError = "Your session expired. Please sign in again."
    deleteToken()
    isAuthenticated = false
    isAwaitingCode = false
    // Intentionally do NOT clear usage or lastUpdated — user can still see last data.
    timer?.cancel()
    timer = nil
}
```

```swift
// fetchUsage() line 201-204 — replace signOut() with:
if http.statusCode == 401 {
    handleSessionExpiry()
    return
}
```

If the API supports refresh tokens (currently unknown from the code), add a `refreshToken()` method that attempts a token refresh before falling back to `handleSessionExpiry()`. The current token storage saves only the access token, so this would also require storing the refresh token. Leave a `// TODO: attempt token refresh here before signing out` comment if refresh is deferred.

**Migration Notes:** The sign-out button in `PopoverView` should continue calling the existing `signOut()` (which clears all state), since that is an intentional user action. The session-expiry path is distinct.

---

### Issue 15 — `ExtraUsageRow` hardcoded `.blue` progress tint

**Problem:** `PopoverView.swift` line 239: `ProgressView(...).tint(.blue)`. The other usage rows use `colorForPct()` for semantic green/yellow/red coloring. Extra usage always appears blue regardless of proximity to the limit, making the color meaningless as a signal.

**Affected file(s):** `PopoverView.swift` line 239.

**Fix:** Apply `colorForPct()` to extra usage, using the normalized utilization value:

```swift
// Before (line 239):
.tint(.blue)

// After:
.tint(colorForPct((extra.utilization ?? 0) / 100.0))
```

**Migration Notes:** `colorForPct` is a file-private function at the bottom of `PopoverView.swift`. It is already accessible to `ExtraUsageRow` since both are in the same file. No visibility change required.

---

### Issue 16 — No loading indicator on refresh

**Problem:** `PopoverView.swift` lines 121–124: clicking "Refresh" fires `Task { await service.fetchUsage() }` with no visual feedback. On slow connections the user sees nothing happening for several seconds.

**Affected file(s):** `UsageService.swift` (new published property); `PopoverView.swift` lines 121–124.

**Fix:** Add `@Published var isLoading = false` to `UsageService`. Use `defer` in `fetchUsage()` to guarantee the flag is cleared in all exit paths:

```swift
// UsageService.swift — add property:
@Published var isLoading = false

// fetchUsage() — at the top:
isLoading = true
defer { isLoading = false }
// ... rest of function unchanged
```

In `PopoverView.swift`, replace the Refresh button text with a conditional spinner:

```swift
Button {
    Task { await service.fetchUsage() }
} label: {
    if service.isLoading {
        ProgressView().controlSize(.mini)
    } else {
        Text("Refresh")
    }
}
.buttonStyle(.borderless)
.font(.caption)
.disabled(service.isLoading)
```

**Migration Notes:** `isLoading` should also be set to `false` in the `catch` block and all early-return paths. The `defer` statement handles this automatically as long as all returns are within the same function scope.

---

### Issue 19 — UUID serialized unnecessarily in `history.json`

**Problem:** `UsageDataPoint` conforms to `Codable` and encodes `id: UUID` (line 4, `UsageHistoryModel.swift`). The UUID is a runtime identity for SwiftUI diffing and has no persistent meaning. At 43,200 points (30 days at 1-minute polling), the UUID field wastes approximately 1.7 MB of JSON storage.

**Affected file(s):** `UsageHistoryModel.swift` lines 3–15.

**Fix:** Add a custom `CodingKeys` enum that excludes `id`, and implement `init(from:)` to assign a fresh UUID on decode:

```swift
struct UsageDataPoint: Codable, Identifiable {
    var id: UUID
    let timestamp: Date
    let pct5h: Double
    let pct7d: Double

    init(timestamp: Date = Date(), pct5h: Double, pct7d: Double) {
        self.id = UUID()
        self.timestamp = timestamp
        self.pct5h = pct5h
        self.pct7d = pct7d
    }

    enum CodingKeys: String, CodingKey {
        case timestamp, pct5h, pct7d
        // id excluded intentionally — assigned fresh on decode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.pct5h = try c.decode(Double.self, forKey: .pct5h)
        self.pct7d = try c.decode(Double.self, forKey: .pct7d)
    }
}
```

**Migration Notes:** Existing `history.json` files contain `id` fields. The new decoder ignores unknown keys by default (Swift's `JSONDecoder` ignores extra fields in keyed containers), so old files decode cleanly. New writes omit the field. No migration step required.

---

### Issue 20 — Uniform `targetPointCount` across all time ranges

**Problem:** `TimeRange.targetPointCount` returns 200 for `day1`, `day7`, and `day30` (lines 43–47, `UsageHistoryModel.swift`). For `day30`, 200 points over 30 days yields one point per ~3.6 hours — overly coarse given the 1-minute polling rate. For `day1`, 200 points over 24 hours yields one point per ~7 minutes, which is moderately dense. For `hour1`, 120 points over 1 hour means one point per 30 seconds — finer than the 60-second polling interval, so many buckets will be empty.

**Affected file(s):** `UsageHistoryModel.swift` lines 40–48.

**Fix:** Set `targetPointCount` to values that align with meaningful time granularity at each scale:

```swift
var targetPointCount: Int {
    switch self {
    case .hour1:  return 60   // 1 point per minute — matches poll interval exactly
    case .hour6:  return 72   // 1 point per 5 minutes
    case .day1:   return 144  // 1 point per 10 minutes
    case .day7:   return 336  // 1 point per 30 minutes
    case .day30:  return 360  // 1 point per 2 hours
    }
}
```

Rationale: `hour1` at 60 points provides maximum resolution for the most granular view. `hour6` at 72 provides 5-minute granularity, appropriate for short-term trend analysis. `day1` at 144 provides 10-minute granularity, balancing resolution and render performance. `day7` at 336 provides 30-minute granularity, sufficient for daily usage patterns. `day30` at 360 provides 2-hour granularity, sufficient for multi-day trends.

**Migration Notes:** The `downsampledPoints` function in `UsageHistoryService` uses `targetPointCount` as the bucket count. Changing these values takes effect immediately on the next render — no data migration required. The chart frame height is fixed at 120pt (Issue 17), so density should not cause rendering slowdowns at these counts.

---

## Production Hardening

### Issue 21 — No structured logging

**Problem:** There are no `os_log` or `Logger` calls anywhere in the codebase. Errors are surfaced only via `lastError: String?` in the UI. Diagnosing issues in production (e.g., a user reporting intermittent sign-out) is impossible without log access.

**Affected file(s):** All source files; primarily `UsageService.swift` and `UsageHistoryService.swift`.

**Fix:** Add `import OSLog` and create a subsystem-level `Logger` in a shared location. One option is a `private extension Logger` or a global constant:

```swift
// New: Logging.swift (or top of UsageService.swift)
import OSLog
extension Logger {
    static let app = Logger(subsystem: "com.local.ClaudeUsageBar", category: "app")
    static let network = Logger(subsystem: "com.local.ClaudeUsageBar", category: "network")
    static let history = Logger(subsystem: "com.local.ClaudeUsageBar", category: "history")
}
```

Log at appropriate levels:

```swift
// UsageService — startPolling:
Logger.network.info("Starting polling, interval=\(self.currentInterval)s")

// UsageService — fetchUsage 429:
Logger.network.warning("Rate limited, backing off to \(self.currentInterval)s")

// UsageService — fetchUsage 401:
Logger.network.error("Session expired (401), signing out")

// UsageService — fetchUsage success:
Logger.network.info("Usage fetched successfully, pct5h=\(self.pct5h), pct7d=\(self.pct7d)")

// UsageHistoryService — flushToDisk:
Logger.history.info("Flushed \(self.history.dataPoints.count) points to disk")

// UsageHistoryService — loadHistory corrupt:
Logger.history.error("Corrupt history file, backing up and resetting")
```

Remove `print` statements if any exist (none found in current code). `os_log`/`Logger` output is visible in Console.app filtered by subsystem `com.local.ClaudeUsageBar`.

**Migration Notes:** `OSLog` is available on macOS 11+. The project targets macOS 14+, so no availability guards are needed. The `Logger` struct (Swift overlay) is available on macOS 11+.

---

### Issue 22 — No version/build number in popover

**Problem:** There is no version information displayed in the popover. Users cannot tell which build they have installed. The Info.plist has `CFBundleShortVersionString = 1.0.0` and `CFBundleVersion = 1`.

**Affected file(s):** `PopoverView.swift` (footer area near Quit button); `Resources/Info.plist`.

**Fix:** Read the version from `Bundle.main` and display it in the popover footer. Handle the `swift run` case (no bundle) gracefully:

```swift
// PopoverView.swift — add a computed property:
private var versionString: String {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    if let build {
        return "v\(version) (\(build))"
    }
    return "v\(version)"
}
```

Add to the `usageView` bottom footer:

```swift
// PopoverView.swift — in the bottom HStack near Quit:
Text(versionString)
    .font(.caption2)
    .foregroundStyle(.tertiary)
```

Position it at the trailing edge of the footer, after the Quit button, or on a separate line below.

**Migration Notes:** No Info.plist changes needed beyond keeping version keys current. When releasing a new build, bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.

---

### Issue 23 — `clientId` inline string with no documentation

**Problem:** `UsageService.swift` line 22: `private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"` has no comment explaining what it is, where it was registered, or how to update it.

**Affected file(s):** `UsageService.swift` line 22.

**Fix:** Add an explanatory comment:

```swift
// OAuth client ID registered at console.anthropic.com for the ClaudeUsageBar app.
// Update this value if the OAuth application is re-registered.
private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
```

Optionally promote to `private static let clientId` for clarity that it is a type-level constant with no instance-specific state.

**Migration Notes:** Zero behavior change — documentation only.

---

### Issue 24 — No resilience for large history files

**Problem:** `UsageHistoryService.loadHistory()` and `flushToDisk()` perform JSON encoding/decoding synchronously on the main thread (both are `@MainActor`). If `history.json` grows unusually large (e.g., due to a bug that bypasses pruning, or running multiple app instances that both write), decoding/encoding could block the main thread for hundreds of milliseconds.

**Affected file(s):** `UsageHistoryService.swift` lines 43–59, 72–82.

**Fix:** Add a file size guard before loading. Warn (via `os_log`) and truncate if over a threshold:

```swift
func loadHistory() {
    let url = Self.historyFileURL
    guard FileManager.default.fileExists(atPath: url.path) else { return }

    // Guard against abnormally large files (> 5 MB indicates a bug)
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let fileSize = attributes?[.size] as? Int ?? 0
    if fileSize > 5 * 1_048_576 {
        Logger.history.error("history.json exceeds 5 MB (\(fileSize) bytes) — truncating")
        try? FileManager.default.removeItem(at: url)
        history = UsageHistory()
        return
    }
    // ... existing decode logic
}
```

For the encoding path, consider moving the `JSONEncoder.encode` call to a `Task { ... }` on a background executor, with the resulting `Data` written back on the main actor. This is a non-trivial change that must preserve `@MainActor` isolation for `history.dataPoints` access:

```swift
// Sketch only — full implementation requires careful actor hop:
func flushToDisk() {
    guard isDirty else { return }
    flushTimer?.cancel(); flushTimer = nil
    let snapshot = history  // captured on MainActor
    isDirty = false
    Task.detached(priority: .background) {
        guard let data = try? JSONEncoder.historyEncoder.encode(snapshot) else { return }
        try? data.write(to: UsageHistoryService.historyFileURL, options: .atomic)
        Logger.history.info("Flushed \(snapshot.dataPoints.count) points to disk")
    }
}
```

Note: `historyFileURL` must be accessible from a `Task.detached` context, which requires making it a `nonisolated static let` rather than an actor-isolated property. This is compatible with Issue 4's proposed change to a `static let`.

**Migration Notes:** The background flush changes the timing of writes but not correctness, since `isDirty` is set to `false` before the async write begins. A race condition exists if a new data point arrives after `isDirty = false` but before the write completes — it will be captured in the next flush cycle. This is acceptable given the 5-minute flush interval.

---

### Issue 25 — SVG parser fully defensive against malformed input

**Problem:** Beyond Bug 1 (force unwrap in `num()`), the parser in `parseSVGPath` has no error reporting and silently skips unknown commands (`default: i += 1`). This is the right behavior for production robustness. After fixing Bug 1, the parser should additionally log a warning via `os_log` if it encounters unexpected data, to aid debugging if the SVG constant is ever modified.

**Affected file(s):** `MenuBarIconRenderer.swift` lines 118–174.

**Fix:** After applying the Bug 1 fix, add a single-line `os_log` call on unexpected characters via the `default` case in the switch:

```swift
// In parseSVGPath, after applying Bug 1 fix:
default:
    Logger.app.debug("parseSVGPath: unrecognised command '\(chars[i])'")
    i += 1
```

Also add a guard at the function entry to return an empty path if the input string is empty:

```swift
func parseSVGPath(_ d: String) -> NSBezierPath {
    guard !d.isEmpty else { return NSBezierPath() }
    // ... rest unchanged
}
```

**Migration Notes:** Depends on Issue 21 (Logger setup) being implemented first, or on a local `Logger` constant defined in `MenuBarIconRenderer.swift`.

---

## Aesthetics / UX

### Issue 26 — No animation on progress bar value changes

**Problem:** When `fetchUsage()` completes and `usage` is updated, `ProgressView` values snap instantly to new values. The transition is abrupt.

**Affected file(s):** `PopoverView.swift`, `UsageBucketRow` and `ExtraUsageRow` structs.

**Fix:** Apply `animation` to the progress view value transition. In `UsageBucketRow`:

```swift
ProgressView(value: (bucket?.utilization ?? 0) / 100.0, total: 1.0)
    .tint(colorForPct((bucket?.utilization ?? 0) / 100.0))
    .animation(.easeInOut(duration: 0.4), value: bucket?.utilization)
```

Apply the same to `ExtraUsageRow`:

```swift
ProgressView(value: (extra.utilization ?? 0) / 100.0, total: 1.0)
    .tint(colorForPct((extra.utilization ?? 0) / 100.0))
    .animation(.easeInOut(duration: 0.4), value: extra.utilization)
```

Also animate the percentage text using `.contentTransition(.numericText())` on the `Text` view in `UsageBucketRow`:

```swift
Text(percentageText)
    .font(.subheadline)
    .monospacedDigit()
    .contentTransition(.numericText())
    .animation(.easeInOut(duration: 0.4), value: bucket?.utilization)
```

**Before/After:** Before: progress bar and percentage text snap to new values on each poll. After: progress bar width and percentage text animate smoothly over 0.4 seconds when the usage value changes.

---

### Issue 27 — "Updated X ago" with no absolute time on hover

**Problem:** `PopoverView.swift` lines 115–118 show only relative time ("Updated 2 min ago"). Users who want the exact timestamp have no way to see it.

**Affected file(s):** `PopoverView.swift` lines 115–118.

**Fix:** Add a `.help()` tooltip showing the absolute timestamp:

```swift
if let updated = service.lastUpdated {
    Text("Updated \(updated, style: .relative) ago")
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(updated.formatted(.dateTime.hour().minute().second()))
}
```

**Before/After:** Before: hovering over the "Updated X ago" text shows nothing. After: a macOS tooltip appears showing the exact time, e.g., "14:23:07".

---

### Issue 28 — Chart legend colors carry no semantic meaning

**Problem:** `UsageChartView.swift` lines 95–98: the chart uses `Color.blue` for the 5-hour line and `Color.orange` for the 7-day line. These are SwiftUI Chart defaults with no semantic relationship to what they represent.

**Affected file(s):** `UsageChartView.swift` lines 64, 70, 95–98, 139, 142.

**Fix:** Define named constants that convey meaning — teal for short-term (5h) and indigo for long-term (7d) — and apply them consistently throughout the chart and tooltip:

```swift
// UsageChartView.swift — add at top of struct:
private let color5h = Color.teal
private let color7d = Color.indigo

// Replace all Color.blue with color5h and Color.orange with color7d:
// Line 64: .foregroundStyle(.blue) → .foregroundStyle(color5h)
// Line 70: .foregroundStyle(.orange) → .foregroundStyle(color7d)
// Lines 95-98: "5h": Color.blue → "5h": color5h, "7d": Color.orange → "7d": color7d
// Line 139: .foregroundStyle(.blue) → .foregroundStyle(color5h) (tooltip)
// Line 142: .foregroundStyle(.orange) → .foregroundStyle(color7d) (tooltip)
```

**Before/After:** Before: blue and orange lines with no semantic association. After: teal (short-term) and indigo (long-term) communicate the time-scale relationship visually.

---

### Issue 29 — Hardcoded popover width

**Problem:** `PopoverView.swift` line 23: `.frame(width: 340)` is a fixed constraint with no flexibility.

**Affected file(s):** `PopoverView.swift` line 23.

**Fix:** Replace with a flexible frame. Note that `MenuBarExtra` with `.window` style may constrain sizing — add a comment documenting this:

```swift
// MenuBarExtra(.window) does not support fully adaptive sizing on macOS 14.
// Use a fixed width for predictable layout; adjust if minimum content requires more.
.frame(minWidth: 300, idealWidth: 340, maxWidth: 400)
```

**Before/After:** Before: popover is always exactly 340pt wide. After: popover adapts between 300 and 400pt, defaulting to 340pt, allowing room for longer localized strings or wider content.

---

### Issue 30 — "Sign Out" and "Quit" not visually separated from "Refresh"

**Problem:** `PopoverView.swift` lines 126–133: "Refresh", "Sign Out", and "Quit" are all in the same `HStack(spacing: 12)` with identical `.borderless` styling. "Sign Out" and "Quit" are destructive actions placed adjacent to the non-destructive "Refresh".

**Affected file(s):** `PopoverView.swift` lines 114–134.

**Fix:** Group destructive actions visually. Add a `Spacer()` between "Refresh" and "Sign Out", color "Sign Out" red, and separate "Sign Out" from "Quit" with a subdued pipe character:

```swift
HStack(spacing: 12) {
    if let updated = service.lastUpdated {
        Text("Updated \(updated, style: .relative) ago")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(updated.formatted(.dateTime.hour().minute().second()))
    }
    Spacer()
    Button("Refresh") {
        Task { await service.fetchUsage() }
    }
    .buttonStyle(.borderless)
    .font(.caption)

    Divider().frame(height: 10)  // visual separator

    Button("Sign Out") { service.signOut() }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.red)
    Button("Quit") { NSApplication.shared.terminate(nil) }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

**Before/After:** Before: Refresh, Sign Out, and Quit are visually identical and equally prominent. After: a Divider separates the safe action (Refresh) from the destructive actions (Sign Out in red, Quit in gray).

---

## Quick Wins

Items that require 5 lines of code or fewer:

| Item # | File | Change Description | Lines Changed |
|--------|------|--------------------|---------------|
| 1 | `MenuBarIconRenderer.swift` line 137 | Replace `Double(...)!` with `guard let d = Double(...) else { return nil }; return CGFloat(d)` | 2 |
| 2 | `UsageChartView.swift` line 111 | Replace `proxy.plotFrame!` with `guard let plotFrame = proxy.plotFrame else { return }; geo[plotFrame]` | 2 |
| 3 | `UsageChartView.swift` line 165 | Replace `sorted.first!` and `sorted.last!` with `guard let firstPoint = sorted.first, let lastPoint = sorted.last else { return nil }` | 2 |
| 5 | `PopoverView.swift` line 173 | Replace `service.isAwaitingCode = false` with `service.cancelOAuthFlow()` | 1 |
| 9 | `UsageHistoryService.swift` line 73 | Move `flushTimer?.cancel(); flushTimer = nil` before the `guard isDirty` check | 2 |
| 11 | `UsageService.swift` line 70 | Replace `generateCodeVerifier()` with `generateRandomBase64URL()` | 1 |
| 12 | `MenuBarIconRenderer.swift` line 16 | Add comment explaining template image + black color relationship | 2 |
| 15 | `PopoverView.swift` line 239 | Replace `.tint(.blue)` with `.tint(colorForPct((extra.utilization ?? 0) / 100.0))` | 1 |
| 23 | `UsageService.swift` line 22 | Add inline comment explaining `clientId` origin | 2 |
| 27 | `PopoverView.swift` lines 115–118 | Add `.help(updated.formatted(.dateTime.hour().minute().second()))` | 1 |

---

## Phased Rollout

### Phase 1: Critical Fixes

**Goal:** Eliminate all known crash paths. No behavior changes beyond crash prevention.

**Items:** 1, 2, 3, 25 (defensive parser cleanup, depends on Bug 1)

**Rationale:** These are the highest-risk items. Items 1, 2, and 3 are independent of each other and can be applied in parallel. Item 25 depends on Bug 1 being fixed first (it adds logging to the now-safe parser). All four changes are small, localized, and do not require any call-site updates.

**Dependencies:** Item 25 has a soft dependency on Item 21 (Logger setup) for the `os_log` call; if Item 21 is deferred, substitute a `print` statement temporarily.

---

### Phase 2: Internal Refactoring

**Goal:** Improve structural correctness and eliminate architectural debt. All changes are behavior-preserving from the user's perspective.

**Items (in order):**

1. Items 4 and 18 together — Extract `ConfigDirectory`. This is a prerequisite for Item 24's background flush sketch (which requires `historyFileURL` to be `nonisolated`).
2. Item 6 — Fix optional dependency injection. Requires changes to `UsageService.init()` and `ClaudeUsageBarApp.swift`. Do after Item 4 because the `App` struct `init()` rewrite is cleaner when `ConfigDirectory` already exists.
3. Item 13 — Move `.task` initialization to `PopoverView.onAppear`. Depends on Item 6 (removes the `service.historyService = historyService` assignment that currently lives in `.task`).
4. Item 5 — Add `cancelOAuthFlow()` method. Independent; can be applied at any point in Phase 2.
5. Item 11 — Rename/extract `generateRandomBase64URL()`. Independent; 1-line change.
6. Items 7 and 19 together — Fix UUID regeneration and CodingKeys exclusion. These are coupled: if `id` is excluded from coding (Issue 19), the deterministic ID scheme (Issue 7) becomes the sole source of identity for downsampled points.
7. Item 8 — Cache downsampled points. Depends on Item 7 (deterministic IDs make caching by identity correct).
8. Items 9 and 10 — Fix flush timer and backoff behavior. Independent of each other and of the above.
9. Item 20 — Tune `targetPointCount`. Independent.
10. Item 14 — Preserve usage data on 401 / add `handleSessionExpiry()`. Independent; add after structural changes are stable.

**Dependencies:** The Item 6 → Item 13 dependency is strict. All others in this phase are independent.

---

### Phase 3: Production Hardening

**Goal:** Add observability, resilience, and documentation. Low user-facing risk.

**Items (in order):**

1. Item 21 — Add `Logger` infrastructure. This is a prerequisite for Items 24 and 25 (which use the logger).
2. Item 22 — Display version string. Independent of logging.
3. Item 23 — Document `clientId`. Zero-risk documentation change.
4. Item 24 — Add file size guard and background flush. Depends on Items 4/18 (nonisolated `historyFileURL`) and Item 21 (logging). The background flush portion is optional in Phase 3 — the size guard alone is a safe 5-line addition.
5. Item 12 — Document template image color rationale. Zero-risk documentation change; can be applied at any time.

**Dependencies:** Item 21 before Items 24 and 25. Items 22, 23, and 12 are independent of everything.

---

### Phase 4: UX Polish

**Goal:** Visual and interaction improvements. These are user-facing changes with cosmetic risk only.

**Items (in order):**

1. Item 15 — Semantic color for `ExtraUsageRow`. One-line change; apply first as it has the highest signal value per effort.
2. Item 16 — Loading indicator on Refresh. Requires adding `@Published var isLoading` to `UsageService`; moderately invasive but low risk.
3. Item 26 — Animate progress bar value changes. Apply `.animation` modifiers to `ProgressView` and percentage text.
4. Item 27 — Absolute time tooltip on "Updated X ago". One-line `.help()` addition.
5. Item 28 — Semantic chart colors. Rename `blue` → `teal` and `orange` → `indigo` across all chart references; five lines across `UsageChartView.swift`.
6. Item 30 — Separate "Sign Out"/"Quit" from "Refresh" visually. Requires restructuring the footer `HStack`; moderate layout change.
7. Item 17 — Tooltip positioning relative to hover location. Most complex UX change; implement last. Requires computing the hover x-position in the overlay and using SwiftUI's alignment guides or offset modifiers to position the tooltip near the cursor rather than pinned to `.top`.
8. Item 29 — Flexible popover width. Apply `.frame(minWidth:idealWidth:maxWidth:)`. Apply last, after all other UX changes, to see if the content needs more than 340pt before committing to a range.

**Dependencies:** Items within Phase 4 are independent of each other, except Item 17 (tooltip positioning) which builds on the hover infrastructure established for the chart and is easier to reason about after the color changes in Item 28 are applied.

---

### Critical Files for Implementation

- `/Users/antoanpeychev/Projects/claude-usage-bar/Sources/ClaudeUsageBar/UsageService.swift` — Core logic to modify: dependency injection (Issue 6), OAuth cleanup (Issue 5/11), backoff behavior (Issue 10), session expiry handling (Issue 14), loading indicator (Issue 16), logging (Issue 21).
- `/Users/antoanpeychev/Projects/claude-usage-bar/Sources/ClaudeUsageBar/UsageHistoryService.swift` — Architecture to refactor: config directory extraction (Issues 4/18), flush timer fix (Issue 9), background encoding (Issue 24).
- `/Users/antoanpeychev/Projects/claude-usage-bar/Sources/ClaudeUsageBar/MenuBarIconRenderer.swift` — Crash fix target: force-unwrap in `num()` (Bug 1), SVG parser defensiveness (Issue 25).
- `/Users/antoanpeychev/Projects/claude-usage-bar/Sources/ClaudeUsageBar/UsageChartView.swift` — Crash fix target and performance: `plotFrame` force-unwrap (Bug 2), sorted array bounds (Bug 3), hover caching (Issue 8), color semantics (Issue 28), tooltip positioning (Issue 17).
- `/Users/antoanpeychev/Projects/claude-usage-bar/Sources/ClaudeUsageBar/PopoverView.swift` — UX changes: loading indicator (Issue 16), animation (Issue 26), footer restructure (Issues 27/30), version display (Issue 22), ExtraUsage color (Issue 15).agentId: a5b0214b59519fb46 (for resuming to continue this agent's work if needed)
<usage>total_tokens: 51983
tool_uses: 14
duration_ms: 302743</usage>