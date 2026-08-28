import Foundation

struct UsageResponse: Codable {
    let fiveHour: UsageBucket?
    let sevenDay: UsageBucket?
    let sevenDayOpus: UsageBucket?
    let sevenDaySonnet: UsageBucket?
    let extraUsage: ExtraUsage?
    /// Server-driven per-scope windows. Newer accounts report per-model weekly
    /// usage here instead of through the fixed `seven_day_*` fields.
    let limits: [UsageLimit]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
        case limits
    }

    init(
        fiveHour: UsageBucket? = nil,
        sevenDay: UsageBucket? = nil,
        sevenDayOpus: UsageBucket? = nil,
        sevenDaySonnet: UsageBucket? = nil,
        extraUsage: ExtraUsage? = nil,
        limits: [UsageLimit]? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.extraUsage = extraUsage
        self.limits = limits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try container.decodeIfPresent(UsageBucket.self, forKey: .fiveHour)
        sevenDay = try container.decodeIfPresent(UsageBucket.self, forKey: .sevenDay)
        sevenDayOpus = try container.decodeIfPresent(UsageBucket.self, forKey: .sevenDayOpus)
        sevenDaySonnet = try container.decodeIfPresent(UsageBucket.self, forKey: .sevenDaySonnet)
        extraUsage = try container.decodeIfPresent(ExtraUsage.self, forKey: .extraUsage)

        // `limits` is server-controlled and not part of any documented contract,
        // so it is decoded element-wise and anything unrecognised is dropped.
        // Strict decoding here would fail the whole response and freeze the
        // 5-hour and 7-day bars over a field the app didn't read before.
        limits = (try? container.decodeIfPresent([LenientLimit].self, forKey: .limits))?
            .compactMap(\.value)
    }

    /// Per-model weekly windows, newest source first: entries from `limits`
    /// win, and the fixed `seven_day_*` fields fill in models they don't cover.
    var perModelWeekly: [PerModelUsage] {
        let weekly = (limits ?? []).filter(\.isWeeklyScoped)
        var result = weekly.compactMap(\.perModelWeekly)

        // Only an entry for exactly this model, scoped to no particular surface,
        // supersedes the fixed field. A narrower window measures something else
        // — suppressing the account-wide bar in its favour would misreport usage
        // (Claude Code shows both rather than reconciling them).
        let superseded = Set(
            weekly
                .filter { ($0.scope?.surface?.displayName?.isEmpty ?? true) }
                .compactMap { $0.scope?.model?.displayName?.lowercased() }
        )

        func appendFixedField(id: String, displayName: String, bucket: UsageBucket?) {
            guard let bucket, bucket.utilization != nil else { return }
            guard !superseded.contains(displayName.lowercased()) else { return }
            result.append(PerModelUsage(id: id, displayName: displayName, bucket: bucket))
        }

        appendFixedField(id: "seven_day_opus", displayName: "Opus", bucket: sevenDayOpus)
        appendFixedField(id: "seven_day_sonnet", displayName: "Sonnet", bucket: sevenDaySonnet)
        return Self.disambiguating(result)
    }

    /// `id` separates rows by group, so the label has to as well — otherwise two
    /// windows for one model render as identical rows with different numbers.
    private static func disambiguating(_ rows: [PerModelUsage]) -> [PerModelUsage] {
        let duplicated = Set(
            Dictionary(grouping: rows, by: \.displayName)
                .filter { $0.value.count > 1 }
                .keys
        )
        guard !duplicated.isEmpty else { return rows }

        return rows.map { row in
            guard duplicated.contains(row.displayName),
                  let group = row.group, !group.isEmpty else { return row }
            return PerModelUsage(
                id: row.id,
                displayName: "\(row.displayName) — \(group)",
                bucket: row.bucket,
                group: group
            )
        }
    }

    func reconciled(with previous: UsageResponse?, now: Date = Date()) -> UsageResponse {
        UsageResponse(
            fiveHour: fiveHour?.reconciled(
                with: previous?.fiveHour,
                resetInterval: 5 * 60 * 60,
                now: now
            ),
            sevenDay: sevenDay?.reconciled(
                with: previous?.sevenDay,
                resetInterval: 7 * 24 * 60 * 60,
                now: now
            ),
            sevenDayOpus: sevenDayOpus?.reconciled(
                with: previous?.sevenDayOpus,
                resetInterval: 7 * 24 * 60 * 60,
                now: now
            ),
            sevenDaySonnet: sevenDaySonnet?.reconciled(
                with: previous?.sevenDaySonnet,
                resetInterval: 7 * 24 * 60 * 60,
                now: now
            ),
            extraUsage: extraUsage,
            limits: limits.map { current in
                current.map { limit in
                    let earlier = previous?.limits
                    let match = earlier?.first { $0.hasSameScope(as: limit) }
                        ?? earlier?.first { $0.hasSameModelScope(as: limit) }
                    return limit.reconciled(with: match, now: now)
                }
            }
        )
    }
}

