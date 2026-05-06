import Foundation
import os

/// Canonical service-status states from the Statuspage.io v2 component enum, mapped 1:1.
///
/// Severity ordering (lowest → highest):
/// `operational` == `underMaintenance` < `degradedPerformance` < `partialOutage` < `majorOutage`.
///
/// `underMaintenance` is treated as `operational` in v1 per planning §R4 / AR §AD6 — surfacing
/// scheduled maintenance distinctly is deferred to a future release.
public enum ClaudeServiceStatus: String, Sendable, Equatable, Codable, CaseIterable {
    case operational
    case underMaintenance      = "under_maintenance"
    case degradedPerformance   = "degraded_performance"
    case partialOutage         = "partial_outage"
    case majorOutage           = "major_outage"

    /// Higher == worse. Matches the rollup ordering in planning §R3.
    public var severity: Int {
        switch self {
        case .operational, .underMaintenance: 0
        case .degradedPerformance:            1
        case .partialOutage:                  2
        case .majorOutage:                    3
        }
    }

    /// Forgiving constructor: unknown / missing strings return `.operational` and emit an
    /// `os_log` warning so schema drift never crashes the app or surfaces raw errors to the
    /// user (`rules/security.md` — error messages must not expose internals).
    public init(forgiving raw: String?) {
        guard let raw, !raw.isEmpty else {
            self = .operational
            return
        }
        if let known = ClaudeServiceStatus(rawValue: raw) {
            self = known
            return
        }
        ClaudeServiceStatus.logger.warning(
            "Unknown component.status string '\(raw, privacy: .public)' — defaulting to .operational"
        )
        self = .operational
    }

    static let logger = Logger(subsystem: "com.local.ClaudeUsageBar", category: "StatusPage")
}

public extension Sequence where Element == ClaudeServiceStatus {
    /// Rolled-up severity across an arbitrary sequence of component statuses.
    /// Returns `.operational` for an empty sequence.
    func rolledUp() -> ClaudeServiceStatus {
        var worst: ClaudeServiceStatus = .operational
        for s in self where s.severity > worst.severity {
            worst = s
        }
        return worst
    }
}

/// One filtered/monitored component as seen by `StatusMonitor` callers.
public struct StatusComponent: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let name: String
    public let status: ClaudeServiceStatus
    public let groupId: String?
    public let updatedAt: Date?

    public init(id: String, name: String, status: ClaudeServiceStatus, groupId: String? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.groupId = groupId
        self.updatedAt = updatedAt
    }
}

/// One unresolved incident (from `summary.json`'s `incidents` array).
public struct StatusIncident: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let name: String
    public let status: String        // "investigating" | "identified" | "monitoring" | "resolved"
    public let impact: String        // "none" | "minor" | "major" | "critical" | "maintenance"
    public let shortlink: URL?
    public let updatedAt: Date?

    public init(id: String, name: String, status: String, impact: String, shortlink: URL? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.impact = impact
        self.shortlink = shortlink
        self.updatedAt = updatedAt
    }
}

/// Decoded shape returned by `StatusPageClient.fetchSummary()`.
/// Mirrors the Statuspage.io v2 `summary.json` payload but only the fields we use.
public struct StatusPageSummary: Sendable, Equatable, Codable {
    public let components: [StatusComponent]
    public let incidents: [StatusIncident]

    public init(components: [StatusComponent], incidents: [StatusIncident]) {
        self.components = components
        self.incidents = incidents
    }
}

/// What `StatusMonitor` publishes after applying the filter and rollup.
public struct StatusSnapshot: Sendable, Equatable {
    public let rollup: ClaudeServiceStatus
    /// Components currently in a non-operational state (after filter).
    public let impactedComponents: [StatusComponent]
    /// Currently unresolved incidents touching the monitored components.
    public let activeIncidents: [StatusIncident]
    /// Every monitored component (operational + impacted) for popover display.
    public let allMonitoredComponents: [StatusComponent]
    public let fetchedAt: Date

    public init(
        rollup: ClaudeServiceStatus,
        impactedComponents: [StatusComponent],
        activeIncidents: [StatusIncident],
        allMonitoredComponents: [StatusComponent],
        fetchedAt: Date
    ) {
        self.rollup = rollup
        self.impactedComponents = impactedComponents
        self.activeIncidents = activeIncidents
        self.allMonitoredComponents = allMonitoredComponents
        self.fetchedAt = fetchedAt
    }

    /// Build a snapshot from a raw summary using `filter` to scope the components.
    public static func make(
        from summary: StatusPageSummary,
        filter: StatusComponentFilter,
        now: Date = Date()
    ) -> StatusSnapshot {
        let monitored = summary.components.filter { filter.matches($0) }
        let impacted = monitored.filter { $0.status.severity > 0 }
        let rollup = monitored.map(\.status).rolledUp()
        return StatusSnapshot(
            rollup: rollup,
            impactedComponents: impacted,
            activeIncidents: summary.incidents,
            allMonitoredComponents: monitored,
            fetchedAt: now
        )
    }
}

/// User-editable, case-insensitive substring filter applied to `component.name`.
/// Persists as JSON under `AppearanceDefaultsKey.statusComponentFilter`.
public struct StatusComponentFilter: Sendable, Equatable, Codable {
    public var substrings: [String]

    public init(substrings: [String]) {
        self.substrings = substrings
    }

    /// Default scope captured during the DV-1.1 spike on 2026-05-06 — all three substrings
    /// match exactly one live `component.name` each (see `.context/spike-status-claude.md`).
    public static let `default` = StatusComponentFilter(
        substrings: ["Claude API", "claude.ai", "Claude Code"]
    )

    public func matches(_ component: StatusComponent) -> Bool {
        let name = component.name.lowercased()
        return substrings.contains { !$0.isEmpty && name.contains($0.lowercased()) }
    }
}

/// Errors surfaced by `StatusPageClient`. None of these are ever shown verbatim to users —
/// the popover renders a generic "Status unavailable" instead (security: no system internals).
public enum StatusError: Error, Sendable, Equatable {
    case transport(URLError.Code)
    case http(Int)
    case decode(String)
    case cancelled
    case invalidResponse
}