/// Decodes a `UsageLimit` without failing the surrounding array.
private struct LenientLimit: Decodable {
    let value: UsageLimit?

    init(from decoder: Decoder) throws {
        value = try? UsageLimit(from: decoder)
    }
}

/// One per-model row in the popover's per-model section.
struct PerModelUsage: Identifiable {
    /// Derived from the full scope, not just the model name: two weekly windows
    /// can name the same model and differ only by surface or group, and SwiftUI
    /// mis-diffs a `ForEach` whose ids collide.
    let id: String
    let displayName: String
    let bucket: UsageBucket
    /// Only used to disambiguate otherwise-identical labels.
    let group: String?

    init(id: String, displayName: String, bucket: UsageBucket, group: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.bucket = bucket
        self.group = group
    }
}

struct UsageLimit: Codable {
    let kind: String?
    let group: String?
    let percent: Double?
    let resetsAt: String?
    let scope: UsageLimitScope?

    enum CodingKeys: String, CodingKey {
        case kind
        case group
        case percent
        case scope
        case resetsAt = "resets_at"
    }

    init(
        kind: String? = nil,
        group: String? = nil,
        percent: Double? = nil,
        resetsAt: String? = nil,
        scope: UsageLimitScope? = nil
    ) {
        self.kind = kind
        self.group = group
        self.percent = percent
        self.resetsAt = resetsAt
        self.scope = scope
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        percent = try container.decodeIfPresent(Double.self, forKey: .percent)
        scope = try container.decodeIfPresent(UsageLimitScope.self, forKey: .scope)

        // Normally ISO-8601, but the field can also arrive as epoch seconds.
        // A nil here means absent, null, or "not a number" — all handled by the
        // string branch, which yields nil for the first two.
        if let epoch = try? container.decodeIfPresent(Double.self, forKey: .resetsAt) {
            resetsAt = Self.isoString(fromEpochSeconds: epoch)
        } else {
            resetsAt = try container.decodeIfPresent(String.self, forKey: .resetsAt)
        }
    }

    var isWeeklyScoped: Bool { kind == "weekly_scoped" }

    /// A model-scoped weekly window, or nil when this entry scopes something else.
    var perModelWeekly: PerModelUsage? {
        guard isWeeklyScoped, percent != nil else { return nil }
        guard let model = scope?.model?.displayName, !model.isEmpty else { return nil }

        let rawSurface = scope?.surface?.displayName
        let surface = (rawSurface?.isEmpty == false) ? rawSurface : nil

        return PerModelUsage(
            id: [kind, group, model, surface]
                .map { $0 ?? "" }
                .joined(separator: "\u{1F}"),
            displayName: surface.map { "\(model) (\($0))" } ?? model,
            bucket: UsageBucket(utilization: percent, resetsAt: resetsAt),
            group: group
        )
    }

    /// Exact match, including `group`.
    func hasSameScope(as other: UsageLimit) -> Bool {
        hasSameModelScope(as: other) && group == other.group
    }

    /// Same window for the same model and surface, ignoring `group`. The server
    /// can relabel a model's group between polls, and a reset should still carry
    /// over when it does.
    func hasSameModelScope(as other: UsageLimit) -> Bool {
        kind == other.kind
            && scope?.model?.displayName == other.scope?.model?.displayName
            && scope?.surface?.displayName == other.scope?.surface?.displayName
    }

    func reconciled(with previous: UsageLimit?, now: Date) -> UsageLimit {
        guard let resetInterval else { return self }

        let resolved = UsageBucket(utilization: percent, resetsAt: resetsAt)
            .reconciled(
                with: previous.map { UsageBucket(utilization: $0.percent, resetsAt: $0.resetsAt) },
                resetInterval: resetInterval,
                now: now
            )

        return UsageLimit(
            kind: kind,
            group: group,
            percent: percent,
            resetsAt: resolved.resetsAt,
            scope: scope
        )
    }

    /// Only weekly windows have a cadence we can extrapolate a missing reset from.
    private var resetInterval: TimeInterval? {
        isWeeklyScoped ? 7 * 24 * 60 * 60 : nil
    }

    private static func isoString(fromEpochSeconds seconds: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }
}

struct UsageLimitScope: Codable {
    let model: UsageLimitDescriptor?
    let surface: UsageLimitDescriptor?

    init(model: UsageLimitDescriptor? = nil, surface: UsageLimitDescriptor? = nil) {
        self.model = model
        self.surface = surface
    }
}

struct UsageLimitDescriptor: Codable {
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }

    init(displayName: String?) {
        self.displayName = displayName
    }
}

struct UsageBucket: Codable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var resetsAtDate: Date? {
        Self.parseResetDate(from: resetsAt)
    }

    /// Seconds until `resetsAtDate`, or nil when the bucket has no reset date.
    /// Returns negative values when the reset time is in the past — callers are
    /// responsible for any clamping they need.
    func secondsUntilReset(now: Date = Date()) -> TimeInterval? {
        resetsAtDate.map { $0.timeIntervalSince(now) }
    }

    /// Position 0...1 of the reset moment within a sliding window of
    /// `windowSeconds`. 0 means the reset is exactly one full window away;
    /// 1 means the reset is now (or in the past). Returns nil when the bucket
    /// has no reset date.
    func resetPosition(windowSeconds: TimeInterval, now: Date = Date()) -> Double? {
        guard let secsLeft = secondsUntilReset(now: now) else { return nil }
        guard windowSeconds > 0 else { return nil }
        let raw = 1.0 - (secsLeft / windowSeconds)
        return min(max(0.0, raw), 1.0)
    }

    func reconciled(with previous: UsageBucket?, resetInterval: TimeInterval, now: Date) -> UsageBucket {
        guard resetsAtDate == nil else { return self }
        guard let previousDate = previous?.resetsAtDate else { return self }

        let resolvedDate = Self.nextResetDate(
            from: previousDate,
            resetInterval: resetInterval,
            now: now
        )

        return UsageBucket(
            utilization: utilization,
            resetsAt: Self.resetString(from: resolvedDate)
        )
    }

    private static func parseResetDate(from value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        let isoFormatters: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime]
        ]

        for options in isoFormatters {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: value) {
                return date
            }
        }

        let fallbackPatterns = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss"
        ]

        for pattern in fallbackPatterns {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = pattern
            if let date = formatter.date(from: value) {
                return date
            }
        }

        return nil
    }

    private static func nextResetDate(from previous: Date, resetInterval: TimeInterval, now: Date) -> Date {
        guard resetInterval > 0 else { return previous }
        guard previous <= now else { return previous }

        let elapsed = now.timeIntervalSince(previous)
        let stepCount = floor(elapsed / resetInterval) + 1
        return previous.addingTimeInterval(stepCount * resetInterval)
    }

    private static func resetString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

struct ExtraUsage: Codable {
    let isEnabled: Bool
    let utilization: Double?
    let usedCredits: Double?
    let monthlyLimit: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case utilization
        case usedCredits = "used_credits"
        case monthlyLimit = "monthly_limit"
    }

    /// API returns credits in minor units (cents); convert to dollars.
    var usedCreditsAmount: Double? {
        usedCredits.map { $0 / 100.0 }
    }

    var monthlyLimitAmount: Double? {
        monthlyLimit.map { $0 / 100.0 }
    }

    static let currencyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 2
        return f
    }()

    static func formatUSD(_ amount: Double) -> String {
        currencyFormatter.string(from: NSNumber(value: amount))
            ?? String(format: "$%.2f", amount)
    }
}
